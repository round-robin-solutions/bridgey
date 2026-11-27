//! The Calls window against protocol/test-vectors/dialer-v1.json (what this device reads from the phone and writes to
//! it), the callsRequest group of protocol-v1.json, and the list and SIM rules (DialerProtocolTests.swift).

use super::*;

const ID: &str = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293";

fn group(file: &str, name: &str) -> Vec<Value> {
    let all: Value = serde_json::from_str(file).unwrap();
    let list = all[name].as_array().unwrap_or_else(|| panic!("{name}")).clone();
    assert!(list.len() > 5, "{name}");
    list
}

fn dialer(name: &str) -> Vec<Value> {
    group(include_str!("../../../../protocol/test-vectors/dialer-v1.json"), name)
}

fn plaintext(v: &Value) -> Vec<u8> {
    match v.get("plaintextString").and_then(Value::as_str) {
        Some(raw) => raw.as_bytes().to_vec(),
        None => serde_json::to_vec(&v["plaintext"]).unwrap(),
    }
}

fn reads(name: &str, decode: impl Fn(&[u8]) -> Option<Value>) {
    let failed: Vec<String> = dialer(name)
        .iter()
        .filter(|v| decode(&plaintext(v)).unwrap_or(json!("reject")) != v["expect"])
        .map(|v| format!("{}: {}", v["name"], decode(&plaintext(v)).unwrap_or(json!("reject"))))
        .collect();
    assert!(failed.is_empty(), "{name} vectors this device reads differently: {failed:#?}");
}

#[test]
fn status() {
    reads("status", |p| {
        decode_status(p).map(|s| {
            json!({"place": s.place, "confirm": s.confirm, "contacts": s.contacts, "recents": s.recents, "whatsapp": s.whatsapp,
                   "sims": s.sims.iter().map(|x| json!({"subId": x.sub_id, "slot": x.slot, "label": x.label})).collect::<Vec<_>>()})
        })
    });
}

#[test]
fn contacts() {
    reads("contacts", |p| {
        decode_contacts_result(p).map(|r| {
            let contacts: Vec<Value> = r
                .contacts
                .iter()
                .map(|c| {
                    json!({"id": c.id, "name": c.name, "starred": c.starred,
                           "numbers": c.numbers.iter().map(|n| json!({"address": n.address, "label": n.label})).collect::<Vec<_>>(),
                           "whatsapp": c.whatsapp.iter().map(|w| json!({"address": w.address, "voice": w.voice, "video": w.video})).collect::<Vec<_>>()})
                })
                .collect();
            json!({"requestId": r.request_id, "contacts": contacts, "error": r.error})
        })
    });
}

#[test]
fn recents() {
    reads("recents", |p| {
        decode_recents_result(p).map(|r| {
            let calls: Vec<Value> = r
                .calls
                .iter()
                .map(|c| json!({"id": c.id, "address": c.address, "name": c.name, "type": c.kind, "date": c.date, "duration": c.duration, "subId": c.sub_id}))
                .collect();
            json!({"requestId": r.request_id, "calls": calls, "error": r.error})
        })
    });
}

#[test]
fn call_result() {
    reads("callResult", |p| decode_call_result(p).map(|r| json!({"requestId": r.request_id, "result": r.result, "reason": r.reason})));
}

/// What this device writes, the phone decodes as the request vectors say; what the phone would reject never goes.
#[test]
fn requests_match_the_vectors_the_phone_decodes() {
    let list = dialer("request");
    let vector = |name: &str| list.iter().find(|v| v["name"] == json!(name)).unwrap_or_else(|| panic!("{name}"))["plaintext"].clone();
    assert_eq!(contacts_request(ID, "Anna").unwrap(), vector("contacts, a name"));
    assert_eq!(contacts_request(ID, "  Anna K ").unwrap(), json!({"version": 1, "requestId": ID, "query": "Anna K"}));
    assert_eq!(recents_request(ID, 20), vector("recents, 20"));
    assert_eq!(call_request(ID, "+91 98765 43210", None).unwrap(), vector("call, a number"));
    assert_eq!(call_request(ID, "(022) 4000-1234", Some(2)).unwrap(), vector("call, a number on SIM 2"));
    assert_eq!(whatsapp_request(ID, 4211, false).unwrap(), vector("call, WhatsApp voice"));
    assert_eq!(whatsapp_request(ID, 4212, true).unwrap(), vector("call, WhatsApp video"));
    // A long query is cut to 64 UTF-16 units, never in the middle of a character, and never sent empty.
    let long = contacts_request(ID, &format!("  {}", "\u{1F600}".repeat(40))).unwrap();
    assert_eq!(long["query"].as_str().unwrap().encode_utf16().count(), 64);
    assert!(contacts_request(ID, "   ").is_none());
    assert_eq!(recents_request(ID, 500)["limit"], json!(50));
    assert!(whatsapp_request(ID, 0, false).is_none());
    // Numbers the phone rejects are refused here.
    for v in list.iter().filter(|v| v["kind"] == json!("dialer.call") && v["expect"] == json!("reject")) {
        let p = &v["plaintext"];
        // Only the vectors whose one fault is the number (not the version, the ID or the other fields).
        let only_number = p.as_object().is_some_and(|o| o.keys().all(|k| matches!(k.as_str(), "version" | "requestId" | "via" | "address")));
        if p["via"] == json!("phone") && p["version"] == json!(1) && only_number {
            if let Some(address) = p["address"].as_str() {
                assert!(call_request(ID, address, None).is_none(), "{}", v["name"]);
            }
        }
    }
}

/// Calls from this device (upstream): the number the phone dials, or reject.
#[test]
fn calls_request_numbers() {
    let failed: Vec<String> = group(include_str!("../../../../protocol/test-vectors/protocol-v1.json"), "callsRequest")
        .iter()
        .filter(|v| {
            let number = v["plaintext"].get("number").and_then(Value::as_str);
            let result = number.and_then(normalized_number).map(Value::from).unwrap_or(json!("reject"));
            result != v["expect"]
        })
        .map(|v| v["name"].to_string())
        .collect();
    assert!(failed.is_empty(), "{failed:?}");
    assert_eq!(upstream_request("+7 (999) 123-45-67").unwrap(), json!({"number": "+7 (999) 123-45-67"}));
    assert!(upstream_request("*100#").is_none());
}

fn sims() -> Vec<Sim> {
    vec![Sim { sub_id: 3, slot: 0, label: "Jio".into() }, Sim { sub_id: 7, slot: 1, label: "Airtel".into() }]
}

#[test]
fn sim_choice() {
    assert_eq!(sim_decision("ask", &sims(), None), SimDecision::Ask);
    assert_eq!(sim_decision("ask", &sims(), Some(7)), SimDecision::Use(7));
    assert_eq!(sim_decision("sim1", &sims(), None), SimDecision::Use(3));
    assert_eq!(sim_decision("sim2", &sims(), None), SimDecision::Use(7));
    assert_eq!(sim_decision("sim2", &sims(), Some(3)), SimDecision::Use(3), "a pick wins");
    assert_eq!(sim_decision("sim1", &sims(), Some(99)), SimDecision::Use(3), "a SIM that is gone is ignored");
    assert_eq!(sim_decision("sim2", &[sims()[0].clone(), Sim { sub_id: 9, slot: 2, label: String::new() }], None), SimDecision::Ask, "an empty preferred slot asks");
    assert_eq!(sim_decision("ask", &sims()[..1], None), SimDecision::PhoneDefault, "one SIM never asks");
    assert_eq!(sim_decision("sim2", &[], Some(7)), SimDecision::PhoneDefault);
}

fn anna() -> Contact {
    Contact {
        id: 7,
        name: "Anna Kapoor".into(),
        starred: true,
        numbers: vec![Number { address: "+91 98765 43210".into(), label: Some("Mobile".into()) }],
        whatsapp: vec![WhatsApp { address: "+919876543210".into(), voice: Some(4211), video: Some(4212) }],
    }
}

fn recent(id: i64, address: &str, name: Option<&str>, kind: &str, date: i64) -> Recent {
    Recent { id, address: address.into(), name: name.map(str::to_string), kind: kind.into(), date, duration: 0, sub_id: None }
}

fn sample_recents() -> Vec<Recent> {
    vec![
        recent(5, "+919876543210", Some("Anna Kapoor"), "outgoing", 5_000),
        recent(4, "+91 98765 43210", Some("Anna Kapoor"), "missed", 4_000),
        recent(3, "100200", Some("Rohan Mehta"), "incoming", 3_000),
        recent(2, "", None, "missed", 2_000),
        recent(1, "+44 20 7946 0000", None, "outgoing", 1_000),
    ]
}

fn ids(rows: &[Row]) -> Vec<String> {
    rows.iter().map(Row::id).collect()
}

#[test]
fn nothing_typed_lists_recent_calls_once_per_number() {
    let r = rows(" ", &[], &sample_recents(), 20);
    assert_eq!(ids(&r), ["r:5", "r:3", "r:2", "r:1"]);
    assert_eq!(rows("", &[], &sample_recents(), 2).len(), 2);
    assert!(Row::Recent(sample_recents()[3].clone()).number().is_none(), "a private number cannot be called back");
}

#[test]
fn a_typed_number_comes_first_then_contacts_then_other_matches() {
    let r = rows("98765", &[anna()], &sample_recents(), 20);
    assert_eq!(ids(&r), ["n:98765", "c:7"]);
    assert_eq!(r[0].number().as_deref(), Some("98765"));
    assert_eq!(ids(&rows("7946 0000", &[], &sample_recents(), 20)), ["n:7946 0000", "r:1"]);
    assert_eq!(ids(&rows("100200", &[], &sample_recents(), 20)), ["n:100200"]);
}

#[test]
fn names_match_word_starts() {
    assert_eq!(ids(&rows("meh", &[], &sample_recents(), 20)), ["r:3"]);
    assert_eq!(ids(&rows("ro", &[], &sample_recents(), 20)), ["r:3"]);
    assert!(rows("ohan", &[], &sample_recents(), 20).is_empty());
    assert_eq!(ids(&rows("Anna", &[anna()], &sample_recents(), 20)), ["c:7"]);
    assert!(recent_matches(&sample_recents()[2], "100"));
    assert!(!recent_matches(&sample_recents()[2], "1"), "one digit matches too much");
    assert!(normalized_number("Anna").is_none());
    assert!(normalized_number("+91 (22) 4000-1234").is_some());
    assert!(normalized_number("*#06#").is_none());
}
