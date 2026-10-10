use crate::server::{check_zombie, new as new_server, ConnectionMeta, ServerPtr};
use hbb_common::{
    allow_err,
    config::{self, option2bool, Config, RENDEZVOUS_PORT},
    log, sleep, tokio,
};

// Kept for the existing IPC and UI bindings; this host only listens on the LAN.
pub struct RendezvousMediator;

static LISTENING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn lan_listening() -> bool {
    LISTENING.load(std::sync::atomic::Ordering::Relaxed)
}

impl RendezvousMediator {
    pub fn restart() {}

    pub async fn start_all() {
        if config::is_outgoing_only() {
            std::future::pending::<()>().await;
            return;
        }
        check_zombie();
        let server = new_server();
        std::thread::spawn(|| {
            allow_err!(crate::lan::start_listening());
        });
        scrap::codec::test_av1();
        direct_server(server).await;
    }
}

pub(crate) static NEEDS_DEPLOY: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(target_os = "android")]
pub(crate) fn reset_needs_deploy_notification() {}

pub struct CheckIfResendPk;
impl CheckIfResendPk {
    pub fn new() -> Self {
        Self
    }
}

fn get_direct_port() -> i32 {
    let mut port = Config::get_option("direct-access-port")
        .parse::<i32>()
        .unwrap_or(0);
    if port <= 0 {
        port = RENDEZVOUS_PORT + 2;
    }
    port
}

async fn direct_server(server: ServerPtr) {
    let mut listener = None;
    let mut port = 0;
    loop {
        let disabled = option2bool("stop-service", &Config::get_option("stop-service"));
        if disabled {
            server.write().unwrap().close_connections();
        }
        if !disabled && listener.is_none() {
            port = get_direct_port();
            match hbb_common::tcp::listen_any(port as _).await {
                Ok(l) => {
                    listener = Some(l);
                    LISTENING.store(true, std::sync::atomic::Ordering::Relaxed);
                    log::info!(
                        "Direct server listening on: {:?}",
                        listener.as_ref().map(|l| l.local_addr())
                    );
                }
                Err(err) => {
                    // to-do: pass to ui
                    log::error!(
                        "Failed to start direct server on port: {}, error: {}",
                        port,
                        err
                    );
                    loop {
                        if port != get_direct_port() {
                            break;
                        }
                        sleep(1.).await;
                    }
                }
            }
        }
        if let Some(l) = listener.as_mut() {
            if disabled || port != get_direct_port() {
                log::info!("Exit direct access listen");
                listener = None;
                LISTENING.store(false, std::sync::atomic::Ordering::Relaxed);
                continue;
            }
            if let Ok(Ok((stream, addr))) = hbb_common::timeout(1000, l.accept()).await {
                if !crate::lan_only::is_lan_ip(addr.ip()) {
                    continue;
                }
                stream.set_nodelay(true).ok();
                log::info!("direct access from {}", addr);
                let local_addr = stream
                    .local_addr()
                    .unwrap_or(Config::get_any_listen_addr(true));
                let server = server.clone();
                tokio::spawn(async move {
                    allow_err!(
                        crate::server::create_tcp_connection(
                            server,
                            hbb_common::Stream::from(stream, local_addr),
                            addr,
                            false,
                            ConnectionMeta::default(), // Direct connections don't have server-side user context.
                        )
                        .await
                    );
                });
            } else {
                sleep(0.1).await;
            }
        } else {
            sleep(1.).await;
        }
    }
}
