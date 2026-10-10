use hbb_common::{bail, ResultType};
use std::{
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};

static CONTROLLING_SESSION_COUNT: AtomicUsize = AtomicUsize::new(0);

pub fn start_auto_update() {}
pub fn stop_auto_update() {}
pub fn manually_check_update() -> ResultType<()> {
    bail!("Updates are unavailable in the LAN-only build")
}

pub fn get_download_file_from_url(_url: &str) -> Option<PathBuf> {
    None
}

#[cfg(target_os = "macos")]
pub fn start_auto_update_macos() {}

#[cfg(target_os = "macos")]
pub fn check_update_as_root() -> ResultType<bool> {
    bail!("Updates are unavailable in the LAN-only build")
}

pub fn update_controlling_session_count(count: usize) {
    CONTROLLING_SESSION_COUNT.store(count, Ordering::SeqCst);
}

#[inline]
/// Returns true when there are no active incoming or outgoing connections.
/// Used to avoid updating while a remote session is in progress.
pub fn has_no_active_conns() -> bool {
    let conns = crate::Connection::alive_conns();
    conns.is_empty() && has_no_controlling_conns()
}

#[cfg(any(not(target_os = "windows"), feature = "flutter"))]
fn has_no_controlling_conns() -> bool {
    CONTROLLING_SESSION_COUNT.load(Ordering::SeqCst) == 0
}

#[cfg(not(any(not(target_os = "windows"), feature = "flutter")))]
fn has_no_controlling_conns() -> bool {
    let app_exe = format!("{}.exe", crate::get_app_name().to_lowercase());
    for arg in [
        "--connect",
        "--play",
        "--file-transfer",
        "--view-camera",
        "--port-forward",
        "--rdp",
    ] {
        if !crate::platform::get_pids_of_process_with_first_arg(&app_exe, arg).is_empty() {
            return false;
        }
    }
    true
}

#[cfg(target_os = "macos")]
pub fn has_no_active_conns_ipc() -> bool {
    let rt = match hbb_common::tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return false,
    };
    rt.block_on(async {
        // Use the same GUI-domain-filtered UID set as the update script.
        // Shell-only SSH/TTY users are excluded, while an empty GUI set maps
        // to UID 0 so the LoginWindow server is queried rather than assumed idle.
        let uids = crate::platform::get_logged_in_uids();
        // Check each user's server — fail closed if any has active connections
        for uid in uids {
            if let Ok(mut conn) = crate::ipc::connect_for_uid(1000, uid, "").await {
                if conn.send(&crate::ipc::Data::HasNoActiveConns(None)).await.is_ok() {
                    match conn.next_timeout(1000).await {
                        Ok(Some(crate::ipc::Data::HasNoActiveConns(Some(true)))) => {
                            // Explicit no active connections — safe to continue
                        }
                        Ok(Some(crate::ipc::Data::HasNoActiveConns(Some(false)))) => {
                            return false; // Explicit active connections
                        }
                        _ => {
                            return false; // Timeout/error/unexpected — fail closed
                        }
                    }
                } else {
                    return false; // Send failed — fail closed
                }
            } else {
                return false; // Connection failed — fail closed
            }
        }
        true // All users explicitly confirmed no active connections
    })
}
