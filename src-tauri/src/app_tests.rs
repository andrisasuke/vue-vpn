use crate::{app::Backend, models::*, native, profile};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

#[derive(Default)]
struct Fake {
    sessions: Vec<Value>,
    saved: HashMap<String, String>,
    connections: Vec<(String, String)>,
    save_count: usize,
    disconnected: Vec<String>,
    allow_save: bool,
    build_id: Option<String>,
    service_status: String,
    replacements: usize,
    registrations: usize,
    snapshot_error: bool,
    cleanup_polls: usize,
    disconnecting: bool,
    cleanup_error: bool,
}
fn setup() -> (tempfile::TempDir, Backend, Arc<Mutex<Fake>>, String) {
    let fake = Arc::new(Mutex::new(Fake {
        allow_save: true,
        build_id: Some("test-current".into()),
        service_status: "enabled".into(),
        ..Fake::default()
    }));
    let handle = fake.clone();
    native::testing::install(Box::new(move |kind, input| {
        let mut f = handle.lock().unwrap();
        let op = input["op"].as_str().unwrap();
        Ok(match kind {
            "identity" => json!({"buildId":"test-current"}),
            "service" => {
                if op == "replace" {
                    f.replacements += 1;
                    f.service_status = "updating".into();
                }
                if op == "register_update" {
                    f.registrations += 1;
                    f.service_status = "enabled".into();
                    f.build_id = Some("test-current".into());
                }
                json!({"status":f.service_status,"message":"Mock helper"})
            }
            "keychain" => {
                let id = input["id"].as_str().unwrap().to_string();
                match op {
                    "set" => {
                        f.saved
                            .insert(id, input["secret"].as_str().unwrap().to_string());
                        f.save_count += 1;
                        json!({"found":true})
                    }
                    "get" => match f.saved.get(&id) {
                        Some(secret) => json!({"found":true,"secret":secret}),
                        None => json!({"found":false}),
                    },
                    "exists" => json!({"found":f.saved.contains_key(&id)}),
                    "delete" => {
                        f.saved.remove(&id);
                        json!({"found":true})
                    }
                    _ => panic!("Unexpected keychain operation"),
                }
            }
            "request" => match op {
                "snapshot" => {
                    if f.snapshot_error {
                        return Err(AppError::new("helper_unavailable", "Interrupted"));
                    }
                    if f.disconnecting {
                        if f.cleanup_polls == 0 {
                            let status = if f.cleanup_error {
                                "error"
                            } else {
                                "disconnected"
                            };
                            let error = f.cleanup_error;
                            for s in &mut f.sessions {
                                if s["status"] == "disconnecting" {
                                    s["status"] = json!(status);
                                    if error {
                                        s["errorCode"] = json!("cleanup_failed");
                                    }
                                }
                            }
                            f.disconnecting = false;
                        } else {
                            f.cleanup_polls -= 1;
                        }
                    }
                    json!({"buildId":f.build_id,"sessions":f.sessions})
                }
                "validate" => {
                    json!({"allowPasswordSave":f.allow_save,"autologin":false,"username":""})
                }
                "connect" => {
                    assert!(
                        !f.disconnecting,
                        "Must finish cleanup before connecting again"
                    );
                    let id = input["profileId"].as_str().unwrap().to_string();
                    f.connections
                        .push((id.clone(), input["password"].as_str().unwrap().into()));
                    f.sessions.retain(|s| s["profileId"] != id);
                    f.sessions.push(json!({"profileId":id,"sessionId":input["sessionId"],"status":"connecting"}));
                    json!({"ok":true})
                }
                "disconnect" => {
                    let id = input["profileId"].as_str().unwrap().to_string();
                    f.disconnected.push(id.clone());
                    let status = if f.cleanup_polls > 0 {
                        f.disconnecting = true;
                        "disconnecting"
                    } else {
                        "disconnected"
                    };
                    for s in &mut f.sessions {
                        if s["profileId"] == id {
                            s["status"] = json!(status);
                        }
                    }
                    json!({"ok":true})
                }
                "disconnect_all" => {
                    let status = if f.cleanup_polls > 0 {
                        f.disconnecting = true;
                        "disconnecting"
                    } else {
                        "disconnected"
                    };
                    for s in &mut f.sessions {
                        s["status"] = json!(status);
                    }
                    json!({"ok":true})
                }
                _ => panic!("Unexpected helper operation"),
            },
            _ => panic!("Unexpected native operation"),
        })
    }));
    let temp = tempfile::tempdir().unwrap();
    let mut b = Backend::new(temp.path().into()).unwrap();
    let imported = profile::parse(
        "client\ndev tun\nremote vpn.example.test\nauth-user-pass\n",
        None,
        "Development",
    )
    .unwrap();
    let id = imported.profile.id.clone();
    b.store
        .save(&imported.profile, Some(&imported.content))
        .unwrap();
    b.profiles.push(imported.profile);
    b.profiles[0].username = "demo".into();
    (temp, b, fake, id)
}
#[test]
fn saves_only_after_connected_and_never_exposes_password_in_snapshot() {
    let (_t, mut b, f, id) = setup();
    let secret = "unit-test-secret";
    b.connect(&id, Some(secret.into()), true).unwrap();
    assert!(f.lock().unwrap().saved.is_empty());
    f.lock().unwrap().sessions[0]["status"] = json!("connected");
    b.refresh().unwrap();
    b.refresh().unwrap();
    assert_eq!(f.lock().unwrap().saved.get(&id).unwrap(), secret);
    assert_eq!(f.lock().unwrap().save_count, 1);
    assert!(b.profiles[0].remembered);
    assert!(!serde_json::to_string(&b.snapshot())
        .unwrap()
        .contains(secret));
    assert!(
        !std::fs::read_to_string(b.store.profile_dir(&id).unwrap().join("profile.json"))
            .unwrap()
            .contains(secret)
    );
}
#[test]
fn forget_cancels_pending_remember_and_auth_failure_removes_bad_saved_password() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("test-pin".into()), true).unwrap();
    b.forget(&id).unwrap();
    f.lock().unwrap().sessions[0]["status"] = json!("connected");
    b.refresh().unwrap();
    assert!(f.lock().unwrap().saved.is_empty());
    f.lock()
        .unwrap()
        .saved
        .insert(id.clone(), "rejected".into());
    {
        let mut fake = f.lock().unwrap();
        fake.sessions[0]["status"] = json!("error");
        fake.sessions[0]["errorCode"] = json!("AUTH_FAILED");
    }
    b.refresh().unwrap();
    assert!(f.lock().unwrap().saved.is_empty());
    assert!(!b.profiles[0].remembered);
}
#[test]
fn missing_saved_credentials_requires_input_and_server_can_disallow_saving() {
    let (_t, mut b, f, id) = setup();
    assert_eq!(
        b.connect(&id, None, false).unwrap_err().code,
        "credentials_required"
    );
    assert!(f.lock().unwrap().connections.is_empty());
    f.lock().unwrap().allow_save = false;
    b.connect(&id, Some("test-pin".into()), true).unwrap();
    f.lock().unwrap().sessions[0]["status"] = json!("connected");
    b.refresh().unwrap();
    assert!(f.lock().unwrap().saved.is_empty());
    assert!(!b.profiles[0].allow_password_save);
}
#[test]
fn full_tunnel_conflict_is_rejected_before_connecting_another_profile() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("test-pin".into()), false).unwrap();
    let mut p = b.profiles[0].clone();
    p.id = uuid::Uuid::new_v4().to_string();
    b.store
        .save(
            &p,
            Some("client\nremote vpn.example.test\nauth-user-pass\n"),
        )
        .unwrap();
    b.profiles.push(p.clone());
    assert_eq!(
        b.connect(&p.id, Some("second-pin".into()), false)
            .unwrap_err()
            .code,
        "full_tunnel_conflict"
    );
    assert_eq!(f.lock().unwrap().connections.len(), 1);
}
#[test]
fn editing_network_settings_reconnects_only_that_profile_with_volatile_credential() {
    let (_t, mut b, f, id) = setup();
    b.profiles[0].routing_mode = RoutingMode::Selected;
    b.profiles[0].routes = vec![crate::policy::route("10.1.0.0".parse().unwrap(), 16).unwrap()];
    b.connect(&id, Some("memory-only".into()), false).unwrap();
    let mut second = b.profiles[0].clone();
    second.id = uuid::Uuid::new_v4().to_string();
    second.routes = vec![crate::policy::route("10.2.0.0".parse().unwrap(), 16).unwrap()];
    b.store
        .save(
            &second,
            Some("client\nremote vpn.example.test\nauth-user-pass\n"),
        )
        .unwrap();
    b.profiles.push(second.clone());
    b.connect(&second.id, Some("second".into()), false).unwrap();
    let p = b.profiles[0].clone();
    f.lock().unwrap().cleanup_polls = 2; // Reconnect must wait for asynchronous route cleanup.
    b.update(
        &id,
        ProfileUpdate {
            name: p.name,
            username: p.username,
            routing_mode: p.routing_mode,
            routes: vec![crate::policy::route("10.3.0.0".parse().unwrap(), 16).unwrap()],
            dns: p.dns,
            allow_legacy_cipher: false,
        },
    )
    .unwrap();
    let fake = f.lock().unwrap();
    assert_eq!(fake.disconnected, vec![id.clone()]);
    assert_eq!(
        fake.connections.last().unwrap(),
        &(id, "memory-only".into())
    );
    assert!(fake.saved.is_empty());
    assert!(b.active(&second.id));
}

#[test]
fn helper_update_preserves_active_session_then_runs_after_disconnect() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("saved-pin".into()), true).unwrap();
    {
        let mut fake = f.lock().unwrap();
        fake.sessions[0]["status"] = json!("connected");
        fake.build_id = None; // The pre-updater helper is migrated automatically.
    }
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "update_pending");
    assert!(b.active(&id));
    assert_eq!(f.lock().unwrap().replacements, 0);
    assert!(f.lock().unwrap().disconnected.is_empty());
    assert_eq!(
        b.connect(&id, None, false).unwrap_err().code,
        "helper_setup"
    );
    b.disconnect(&id).unwrap();
    assert_eq!(b.helper.status, "updating");
    assert_eq!(f.lock().unwrap().replacements, 1);
    assert_eq!(b.disconnect_all().unwrap_err().code, "helper_updating");
    {
        let mut fake = f.lock().unwrap();
        fake.build_id = Some("test-current".into());
        fake.service_status = "enabled".into();
        fake.sessions.clear();
    }
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "enabled");
    assert!(b
        .logs
        .iter()
        .any(|l| l.message == "VPN helper updated successfully."));
    assert_eq!(f.lock().unwrap().saved.get(&id).unwrap(), "saved-pin");
    b.connect(&id, None, false).unwrap();
    assert_eq!(f.lock().unwrap().connections.len(), 2);
}

#[test]
fn quit_cleanup_never_starts_async_helper_replacement() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("test-pin".into()), false).unwrap();
    f.lock().unwrap().build_id = None;
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "update_pending");
    b.disconnect_all().unwrap();
    assert!(!b.active(&id));
    assert_eq!(f.lock().unwrap().replacements, 0);
    b.refresh().unwrap(); // When staying in the app, normal polling completes it.
    assert_eq!(f.lock().unwrap().replacements, 1);
}

#[test]
fn missing_helper_registration_recovers_without_manual_enable() {
    let (_t, mut b, f, _id) = setup();
    f.lock().unwrap().service_status = "not_found".into();
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "updating");
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "enabled");
    assert_eq!(f.lock().unwrap().registrations, 1);
    assert_eq!(f.lock().unwrap().replacements, 0);
    assert!(f.lock().unwrap().connections.is_empty());
}

#[test]
fn retry_action_completes_registration_without_an_extra_enable_click() {
    let (_t, mut b, f, _id) = setup();
    f.lock().unwrap().build_id = None;
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "updating");
    f.lock().unwrap().service_status = "update_failed".into();
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "update_failed");
    f.lock().unwrap().service_status = "not_registered".into();
    assert_eq!(b.helper_action("retry_update").unwrap().status, "updating");
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "enabled");
    assert_eq!(f.lock().unwrap().registrations, 1);
    assert_eq!(f.lock().unwrap().replacements, 1);
}

#[test]
fn helper_interruption_does_not_save_password_or_report_stale_connection() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("ephemeral-pin".into()), true).unwrap();
    f.lock().unwrap().snapshot_error = true;
    b.refresh().unwrap();
    assert_eq!(b.helper.status, "recovering");
    assert_eq!(b.sessions[0].status, SessionStatus::Reconnecting);
    assert_eq!(f.lock().unwrap().save_count, 0);
    f.lock().unwrap().snapshot_error = false;
    f.lock().unwrap().sessions[0]["status"] = json!("connected");
    b.refresh().unwrap();
    assert_eq!(b.sessions[0].status, SessionStatus::Connected);
    assert_eq!(f.lock().unwrap().save_count, 1);
}

#[test]
fn ordinary_disconnect_returns_while_cleanup_is_pending() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("test".into()), false).unwrap();
    f.lock().unwrap().cleanup_polls = 10;
    b.disconnect(&id).unwrap();
    assert_eq!(b.sessions[0].status, SessionStatus::Disconnecting);
    assert!(f.lock().unwrap().disconnecting);
}

#[test]
fn quit_and_delete_wait_for_async_cleanup_and_surface_failure() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("test".into()), false).unwrap();
    f.lock().unwrap().cleanup_polls = 1;
    b.disconnect_all().unwrap();
    assert!(!f.lock().unwrap().disconnecting);
    assert!(!b.sessions[0].active());
    b.connect(&id, Some("test".into()), false).unwrap();
    f.lock().unwrap().cleanup_polls = 1;
    f.lock().unwrap().cleanup_error = true;
    assert_eq!(b.delete(&id).unwrap_err().code, "cleanup_failed");
    assert!(b.get(&id).is_ok());
}

#[test]
fn traffic_counters_survive_snapshots_without_creating_activity_events() {
    let (_t, mut b, f, id) = setup();
    b.connect(&id, Some("test".into()), false).unwrap();
    f.lock().unwrap().sessions[0]["status"] = json!("connected");
    b.refresh().unwrap();
    // Older helpers may omit the new fields until their automatic update.
    assert_eq!(b.sessions[0].bytes_in, 0);
    assert_eq!(b.sessions[0].bytes_out, 0);
    let log_count = b.logs.len();
    for (received, sent) in [(100_u64, 100_000_u64), (1_500_000, 5_000_000_000)] {
        {
            let mut fake = f.lock().unwrap();
            fake.sessions[0]["bytesIn"] = json!(received);
            fake.sessions[0]["bytesOut"] = json!(sent);
        }
        b.refresh().unwrap();
        let snapshot = serde_json::to_value(b.snapshot()).unwrap();
        assert_eq!(snapshot["sessions"][0]["bytesIn"], json!(received));
        assert_eq!(snapshot["sessions"][0]["bytesOut"], json!(sent));
        assert_eq!(b.logs.len(), log_count);
    }
}
