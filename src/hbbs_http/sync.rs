#[cfg(not(target_os = "ios"))]
use hbb_common::tokio::sync::broadcast;

#[cfg(not(target_os = "ios"))]
lazy_static::lazy_static! {
    static ref SENDER: broadcast::Sender<Vec<i32>> = broadcast::channel(16).0;
}

#[cfg(not(target_os = "ios"))]
pub fn signal_receiver() -> broadcast::Receiver<Vec<i32>> {
    SENDER.subscribe()
}

#[cfg(not(target_os = "ios"))]
pub fn is_pro() -> bool {
    false
}

#[cfg(all(
    feature = "flutter",
    not(any(target_os = "android", target_os = "ios"))
))]
pub fn register_switch_grant(_switch_uuid: String) {}
