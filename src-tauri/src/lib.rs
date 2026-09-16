mod app;
#[cfg(test)]
mod app_tests;
mod helper_update;
mod models;
mod native;
mod policy;
mod profile;
mod storage;

use app::Backend;
use models::*;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Duration,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};

struct State {
    backend: Mutex<Backend>,
    quitting: AtomicBool,
    exit_ready: AtomicBool,
    tray_signature: Mutex<String>,
}
async fn task<T: Send + 'static>(
    app: tauri::AppHandle,
    f: impl FnOnce(&mut Backend) -> Result<T> + Send + 'static,
) -> Result<T> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<State>();
        let mut backend = state
            .backend
            .lock()
            .map_err(|_| AppError::new("state", "Application state is unavailable."))?;
        let result = f(&mut backend);
        publish(&app, &backend);
        result
    })
    .await
    .map_err(|e| AppError::new("task", e.to_string()))?
}
#[tauri::command]
async fn snapshot(app: tauri::AppHandle) -> Result<Snapshot> {
    task(app, |b| {
        b.refresh_credentials();
        b.refresh()?;
        Ok(b.snapshot())
    })
    .await
}
#[tauri::command]
async fn import_profile(app: tauri::AppHandle, path: String) -> Result<String> {
    task(app, move |b| b.import(PathBuf::from(path))).await
}
#[tauri::command]
async fn update_profile(app: tauri::AppHandle, id: String, update: ProfileUpdate) -> Result<()> {
    task(app, move |b| b.update(&id, update)).await
}
#[tauri::command]
async fn delete_profile(app: tauri::AppHandle, id: String) -> Result<()> {
    task(app, move |b| b.delete(&id)).await
}
#[tauri::command]
async fn connect_profile(
    app: tauri::AppHandle,
    id: String,
    password: Option<String>,
    remember: bool,
) -> Result<()> {
    task(app, move |b| b.connect(&id, password, remember)).await
}
#[tauri::command]
async fn disconnect_profile(app: tauri::AppHandle, id: String) -> Result<()> {
    task(app, move |b| b.disconnect(&id)).await
}
#[tauri::command]
async fn disconnect_all(app: tauri::AppHandle) -> Result<()> {
    task(app, |b| b.disconnect_all()).await
}
#[tauri::command]
async fn forget_password(app: tauri::AppHandle, id: String) -> Result<()> {
    task(app, move |b| b.forget(&id)).await
}
#[tauri::command]
async fn helper_action(app: tauri::AppHandle, operation: String) -> Result<HelperStatus> {
    task(app, move |b| b.helper_action(&operation)).await
}
fn show(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}
fn tray_image(connected: bool, connecting: bool) -> tauri::image::Image<'static> {
    // macOS scales tray images to 18 pt high. Fit the logo tightly inside a
    // 22 × 18 pt Retina canvas instead of retaining the app icon's large padding.
    let width = 44;
    let height = 36;
    let units_per_pixel = 28. / height as f32;
    let mut pixels = vec![0; width * height * 4];
    let color = if connected {
        [48, 143, 77]
    } else if connecting {
        [176, 140, 61]
    } else {
        [139, 145, 135]
    };
    // Match the two rounded V paths in IconSprite.vue's 40 × 40 i-brand symbol.
    let segments: [(f32, f32, f32, f32); 4] = [
        (6., 10., 20., 32.),
        (20., 32., 34., 10.),
        (14., 10., 20., 20.),
        (20., 20., 26., 10.),
    ];
    let samples = 4;
    for y in 0..height {
        for x in 0..width {
            let mut coverage = 0;
            for sy in 0..samples {
                for sx in 0..samples {
                    // The stroked logo spans x=4..36, y=8..34. Keep its aspect
                    // ratio and center it on (20, 21), with room for round caps.
                    let px = 20.
                        + (x as f32 + (sx as f32 + 0.5) / samples as f32 - width as f32 / 2.)
                            * units_per_pixel;
                    let py = 21.
                        + (y as f32 + (sy as f32 + 0.5) / samples as f32 - height as f32 / 2.)
                            * units_per_pixel;
                    let inside = segments.iter().any(|&(ax, ay, bx, by)| {
                        let dx = bx - ax;
                        let dy = by - ay;
                        let t =
                            (((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)).clamp(0., 1.);
                        // A radius of two matches stroke-width="4", including round caps/joins.
                        (px - ax - t * dx).powi(2) + (py - ay - t * dy).powi(2) <= 4.
                    });
                    coverage += usize::from(inside);
                }
            }
            if coverage > 0 {
                let i = (y * width + x) * 4;
                pixels[i..i + 3].copy_from_slice(&color);
                pixels[i + 3] =
                    ((coverage * 255 + samples * samples / 2) / (samples * samples)) as u8;
            }
        }
    }
    tauri::image::Image::new_owned(pixels, width as u32, height as u32)
}
fn publish(app: &tauri::AppHandle, b: &Backend) {
    let snapshot = b.snapshot();
    let _ = app.emit("vpn-snapshot", &snapshot);
    let signature = serde_json::to_string(&(
        &b.profiles,
        &b.sessions
            .iter()
            .map(|s| (&s.profile_id, &s.status))
            .collect::<Vec<_>>(),
    ))
    .unwrap_or_default();
    let state = app.state::<State>();
    let mut previous = state.tray_signature.lock().unwrap();
    if *previous == signature {
        return;
    }
    *previous = signature;
    let connected = b
        .sessions
        .iter()
        .any(|s| s.status == SessionStatus::Connected);
    let connecting = b.sessions.iter().any(Session::active);
    if let Some(tray) = app.tray_by_id("vuevpn") {
        let _ = tray.set_icon(Some(tray_image(connected, connecting)));
        let _ = tray.set_tooltip(Some(if connected {
            "VueVPN — Connected"
        } else if connecting {
            "VueVPN — Connecting"
        } else {
            "VueVPN — Disconnected"
        }));
        if let Ok(menu) = Menu::new(app) {
            if let Ok(item) = MenuItem::with_id(app, "open", "Open VueVPN", true, None::<&str>) {
                let _ = menu.append(&item);
            }
            for p in &b.profiles {
                let active = b.active(&p.id);
                let label = format!(
                    "{}  ·  {}",
                    p.name,
                    if active { "Disconnect" } else { "Connect" }
                );
                if let Ok(item) =
                    MenuItem::with_id(app, format!("profile:{}", p.id), label, true, None::<&str>)
                {
                    let _ = menu.append(&item);
                }
            }
            for (id, label, enabled) in [
                ("disconnect_all", "Disconnect All", connecting),
                ("quit", "Quit VueVPN", true),
            ] {
                if let Ok(item) = MenuItem::with_id(app, id, label, enabled, None::<&str>) {
                    let _ = menu.append(&item);
                }
            }
            let _ = tray.set_menu(Some(menu));
        }
    }
}
fn quit(app: tauri::AppHandle) {
    if app.state::<State>().quitting.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        match task(app.clone(), |b| b.disconnect_all()).await {
            Ok(()) => {
                app.state::<State>()
                    .exit_ready
                    .store(true, Ordering::SeqCst);
                app.exit(0);
            }
            Err(e) => {
                app.state::<State>().quitting.store(false, Ordering::SeqCst);
                show(&app);
                let _ = app.emit("vpn-error", e);
            }
        }
    });
}
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)))
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            snapshot,
            import_profile,
            update_profile,
            delete_profile,
            connect_profile,
            disconnect_profile,
            disconnect_all,
            forget_password,
            helper_action
        ])
        .setup(|app| {
            let backend = Backend::new(app.path().app_data_dir()?.join("profiles"))?;
            app.manage(State {
                backend: Mutex::new(backend),
                quitting: AtomicBool::new(false),
                exit_ready: AtomicBool::new(false),
                tray_signature: Mutex::new(String::new()),
            });
            TrayIconBuilder::with_id("vuevpn")
                .icon(tray_image(false, false))
                .icon_as_template(false)
                .tooltip("VueVPN — Disconnected")
                .on_menu_event(|app, event| {
                    let id = event.id.as_ref().to_string();
                    if id == "open" {
                        show(app);
                        return;
                    }
                    if id == "quit" {
                        quit(app.clone());
                        return;
                    }
                    let handle = app.clone();
                    tauri::async_runtime::spawn(async move {
                        let choice = id.clone();
                        let result = task(handle.clone(), move |b| {
                            if choice == "disconnect_all" {
                                return b.disconnect_all();
                            }
                            if let Some(profile_id) = choice.strip_prefix("profile:") {
                                if b.active(profile_id) {
                                    b.disconnect(profile_id)
                                } else {
                                    b.connect(profile_id, None, false)
                                }
                            } else {
                                Ok(())
                            }
                        })
                        .await;
                        if let Err(e) = result {
                            show(&handle);
                            if e.code == "credentials_required" || e.code == "keychain" {
                                let _ = handle
                                    .emit("vpn-credentials", id.trim_start_matches("profile:"));
                            } else {
                                let _ = handle.emit("vpn-error", e);
                            }
                        }
                    });
                })
                .build(app)?;
            let handle = app.handle().clone();
            std::thread::spawn(move || loop {
                if handle.state::<State>().quitting.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_secs(1));
                    continue;
                }
                {
                    let state = handle.state::<State>();
                    if let Ok(mut b) = state.backend.lock() {
                        if let Err(e) = b.refresh() {
                            b.log(None, e.message);
                        }
                        publish(&handle, &b);
                    };
                }
                // Publish per-profile traffic counters without polling from the webview.
                std::thread::sleep(Duration::from_secs(1));
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .build(tauri::generate_context!())
        .expect("Cannot initialize VueVPN");
    app.run(|handle, event| {
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Reopen { .. } = &event {
            show(handle);
        }
        if let tauri::RunEvent::ExitRequested { api, .. } = event {
            if !handle.state::<State>().exit_ready.load(Ordering::SeqCst) {
                api.prevent_exit();
                quit(handle.clone());
            }
        }
    });
}
