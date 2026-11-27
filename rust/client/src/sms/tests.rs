//! Text messages against the golden vectors in protocol/test-vectors/protocol-v1.json (the groups the Mac and Android
//! check: what this device reads from the phone, and what it writes, which the phone's decoders accept), and the
//! cache's merge rules (SmsStore.swift).

use super::*;

fn vectors(group: &str) -> Vec<Value> {
    let all: Value = serde_json::from_str(include_str!("../../../../protocol/test-vectors/protocol-v1.json")).unwrap();
    let list = all[group].as_array().unwrap_or_else(|| panic!("{group}")).clone();
    assert!(list.len() > 5, "{group}");
    list
}

fn plaintext(v: &Value) -> Vec<u8> {
    match v.get("plaintextString").and_then(Value::as_str) {
        Some(raw) => raw.as_bytes().to_vec(),
        None => serde_json::to_vec(&v["plaintext"]).unwrap(),
    }
}

/// Each vector of `group` decodes to its `expect` ("reject" when the decoder refuses it).
fn reads(group: &str, decode: impl Fn(&[u8]) -> Option<Value>) {
    let failed: Vec<String> = vectors(group)
        .iter()
        .filter(|v| decode(&plaintext(v)).unwrap_or(json!("reject")) != v["expect"])
        .map(|v| format!("{}: {}", v["name"], decode(&plaintext(v)).unwrap_or(json!("reject"))))
        .collect();
    assert!(failed.is_empty(), "{group} vectors this device reads differently: {failed:#?}");
}

#[test]
fn status() {
    reads("smsStatus", |p| decode_status(p).map(|s| json!({"read": s.read, "send": s.send, "contacts": s.contacts, "sims": s.sims, "cursor": s.cursor})));
}

#[test]
fn message_object() {
    reads("smsMessage", |p| {
        let value: Value = serde_json::from_slice(p).ok()?;
        decode_message(&value).map(|m| {
            json!({"id": m.id, "threadId": m.thread_id, "direction": m.direction, "status": m.status, "date": m.date, "address": m.address,
                   "body": m.body, "truncated": m.truncated, "subId": m.sub_id, "read": m.read,
                   "parts": m.parts.iter().map(|x| json!({"partId": x.part_id, "mimeType": x.mime_type, "size": x.size})).collect::<Vec<_>>()})
        })
    });
}

#[test]
fn send_status() {
    reads("smsSendStatus", |p| decode_send_status(p).map(|s| json!({"requestId": s.request_id, "status": s.status, "reason": s.reason, "via": s.via})));
}

#[test]
fn mark_read_result() {
    reads("smsMarkReadResult", |p| {
        decode_mark_read_result(p).map(|r| json!({"requestId": r.request_id, "results": r.results.iter().map(|(t, o)| json!({"threadId": t, "result": o})).collect::<Vec<_>>(), "error": r.error}))
    });
}

#[test]
fn blocked_numbers_result() {
    reads("smsBlockedNumbersResult", |p| decode_blocked_numbers_result(p).map(|(id, r)| json!({"requestId": id, "result": r})));
}

#[test]
fn changed() {
    reads("smsChanged", |p| decode_changed(p).map(|c| json!({"cursor": c})));
}

#[test]
fn threads_page() {
    reads("smsThreadsPage", |p| {
        decode_threads_page(p).map(|page| {
            let threads: Vec<Value> = page
                .threads
                .iter()
                .map(|t| json!({"threadId": t.thread_id, "snippet": t.snippet, "date": t.date, "unread": t.unread, "subId": t.sub_id, "participants": t.participants}))
                .collect();
            json!({"requestId": page.request_id, "threads": threads, "more": page.more, "error": page.error})
        })
    });
}

#[test]
fn attachment_data() {
    use base64::Engine;
    reads("smsAttachmentData", |p| {
        decode_attachment(p).map(|a| {
            json!({"requestId": a.request_id, "partId": a.part_id, "data": a.data.map(|d| base64::engine::general_purpose::STANDARD.encode(d)), "width": a.width, "height": a.height, "error": a.error})
        })
    });
}

#[test]
fn contacts_result() {
    reads("smsContactsResult", |p| {
        decode_contacts_result(p).map(|r| {
            json!({"requestId": r.request_id, "contacts": r.contacts.iter().map(|c| json!({"name": c.name, "address": c.address, "label": c.label})).collect::<Vec<_>>(), "error": r.error})
        })
    });
}

/// Every request the phone accepts, this device writes the same way from the decoded values.
#[test]
fn requests_as_this_device_writes_them() {
    let mut checked = 0;
    let mut failed = Vec::new();
    for v in vectors("smsRequest") {
        let Some(expect) = v["expect"].as_object() else { continue };
        checked += 1;
        let id = expect["requestId"].as_str().unwrap();
        let int = |k: &str| expect.get(k).and_then(Value::as_i64);
        let written = match v["kind"].as_str().unwrap() {
            "sms.threads" => Some(threads_request(id, int("before"), int("limit").unwrap())),
            "sms.messages" => {
                let before = expect.get("before").and_then(Value::as_object).map(|b| (b["date"].as_i64().unwrap(), b["id"].as_str().unwrap().to_string()));
                Some(messages_request(id, int("threadId").unwrap(), before.as_ref().map(|(d, m)| (*d, m.as_str())), int("limit").unwrap()))
            }
            "sms.sync" => {
                let since = &expect["since"];
                Some(sync_request(id, Cursor { sms: since["sms"].as_i64().unwrap(), mms: since["mms"].as_i64().unwrap() }, int("limit").unwrap()))
            }
            "sms.attachment" => Some(attachment_request(id, expect["partId"].as_str().unwrap())),
            "sms.contacts" => contacts_request(id, expect["query"].as_str().unwrap()),
            "sms.mark_read" => mark_read_request(id, &expect["threadIds"].as_array().unwrap().iter().map(|t| t.as_i64().unwrap()).collect::<Vec<_>>()),
            "sms.blocked_numbers" => Some(blocked_numbers_request(id, expect.get("address").and_then(Value::as_str))),
            other => panic!("{other}"),
        };
        let Some(Value::Object(mut written)) = written else {
            failed.push(v["name"].to_string());
            continue;
        };
        for key in expect.keys() {
            written.entry(key.clone()).or_insert(Value::Null);
        }
        written.remove("version");
        if Value::Object(written) != Value::Object(expect.clone()) {
            failed.push(v["name"].to_string());
        }
    }
    assert!(failed.is_empty(), "{failed:?}");
    assert!(checked >= 17);
}

/// Sends the phone accepts are what this device writes; malformed bodies and numbers never leave it.
#[test]
fn send_as_this_device_writes_it() {
    const ID: &str = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293";
    let mut failed = Vec::new();
    for v in vectors("smsSend") {
        let ok = match v["expect"].as_object() {
            None => {
                let p = &v["plaintext"];
                match p.get("body").and_then(Value::as_str) {
                    None => true,
                    Some(body) if !is_sendable_body(body) => send_request(ID, body, &Target::Thread(1), None).is_none(),
                    Some(body) => match (p.get("address").and_then(Value::as_str), p.get("threadId"), p.get("notificationId")) {
                        (Some(address), None, None) => send_request(ID, body, &Target::Address(address.into()), None).is_none(),
                        _ => true,
                    },
                }
            }
            Some(expect) => {
                let target = if let Some(t) = expect["threadId"].as_i64() {
                    Target::Thread(t)
                } else if let Some(a) = expect["address"].as_str() {
                    Target::Address(a.into())
                } else {
                    Target::Notification(expect["notificationId"].as_str().unwrap().into())
                };
                match send_request(expect["requestId"].as_str().unwrap(), expect["body"].as_str().unwrap(), &target, expect["subId"].as_i64()) {
                    Some(Value::Object(mut written)) => {
                        written.remove("version");
                        for key in ["threadId", "address", "notificationId", "subId"] {
                            written.entry(key).or_insert(Value::Null);
                        }
                        Value::Object(written) == Value::Object(expect.clone())
                    }
                    _ => false,
                }
            }
        };
        if !ok {
            failed.push(v["name"].to_string());
        }
    }
    assert!(failed.is_empty(), "{failed:?}");
}

fn thread(id: i64, date: i64, unread: i64) -> Thread {
    Thread { thread_id: id, participants: vec![Participant { address: format!("+44{id}"), name: None }], snippet: String::new(), date, unread, sub_id: None }
}

fn message(id: &str, thread: i64, date: i64, incoming: bool, read: bool) -> Message {
    Message {
        id: id.into(),
        thread_id: thread,
        direction: if incoming { "in" } else { "out" }.into(),
        status: if incoming { "received" } else { "sent" }.into(),
        date,
        address: "+441".into(),
        body: id.into(),
        truncated: false,
        sub_id: None,
        read,
        parts: vec![],
    }
}

#[test]
fn newest_page_replaces_what_it_covers() {
    let mut cache = Cache::default();
    cache.apply_threads(&[thread(1, 300, 0), thread(2, 200, 0), thread(3, 100, 0)], true, true);
    // Conversation 2 went on the phone: the newest page no longer has it.
    cache.apply_threads(&[thread(1, 310, 1), thread(3, 100, 0)], true, true);
    assert_eq!(cache.threads.iter().map(|t| t.thread_id).collect::<Vec<_>>(), vec![1, 3]);
    // An older page only adds.
    cache.apply_threads(&[thread(9, 50, 0)], false, false);
    assert_eq!(cache.threads.len(), 3);
    assert!(!cache.threads_more);
}

#[test]
fn at_most_200_conversations() {
    let mut cache = Cache::default();
    let page: Vec<Thread> = (1..=250).map(|i| thread(i, i * 10, 0)).collect();
    cache.apply_threads(&page, true, false);
    assert_eq!(cache.threads.len(), MAX_THREADS);
    assert!(cache.threads_more);
    assert_eq!(cache.threads[0].thread_id, 250);
}

#[test]
fn messages_page_replaces_its_span_and_updates_the_line() {
    let mut cache = Cache::default();
    cache.apply_threads(&[thread(1, 100, 0)], true, false);
    cache.apply_messages(&[message("s3", 1, 100, true, true), message("s2", 1, 90, true, true), message("s1", 1, 80, false, true)], 1, None, false);
    assert_eq!(cache.messages_in(1).len(), 3);
    // s2 deleted on the phone, and a new unread one arrived.
    cache.apply_messages(&[message("s4", 1, 120, true, false), message("s3", 1, 100, true, true), message("s1", 1, 80, false, true)], 1, None, false);
    let ids: Vec<&str> = cache.messages_in(1).iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, vec!["s4", "s3", "s1"]);
    assert_eq!(cache.thread(1).unwrap().date, 120);
    assert_eq!(cache.thread(1).unwrap().unread, 1);
    assert_eq!(cache.thread(1).unwrap().snippet, "s4");
}

#[test]
fn sync_adds_counts_and_names_unknown_conversations() {
    let mut cache = Cache::default();
    cache.apply_threads(&[thread(1, 100, 0)], true, false);
    let unknown = cache.apply_sync(&[message("s5", 1, 150, true, false), message("s6", 2, 160, true, false)]);
    assert_eq!(unknown, HashSet::from([2]));
    assert_eq!(cache.thread(1).unwrap().unread, 1);
    // The same message again is not counted twice.
    cache.apply_sync(&[message("s5", 1, 150, true, false)]);
    assert_eq!(cache.thread(1).unwrap().unread, 1);
}

#[test]
fn read_here_and_unread_first() {
    let mut cache = Cache::default();
    cache.apply_threads(&[thread(1, 300, 0), thread(2, 200, 2), thread(3, 100, 0)], true, false);
    cache.apply_messages(&[message("s2", 2, 200, true, false), message("s1", 2, 190, true, false)], 2, None, false);
    let order: Vec<i64> = cache.rows(false, None).iter().map(|(t, _)| t.thread_id).collect();
    assert_eq!(order, vec![2, 1, 3], "unread first, then newest");
    cache.mark_read(2, cache.newest_incoming_date(&cache.thread(2).unwrap().clone()));
    assert_eq!(cache.unread(cache.thread(2).unwrap()), 0);
    assert_eq!(cache.rows(false, None).iter().map(|(t, _)| t.thread_id).collect::<Vec<_>>(), vec![1, 2, 3]);
    // A newer message after reading counts again.
    cache.apply_sync(&[message("s9", 2, 400, true, false)]);
    assert_eq!(cache.unread(cache.thread(2).unwrap()), 1);
    cache.mark_unread(3);
    assert_eq!(cache.unread(cache.thread(3).unwrap()), 1);
    assert_eq!(cache.rows(true, None).len(), 2);
    // The phone caught up: the read point goes.
    cache.apply_threads(&[thread(2, 400, 0)], false, false);
    cache.reconcile();
    assert!(!cache.read_through.contains_key(&2));
}

#[test]
fn numbers() {
    assert_eq!(normalized_address("+91 98765-43210").as_deref(), Some("+919876543210"));
    assert_eq!(normalized_address("(022) 555.0101").as_deref(), Some("0225550101"));
    assert!(normalized_address("1").is_none());
    assert!(normalized_address("*123#").is_none());
    assert!(same_number("+447700900123", "07700 900123"));
    assert!(!same_number("+447700900123", "+447700900124"));
}

#[test]
fn the_cache_round_trips() {
    let mut cache = Cache { version: 1, cursor: Some(Cursor { sms: 3, mms: 1 }), ..Default::default() };
    cache.apply_threads(&[thread(1, 100, 1)], true, false);
    cache.apply_messages(&[message("s1", 1, 100, true, false)], 1, None, false);
    cache.mark_read(1, 100);
    let back: Cache = serde_json::from_slice(&serde_json::to_vec(&cache).unwrap()).unwrap();
    assert_eq!(back, cache);
}
