use super::*;
use serde_json::{json, Value};

fn inputs() -> InputCapabilities {
    InputCapabilities { pointer: true, touch: true, keys: true, text: true, navigation: true }
}

fn authority() -> Authority {
    Authority {
        generation: 1,
        binding: Binding { peer: PeerIdentity { device: [1; 16], key_sha256: [2; 32] }, transport: 1, connection: [7; 16] },
        stream: 4,
        trusted_device: true,
        view_grant: true,
        control_grant: true,
        capture_ready: true,
        input_ready: true,
        unlocked: true,
        stream_active: true,
        host: Capabilities {
            v: VERSION,
            screen_source: true,
            full_display_source: true,
            h264_encode: true,
            input_host: inputs(),
            capture_requires_prompt: true,
            ..Capabilities::default()
        },
        controller: Capabilities {
            v: VERSION,
            screen_viewer: true,
            h264_decode: true,
            input_controller: inputs(),
            ..Capabilities::default()
        },
    }
}

fn geometry() -> Geometry {
    Geometry { generation: 1, source: 9, kind: SourceKind::Display, width: 1920, height: 1080 }
}

fn packet(info: SessionInfo, seq: u64, input: Input) -> Packet {
    Packet {
        v: VERSION,
        session: info.session,
        transport: info.transport,
        connection: info.connection,
        stream: info.stream,
        geometry: info.geometry.generation,
        seq,
        input,
    }
}

fn ready() -> (HostSession, Authority, SessionInfo) {
    let mut host = HostSession::default();
    let authority = authority();
    let info = host.begin(authority, geometry(), 0).unwrap();
    assert_eq!(host.receive(authority, authority.binding, &packet(info, 1, Input::GeometryAck {}), 0).status, Status::Accepted);
    (host, authority, info)
}

#[test]
fn golden_wire_capabilities_geometry_and_packets() {
    let fixture: Value = serde_json::from_str(include_str!("../../test-vectors/screen-control-v1.json")).unwrap();
    assert_eq!(fixture["protocol"], PROTOCOL);
    let local = authority();
    for (name, expected) in [("host", local.host), ("controller", local.controller)] {
        let bytes = serde_json::to_vec(&fixture[name]).unwrap();
        assert_eq!(Capabilities::decode(&bytes), Ok(expected));
        assert_eq!(serde_json::to_value(expected).unwrap(), fixture[name]);
    }
    assert_eq!(serde_json::to_value(geometry()).unwrap(), fixture["geometry"]);
    let mut host = HostSession::default();
    let info = host.begin(local, geometry(), 0).unwrap();
    for (index, value) in fixture["packets"].as_array().unwrap().iter().enumerate() {
        let decoded = Packet::decode(&serde_json::to_vec(value).unwrap()).unwrap();
        assert_eq!(serde_json::to_value(&decoded).unwrap(), *value);
        assert_eq!(decoded.seq, index as u64 + 1);
        assert_eq!(host.receive(local, local.binding, &decoded, index as u64).status, Status::Accepted);
    }
    assert_eq!(info.session, 1);
    assert_eq!(geometry().pixel(0.25, 0.75), Some(PixelPoint { x: 480, y: 809 }));
    for value in fixture["invalidPackets"].as_array().unwrap() {
        assert!(Packet::decode(&serde_json::to_vec(value).unwrap()).is_err());
    }
}

#[test]
fn unknown_capabilities_never_create_permission_or_assume_platform_roles() {
    let missing = Capabilities::decode(br#"{"v":1,"futureCapability":true}"#).unwrap();
    assert_eq!(missing.input_host, InputCapabilities::default());
    assert!(!missing.screen_source);
    assert_eq!(Capabilities::negotiated_input(missing, authority().controller), Err(Rejection::Unsupported));
    assert_eq!(Capabilities::decode(br#"{"v":2,"screenSource":true}"#), Err(Rejection::Version));
    assert_eq!(Capabilities::decode(br#"{"screenSource":true}"#), Err(Rejection::Version));
    assert_eq!(Capabilities::decode(br#"{"v":1,"screenSource":"yes"}"#), Err(Rejection::Malformed));
    assert_eq!(Capabilities::decode(&vec![b' '; MAX_PACKET_BYTES + 1]), Err(Rejection::PacketSize));
}

#[test]
fn negotiated_roles_intersect_without_inventing_text_support() {
    let mut local = authority();
    local.host.input_host.text = false; // e.g. an older native adapter with gestures/navigation.
    let input = Capabilities::negotiated_input(local.host, local.controller).unwrap();
    assert!(!input.text);
    assert!(input.pointer && input.navigation);
    local.host.input_host = InputCapabilities::default(); // e.g. public iOS host APIs.
    assert_eq!(Capabilities::negotiated_input(local.host, local.controller), Err(Rejection::Unsupported));
}

#[test]
fn pairing_or_an_os_permission_alone_does_not_grant_control() {
    for change in 0..8 {
        let mut local = authority();
        match change {
            0 => local.trusted_device = false,
            1 => local.view_grant = false,
            2 => local.control_grant = false,
            3 => local.capture_ready = false,
            4 => local.input_ready = false,
            5 => local.unlocked = false,
            6 => local.stream_active = false,
            _ => local.binding.peer.key_sha256 = [0; 32],
        }
        assert!(HostSession::default().begin(local, geometry(), 0).is_err(), "case {change}");
    }
}

#[test]
fn authority_counters_and_transport_nonce_are_required() {
    for invalid in [0, MAX_SEQUENCE + 1, u64::MAX] {
        for field in 0..3 {
            let mut local = authority();
            match field {
                0 => local.generation = invalid,
                1 => local.binding.transport = invalid,
                _ => local.stream = invalid,
            }
            assert_eq!(HostSession::default().begin(local, geometry(), 0), Err(Rejection::Counter));
        }
    }
    let mut local = authority();
    local.binding.connection = [0; 16];
    assert_eq!(HostSession::default().begin(local, geometry(), 0), Err(Rejection::Binding));
}

#[test]
fn exact_pinned_sender_and_current_transport_are_required_without_stopping_another_peer() {
    let (mut host, local, info) = ready();
    let input = packet(info, 2, Input::Pointer { x: 0.2, y: 0.8 });
    for field in 0..4 {
        let mut sender = local.binding;
        match field {
            0 => sender.peer.device[0] ^= 1,
            1 => sender.peer.key_sha256[0] ^= 1,
            2 => sender.transport += 1,
            _ => sender.connection[0] ^= 1,
        }
        assert_eq!(host.receive(local, sender, &input, 0).status, Status::Rejected(Rejection::Binding));
        assert_eq!(host.info(), Some(info));
    }
    assert_eq!(host.receive(local, local.binding, &input, 0).status, Status::Accepted);
}

#[test]
fn a_process_restart_cannot_reuse_an_old_packet_on_a_new_transport() {
    let (_, local, old_info) = ready();
    let old = packet(old_info, 1, Input::GeometryAck {});
    let mut restarted = HostSession::default();
    let mut new_local = local;
    new_local.binding.connection = [8; 16];
    let new_info = restarted.begin(new_local, geometry(), 0).unwrap();
    assert_eq!(new_info.session, old_info.session, "counter reuse alone must not authorize old packets");
    assert_eq!(restarted.receive(new_local, new_local.binding, &old, 0).status, Status::Rejected(Rejection::Binding));
    let mut fresh = old;
    fresh.connection = new_local.binding.connection;
    assert_eq!(restarted.receive(new_local, new_local.binding, &fresh, 0).status, Status::Accepted);
}

#[test]
fn revocation_ends_holds_and_old_authority_cannot_reenable_it() {
    let (mut host, local, info) = ready();
    assert_eq!(
        host.receive(local, local.binding, &packet(info, 2, Input::Key { key: Key::Shift, down: true }), 0).status,
        Status::Accepted
    );
    let mut revoked = local;
    revoked.generation = 2;
    revoked.control_grant = false;
    let stopped = host.synchronize(revoked);
    assert_eq!(stopped.status, Status::Stopped(StopReason::Revoked));
    assert_ne!(stopped.release.keys, 0);
    assert_eq!(host.begin(local, geometry(), 0), Err(Rejection::AuthorityReplay));
    assert_eq!(host.stop(StopReason::User).release, HeldInput::default());
    let mut regranted = local;
    regranted.generation = 3;
    assert!(host.begin(regranted, geometry(), 0).is_ok());
    let current = host.info();
    assert_eq!(host.synchronize(local).status, Status::Rejected(Rejection::AuthorityReplay));
    assert_eq!(host.info(), current, "an obsolete callback cannot stop the newer authorized session");
}

#[test]
fn reusing_an_authority_generation_burns_it_instead_of_restoring_a_stale_grant() {
    let (mut host, local, _) = ready();
    let mut changed_without_new_generation = local;
    changed_without_new_generation.control_grant = false;
    assert_eq!(host.synchronize(changed_without_new_generation).status, Status::Stopped(StopReason::AuthorityChanged));
    assert_eq!(host.begin(local, geometry(), 0), Err(Rejection::AuthorityReplay));
    let mut fresh = local;
    fresh.generation += 1;
    assert!(host.begin(fresh, geometry(), 0).is_ok());
}

#[test]
fn stop_fences_a_pending_native_begin_before_any_active_session_exists() {
    let mut host = HostSession::default();
    let local = authority();
    assert_eq!(host.synchronize(local).status, Status::Accepted);
    assert_eq!(host.stop(StopReason::User).release, HeldInput::default());
    assert_eq!(host.begin(local, geometry(), 0), Err(Rejection::AuthorityReplay));
    let mut fresh = local;
    fresh.generation += 1;
    assert!(host.begin(fresh, geometry(), 0).is_ok());
}

#[test]
fn a_wrong_geometry_release_cannot_leave_native_input_held_by_heartbeats() {
    let transitions = [
        (
            Input::Button { button: Button::Primary, down: true, x: 0.5, y: 0.5 },
            Input::Button { button: Button::Primary, down: false, x: 0.5, y: 0.5 },
        ),
        (Input::Key { key: Key::Shift, down: true }, Input::Key { key: Key::Shift, down: false }),
        (
            Input::Touch { contact: 0, phase: TouchPhase::Down, x: 0.5, y: 0.5 },
            Input::Touch { contact: 0, phase: TouchPhase::Up, x: 0.5, y: 0.5 },
        ),
    ];
    for (down, up) in transitions {
        let (mut host, local, info) = ready();
        assert_eq!(host.receive(local, local.binding, &packet(info, 2, down), 0).status, Status::Accepted);
        let held = host.held();
        assert!(!held.is_empty());
        let mut stale = packet(info, 3, up);
        stale.geometry += 1;
        let stopped = host.receive(local, local.binding, &stale, 0);
        assert_eq!(stopped.status, Status::Stopped(StopReason::GeometryInvalid));
        assert_eq!(stopped.release, held);
        assert!(host.held().is_empty());
        assert_ne!(host.receive(local, local.binding, &packet(info, 4, Input::Heartbeat {}), 1).status, Status::Accepted);
        assert!(host.info().is_none());
    }
}

#[test]
fn an_old_capture_callback_cannot_resize_or_stop_a_new_control_session() {
    let (mut host, local, old) = ready();
    host.stop(StopReason::User);
    let mut fresh = local;
    fresh.generation += 1;
    fresh.stream += 1;
    let current = host.begin(fresh, geometry(), 0).unwrap();
    let resized = Geometry { generation: 2, width: 1080, height: 1920, ..geometry() };
    assert_eq!(host.geometry_changed(old, resized).status, Status::Rejected(Rejection::Session));
    assert_eq!(host.info(), Some(current));
    let mut wrong_channel = current;
    wrong_channel.connection[0] ^= 1;
    assert_eq!(host.geometry_changed(wrong_channel, resized).status, Status::Rejected(Rejection::Session));
    assert_eq!(host.info(), Some(current));
    assert_eq!(host.geometry_changed(current, resized).status, Status::Accepted);
}

#[test]
fn changed_permission_lock_stream_or_binding_stops_before_next_input() {
    for field in 0..5 {
        let (mut host, local, info) = ready();
        let mut changed = local;
        changed.generation += 1;
        match field {
            0 => changed.capture_ready = false,
            1 => changed.input_ready = false,
            2 => changed.unlocked = false,
            3 => changed.stream_active = false,
            _ => changed.binding.transport += 1,
        }
        assert!(matches!(
            host.receive(changed, local.binding, &packet(info, 2, Input::Pointer { x: 0.5, y: 0.5 }), 0).status,
            Status::Stopped(_)
        ));
        assert!(host.info().is_none());
    }
}

#[test]
fn resize_releases_holds_and_requires_new_geometry_ack() {
    let (mut host, local, info) = ready();
    host.receive(local, local.binding, &packet(info, 2, Input::Button { button: Button::Primary, down: true, x: 0.25, y: 0.75 }), 0);
    let changed = Geometry { generation: 2, width: 1080, height: 1920, ..geometry() };
    let resized = host.geometry_changed(info, changed);
    assert_eq!(resized.status, Status::Accepted);
    assert_eq!(resized.release.buttons, 1);
    assert!(host.held().is_empty());
    assert_eq!(
        host.receive(local, local.binding, &packet(info, 3, Input::Pointer { x: 0.5, y: 0.5 }), 0).status,
        Status::Rejected(Rejection::Geometry)
    );
    let current = host.info().unwrap();
    assert_eq!(
        host.receive(local, local.binding, &packet(current, 4, Input::Pointer { x: 0.5, y: 0.5 }), 0).status,
        Status::Rejected(Rejection::GeometryNotAcknowledged)
    );
    assert_eq!(host.receive(local, local.binding, &packet(current, 5, Input::GeometryAck {}), 0).status, Status::Accepted);
    assert_eq!(host.receive(local, local.binding, &packet(current, 6, Input::Pointer { x: 0.5, y: 0.5 }), 0).status, Status::Accepted);
}

#[test]
fn replacing_the_source_or_reusing_geometry_generation_stops_instead_of_retargeting() {
    for changed in [
        Geometry { generation: 2, source: 10, ..geometry() },
        Geometry { generation: 2, kind: SourceKind::Window, ..geometry() },
        Geometry { width: 1080, height: 1920, ..geometry() },
        Geometry { generation: 2, width: 0, ..geometry() },
    ] {
        let (mut host, _, info) = ready();
        assert!(matches!(host.geometry_changed(info, changed).status, Status::Stopped(_)));
        assert!(host.info().is_none());
    }
    let (mut host, _, info) = ready();
    host.geometry_changed(info, Geometry { generation: 2, ..geometry() });
    assert_eq!(host.geometry_changed(info, geometry()).status, Status::Rejected(Rejection::Geometry));
    assert_eq!(host.info().unwrap().geometry.generation, 2);
}

#[test]
fn full_display_geometry_is_required_without_assuming_app_capture_coordinates() {
    for bad in [
        Geometry { kind: SourceKind::Window, ..geometry() },
        Geometry { width: 0, ..geometry() },
        Geometry { height: 0, ..geometry() },
        Geometry { width: MAX_DIMENSION + 1, ..geometry() },
        Geometry { width: MAX_DIMENSION, height: MAX_DIMENSION, ..geometry() },
        Geometry { generation: 0, ..geometry() },
    ] {
        assert_eq!(HostSession::default().begin(authority(), bad, 0), Err(Rejection::Geometry));
    }
}

#[test]
fn nonfinite_or_outside_points_never_map_to_another_display() {
    let (mut host, local, info) = ready();
    for (index, value) in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.001, 1.001].into_iter().enumerate() {
        assert!(geometry().pixel(value, 0.5).is_none());
        assert_eq!(
            host.receive(local, local.binding, &packet(info, index as u64 + 2, Input::Pointer { x: value, y: 0.5 }), 0).status,
            Status::Rejected(Rejection::Coordinates)
        );
    }
    assert_eq!(geometry().pixel(0.0, 0.0), Some(PixelPoint { x: 0, y: 0 }));
    assert_eq!(geometry().pixel(1.0, 1.0), Some(PixelPoint { x: 1919, y: 1079 }));
}

#[test]
fn deterministic_coordinate_boundary_corpus_stays_inside_selected_pixels() {
    let mut seed = 0x94d0_49bb_1331_11eb_u64;
    for _ in 0..2_000 {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
        let x = ((seed >> 32) as u32) as f64 / u32::MAX as f64;
        let y = (seed as u32) as f64 / u32::MAX as f64;
        let point = geometry().pixel(x, y).unwrap();
        assert!(point.x < geometry().width && point.y < geometry().height);
        assert!(geometry().pixel(x + 1.000_001, y).is_none());
    }
}

#[test]
fn buttons_and_scroll_have_their_own_position_not_a_stale_pointer_cache() {
    let (mut host, local, info) = ready();
    // A click is valid after geometry ACK without a preceding pointer packet.
    assert_eq!(
        host.receive(local, local.binding, &packet(info, 2, Input::Button { button: Button::Primary, down: true, x: 0.8, y: 0.2 }), 0)
            .status,
        Status::Accepted
    );
    assert_eq!(
        host.receive(
            local,
            local.binding,
            &packet(info, 3, Input::Button { button: Button::Primary, down: false, x: f64::NAN, y: 0.2 }),
            0
        )
        .status,
        Status::Stopped(StopReason::InvalidInput)
    );
    assert!(host.held().is_empty());
    let (mut host, local, info) = ready();
    assert_eq!(
        host.receive(local, local.binding, &packet(info, 2, Input::Scroll { dx: 0, dy: 10, x: -0.1, y: 0.5 }), 0).status,
        Status::Rejected(Rejection::Coordinates)
    );
    let mut wire = serde_json::to_value(packet(info, 5, Input::Button { button: Button::Primary, down: false, x: 0.8, y: 0.2 })).unwrap();
    wire["input"].as_object_mut().unwrap().remove("x");
    assert_eq!(Packet::decode(&serde_json::to_vec(&wire).unwrap()), Err(Rejection::Malformed));
}

#[test]
fn text_is_stopped_if_native_focus_is_outside_the_selected_source() {
    let (mut host, local, info) = ready();
    let mut ineligible = local;
    ineligible.generation += 1;
    ineligible.input_ready = false;
    assert_eq!(
        host.receive(ineligible, local.binding, &packet(info, 2, Input::Text { text: "synthetic text".into() }), 0).status,
        Status::Stopped(StopReason::PermissionLost)
    );
    assert!(host.info().is_none());
}

#[test]
fn stop_returns_all_held_native_inputs_once() {
    let (mut host, local, info) = ready();
    for (index, input) in [
        Input::Button { button: Button::Primary, down: true, x: 0.25, y: 0.75 },
        Input::Key { key: Key::Control, down: true },
        Input::Touch { contact: 3, phase: TouchPhase::Down, x: 0.2, y: 0.3 },
    ]
    .into_iter()
    .enumerate()
    {
        assert_eq!(host.receive(local, local.binding, &packet(info, index as u64 + 2, input), 0).status, Status::Accepted);
    }
    let held = host.held();
    assert_ne!(held.buttons, 0);
    assert_ne!(held.keys, 0);
    assert_eq!(held.contacts, 1 << 3);
    assert_eq!(host.stop(StopReason::Disconnected).release, held);
    assert!(host.stop(StopReason::User).release.is_empty());
    assert!(host.info().is_none());
}

#[test]
fn invalid_hold_transitions_do_not_inject_duplicate_or_unmatched_events() {
    let (mut host, local, info) = ready();
    let commands = [
        Input::Button { button: Button::Primary, down: false, x: 0.25, y: 0.75 },
        Input::Key { key: Key::Alt, down: false },
        Input::Touch { contact: 0, phase: TouchPhase::Move, x: 0.2, y: 0.3 },
        Input::Touch { contact: 10, phase: TouchPhase::Down, x: 0.2, y: 0.3 },
    ];
    for (index, command) in commands.into_iter().enumerate() {
        assert!(matches!(host.receive(local, local.binding, &packet(info, index as u64 + 2, command), 0).status, Status::Rejected(_)));
        assert!(host.held().is_empty());
    }
}

#[test]
fn duplicate_packets_and_old_session_ids_cannot_inject_again() {
    let (mut host, local, info) = ready();
    let input = packet(info, 2, Input::Pointer { x: 0.3, y: 0.4 });
    assert_eq!(host.receive(local, local.binding, &input, 0).status, Status::Accepted);
    assert_eq!(host.receive(local, local.binding, &input, 0).status, Status::Rejected(Rejection::Replay));
    host.stop(StopReason::User);
    assert_eq!(host.begin(local, geometry(), 0), Err(Rejection::AuthorityReplay));
    let mut fresh = local;
    fresh.generation += 1;
    let new_info = host.begin(fresh, geometry(), 0).unwrap();
    assert!(new_info.session > info.session);
    assert_eq!(host.receive(fresh, fresh.binding, &input, 0).status, Status::Rejected(Rejection::Session));
}

#[test]
fn a_gap_on_the_ordered_control_lane_releases_holds() {
    let (mut host, local, info) = ready();
    host.receive(local, local.binding, &packet(info, 2, Input::Key { key: Key::Shift, down: true }), 0);
    let result = host.receive(local, local.binding, &packet(info, 4, Input::Heartbeat {}), 0);
    assert_eq!(result.status, Status::Stopped(StopReason::SequenceGap));
    assert_ne!(result.release.keys, 0);
}

#[test]
fn pointer_rate_limit_does_not_block_stop() {
    let (mut host, local, info) = ready();
    for seq in 2..122 {
        assert_eq!(host.receive(local, local.binding, &packet(info, seq, Input::Pointer { x: 0.5, y: 0.5 }), 0).status, Status::Accepted);
    }
    assert_eq!(
        host.receive(local, local.binding, &packet(info, 122, Input::Pointer { x: 0.5, y: 0.5 }), 0).status,
        Status::Rejected(Rejection::Rate)
    );
    assert_eq!(host.receive(local, local.binding, &packet(info, 123, Input::Stop {}), 0).status, Status::Stopped(StopReason::User));
}

#[test]
fn a_rate_limited_discrete_transition_releases_instead_of_sticking_a_button() {
    let (mut host, local, info) = ready();
    host.receive(local, local.binding, &packet(info, 2, Input::Button { button: Button::Primary, down: true, x: 0.25, y: 0.75 }), 0);
    for seq in 3..22 {
        assert_eq!(host.receive(local, local.binding, &packet(info, seq, Input::Text { text: "a".into() }), 0).status, Status::Accepted);
    }
    let result =
        host.receive(local, local.binding, &packet(info, 22, Input::Button { button: Button::Primary, down: false, x: 0.25, y: 0.75 }), 0);
    assert_eq!(result.status, Status::Stopped(StopReason::RateLimited));
    assert_eq!(result.release.buttons, 1);
}

#[test]
fn invalid_inputs_do_not_extend_the_six_second_liveness_deadline() {
    let (mut host, local, info) = ready();
    assert_eq!(
        host.receive(local, local.binding, &packet(info, 2, Input::Pointer { x: f64::NAN, y: 0.5 }), 5_900).status,
        Status::Rejected(Rejection::Coordinates)
    );
    assert_eq!(host.tick(6_000).status, Status::Stopped(StopReason::Timeout));
    let (mut host, local, info) = ready();
    assert_eq!(host.receive(local, local.binding, &packet(info, 2, Input::Heartbeat {}), 5_000).status, Status::Accepted);
    assert_eq!(host.tick(10_999).status, Status::Accepted);
    assert_eq!(host.tick(11_000).status, Status::Stopped(StopReason::Timeout));
}

#[test]
fn monotonic_clock_reversal_stops_and_never_refills_an_extra_budget() {
    let (mut host, local, info) = ready();
    assert_eq!(host.receive(local, local.binding, &packet(info, 2, Input::Heartbeat {}), 100).status, Status::Accepted);
    assert_eq!(host.tick(99).status, Status::Stopped(StopReason::Clock));
}

#[test]
fn counters_fail_closed_at_json_safe_limits_without_wrapping() {
    let mut host = HostSession::default();
    host.last_session = MAX_SEQUENCE;
    assert_eq!(host.begin(authority(), geometry(), 0), Err(Rejection::Exhausted));
    let (mut host, local, info) = ready();
    host.active.as_mut().unwrap().sequence = MAX_SEQUENCE - 1;
    assert_eq!(
        host.receive(local, local.binding, &packet(info, MAX_SEQUENCE, Input::Key { key: Key::Shift, down: true }), 0).status,
        Status::Stopped(StopReason::Exhausted)
    );
    assert!(host.held().is_empty());
    for invalid in [0, MAX_SEQUENCE + 1, u64::MAX] {
        let mut value = serde_json::to_value(packet(info, 2, Input::Heartbeat {})).unwrap();
        value["seq"] = json!(invalid);
        assert_eq!(Packet::decode(&serde_json::to_vec(&value).unwrap()), Err(Rejection::Counter));
    }
}

#[test]
fn text_scroll_and_operation_decoding_have_explicit_bounds() {
    let (mut host, local, info) = ready();
    for (index, input) in [
        Input::Text { text: "a".repeat(MAX_TEXT_SCALARS + 1) },
        Input::Text { text: "\n".into() },
        Input::Text { text: "".into() },
        Input::Scroll { dx: i32::MIN, dy: 1, x: 0.25, y: 0.75 },
        Input::Scroll { dx: 0, dy: 0, x: 0.25, y: 0.75 },
    ]
    .into_iter()
    .enumerate()
    {
        assert_eq!(
            host.receive(local, local.binding, &packet(info, index as u64 + 2, input), 0).status,
            Status::Rejected(Rejection::InvalidInput)
        );
    }
    assert_eq!(Packet::decode(&vec![b' '; MAX_PACKET_BYTES + 1]), Err(Rejection::PacketSize));
    let mut value = serde_json::to_value(packet(info, 1, Input::Heartbeat {})).unwrap();
    value["input"] = json!({"op":"shell","command":"forbidden"});
    assert_eq!(Packet::decode(&serde_json::to_vec(&value).unwrap()), Err(Rejection::Malformed));
    for operation in ["geometry_ack", "heartbeat", "stop"] {
        value["input"] = json!({"op":operation,"unexpected":true});
        assert_eq!(Packet::decode(&serde_json::to_vec(&value).unwrap()), Err(Rejection::Malformed));
    }
}

#[test]
fn debugging_a_packet_does_not_expose_typed_content() {
    let (_, _, info) = ready();
    let packet = packet(info, 2, Input::Text { text: "private typed fixture".into() });
    assert!(!format!("{packet:?}").contains("private typed fixture"));
}
