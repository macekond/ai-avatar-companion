//! Nova shell: spawns the Python sidecar (WebSocket pipeline server),
//! forwards its output to the log, and kills it when the app exits.
//!
//! The sidecar is also started with `--managed`, so it watches its stdin
//! pipe and exits on EOF — covering the case where this process dies
//! without running its exit handler (SIGKILL, crash).

use std::sync::Mutex;

use tauri::{Emitter, Manager, RunEvent};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

struct SidecarChild(Mutex<Option<CommandChild>>);

pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            let (mut rx, child) = app
                .shell()
                .sidecar("nova-server")
                .expect("nova-server sidecar binary missing from bundle")
                .args(["--managed"])
                .spawn()
                .expect("failed to spawn nova-server sidecar");

            app.manage(SidecarChild(Mutex::new(Some(child))));

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                while let Some(event) = rx.recv().await {
                    match event {
                        CommandEvent::Stdout(line) => {
                            let s = String::from_utf8_lossy(&line);
                            log::info!("[sidecar] {}", s.trim_end());
                            if s.starts_with("NOVA_READY") {
                                let _ = handle.emit("sidecar-ready", ());
                            }
                        }
                        CommandEvent::Stderr(line) => {
                            log::warn!("[sidecar] {}", String::from_utf8_lossy(&line).trim_end());
                        }
                        CommandEvent::Terminated(payload) => {
                            log::error!("[sidecar] exited with {:?}", payload.code);
                        }
                        _ => {}
                    }
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Nova")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                if let Some(state) = app.try_state::<SidecarChild>() {
                    if let Some(child) = state.0.lock().unwrap().take() {
                        log::info!("killing sidecar on exit");
                        let _ = child.kill();
                    }
                }
            }
        });
}
