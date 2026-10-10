#[cfg(not(target_os = "ios"))]
use hbb_common::whoami;
use hbb_common::{
    allow_err,
    anyhow::bail,
    config::Config,
    config::{self, RENDEZVOUS_PORT},
    log,
    protobuf::Message as _,
    rendezvous_proto::*,
    tokio::{
        self,
        sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender},
    },
    ResultType,
};

use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs, UdpSocket},
    time::Instant,
};

type Message = RendezvousMessage;

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
#[test]
fn lan_interface_enumeration_includes_loopback() {
    assert!(local_interfaces()
        .iter()
        .any(|(ip, name)| ip.is_loopback() && !name.is_empty()));
}

pub(crate) fn local_interfaces() -> Vec<(IpAddr, String)> {
    // default-net's enumeration sends gateway probes to a public IP.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    match nix::ifaddrs::getifaddrs() {
        Ok(interfaces) => {
            return interfaces
                .filter_map(|interface| {
                    let addr = interface.address?;
                    let ip = addr
                        .as_sockaddr_in()
                        .map(|addr| IpAddr::V4(addr.ip()))
                        .or_else(|| addr.as_sockaddr_in6().map(|addr| IpAddr::V6(addr.ip())))?;
                    Some((ip, interface.interface_name))
                })
                .collect();
        }
        Err(err) => hbb_common::throttled_log!(
            std::time::Duration::from_secs(30),
            warn,
            "Cannot enumerate LAN interfaces: {err}"
        ),
    }
    Vec::new()
}

#[cfg(not(target_os = "ios"))]
pub(super) fn start_listening() -> ResultType<()> {
    let addr = SocketAddr::from(([0, 0, 0, 0], get_broadcast_port()));
    let socket = std::net::UdpSocket::bind(addr)?;
    socket.set_read_timeout(Some(std::time::Duration::from_millis(1000)))?;
    log::info!("lan discovery listener started");
    loop {
        let mut buf = [0; 2048];
        if let Ok((len, addr)) = socket.recv_from(&mut buf) {
            if !crate::lan_only::is_lan_ip(addr.ip()) {
                continue;
            }
            if let Ok(msg_in) = Message::parse_from_bytes(&buf[0..len]) {
                match msg_in.union {
                    Some(rendezvous_message::Union::PeerDiscovery(p)) => {
                        if p.cmd == "ping"
                            && config::option2bool(
                                "enable-lan-discovery",
                                &Config::get_option("enable-lan-discovery"),
                            )
                        {
                            let id = Config::get_id();
                            if p.id == id {
                                continue;
                            }
                            if let Some(self_addr) = get_ipaddr_by_peer(&addr) {
                                let mut msg_out = Message::new();
                                let mut hostname = crate::whoami_hostname();
                                // The default hostname is "localhost" which is a bit confusing
                                if hostname == "localhost" {
                                    hostname = "unknown".to_owned();
                                }
                                let peer = PeerDiscovery {
                                    cmd: "pong".to_owned(),
                                    mac: get_mac(&self_addr),
                                    id,
                                    hostname,
                                    username: crate::platform::get_active_username(),
                                    platform: whoami::platform().to_string(),
                                    ..Default::default()
                                };
                                msg_out.set_peer_discovery(peer);
                                socket.send_to(&msg_out.write_to_bytes()?, addr).ok();
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

#[tokio::main(flavor = "current_thread")]
pub async fn discover() -> ResultType<()> {
    let sockets = send_query()?;
    let rx = spawn_wait_responses(sockets);
    handle_received_peers(rx).await?;

    log::info!("discover ping done");
    Ok(())
}

pub fn send_wol(id: String) {
    let interfaces = local_interfaces();
    for peer in &config::LanPeers::load().peers {
        if peer.id == id {
            for (_, mac) in peer.ip_mac.iter() {
                if let Ok(mac_addr) = mac.parse() {
                    for (ip, _) in &interfaces {
                        if ip.is_ipv4() && crate::lan_only::is_lan_ip(*ip) {
                            log::info!("Send wol to {mac_addr} of {ip}");
                            allow_err!(wol::send_wol(mac_addr, None, Some(*ip)));
                        }
                    }
                }
            }
            break;
        }
    }
}

#[inline]
fn get_broadcast_port() -> u16 {
    (RENDEZVOUS_PORT + 3) as _
}

fn get_mac(_ip: &IpAddr) -> String {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    if let Ok(mac) = get_mac_by_ip(_ip) {
        mac.to_string()
    } else {
        "".to_owned()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    "".to_owned()
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn get_mac_by_ip(ip: &IpAddr) -> ResultType<String> {
    for (addr, name) in local_interfaces() {
        if addr == *ip {
            if let Some(mac) = mac_address::mac_address_by_name(&name)? {
                return Ok(mac.to_string());
            }
        }
    }
    bail!("No interface found for ip: {:?}", ip);
}

// Mainly from https://github.com/shellrow/default-net/blob/cf7ca24e7e6e8e566ed32346c9cfddab3f47e2d6/src/interface/shared.rs#L4
fn get_ipaddr_by_peer<A: ToSocketAddrs>(peer: A) -> Option<IpAddr> {
    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return None,
    };

    match socket.connect(peer) {
        Ok(()) => (),
        Err(_) => return None,
    };

    match socket.local_addr() {
        Ok(addr) => return Some(addr.ip()),
        Err(_) => return None,
    };
}

fn create_broadcast_sockets() -> Vec<UdpSocket> {
    let mut ipv4s = Vec::new();
    for (ip, _) in local_interfaces() {
        if let IpAddr::V4(ip) = ip {
            if crate::lan_only::is_lan_ip(ip.into()) {
                ipv4s.push(ip);
            }
        }
    }
    ipv4s.push(Ipv4Addr::UNSPECIFIED); // for robustness
    let mut sockets = Vec::new();
    for v4_addr in ipv4s {
        if let Ok(s) = UdpSocket::bind(SocketAddr::from((v4_addr, 0))) {
            if s.set_broadcast(true).is_ok() {
                sockets.push(s);
            }
        }
    }
    sockets
}

fn send_query() -> ResultType<Vec<UdpSocket>> {
    let sockets = create_broadcast_sockets();
    if sockets.is_empty() {
        bail!("Found no bindable ipv4 addresses");
    }

    let mut msg_out = Message::new();
    // We may not be able to get the mac address on mobile platforms.
    // So we need to use the id to avoid discovering ourselves.
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let id = crate::ui_interface::get_id();
    // `crate::ui_interface::get_id()` will cause error:
    // `get_id()` uses async code with `current_thread`, which is not allowed in this context.
    //
    // No need to get id for desktop platforms.
    // We can use the mac address to identify the device.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let id = "".to_owned();
    let peer = PeerDiscovery {
        cmd: "ping".to_owned(),
        id,
        ..Default::default()
    };
    msg_out.set_peer_discovery(peer);
    let out = msg_out.write_to_bytes()?;
    let maddr = SocketAddr::from(([255, 255, 255, 255], get_broadcast_port()));
    for socket in &sockets {
        allow_err!(socket.send_to(&out, maddr));
    }
    log::info!("discover ping sent");
    Ok(sockets)
}

fn wait_response(
    socket: UdpSocket,
    timeout: Option<std::time::Duration>,
    tx: UnboundedSender<config::DiscoveryPeer>,
) -> ResultType<()> {
    let mut last_recv_time = Instant::now();

    let local_addr = socket.local_addr();
    let try_get_ip_by_peer = match local_addr.as_ref() {
        Err(..) => true,
        Ok(addr) => addr.ip().is_unspecified(),
    };
    let mut mac: Option<String> = None;

    socket.set_read_timeout(timeout)?;
    loop {
        let mut buf = [0; 2048];
        if let Ok((len, addr)) = socket.recv_from(&mut buf) {
            if !crate::lan_only::is_lan_ip(addr.ip()) {
                continue;
            }
            if let Ok(msg_in) = Message::parse_from_bytes(&buf[0..len]) {
                match msg_in.union {
                    Some(rendezvous_message::Union::PeerDiscovery(p)) => {
                        last_recv_time = Instant::now();
                        if p.cmd == "pong" {
                            if !crate::common::is_valid_untrusted_peer_id(&p.id) {
                                log::warn!(
                                    "Ignoring LAN discovery response from {} with invalid peer id",
                                    addr
                                );
                                continue;
                            }

                            let local_mac = if try_get_ip_by_peer {
                                if let Some(self_addr) = get_ipaddr_by_peer(&addr) {
                                    get_mac(&self_addr)
                                } else {
                                    "".to_owned()
                                }
                            } else {
                                match mac.as_ref() {
                                    Some(m) => m.clone(),
                                    None => {
                                        let m = if let Ok(local_addr) = local_addr {
                                            get_mac(&local_addr.ip())
                                        } else {
                                            "".to_owned()
                                        };
                                        mac = Some(m.clone());
                                        m
                                    }
                                }
                            };

                            if local_mac.is_empty() && p.mac.is_empty() || local_mac != p.mac {
                                allow_err!(tx.send(config::DiscoveryPeer {
                                    id: addr.ip().to_string(),
                                    ip_mac: HashMap::from([
                                        (addr.ip().to_string(), p.mac.clone(),)
                                    ]),
                                    username: p.username.clone(),
                                    hostname: p.hostname.clone(),
                                    platform: p.platform.clone(),
                                    online: true,
                                }));
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        if last_recv_time.elapsed().as_millis() > 3_000 {
            break;
        }
    }
    Ok(())
}

fn spawn_wait_responses(sockets: Vec<UdpSocket>) -> UnboundedReceiver<config::DiscoveryPeer> {
    let (tx, rx) = unbounded_channel::<_>();
    for socket in sockets {
        let tx_clone = tx.clone();
        std::thread::spawn(move || {
            allow_err!(wait_response(
                socket,
                Some(std::time::Duration::from_millis(10)),
                tx_clone
            ));
        });
    }
    rx
}

async fn handle_received_peers(mut rx: UnboundedReceiver<config::DiscoveryPeer>) -> ResultType<()> {
    let mut peers = config::LanPeers::load().peers;
    peers.iter_mut().for_each(|peer| {
        peer.online = false;
    });

    let mut response_set = HashSet::new();
    let mut last_write_time: Option<Instant> = None;
    loop {
        tokio::select! {
            data = rx.recv() => match data {
                Some(mut peer) => {
                    let in_response_set = !response_set.insert(peer.id.clone());
                    if let Some(pos) = peers.iter().position(|x| x.is_same_peer(&peer) ) {
                        let peer1 = peers.remove(pos);
                        if in_response_set {
                            peer.ip_mac.extend(peer1.ip_mac);
                            peer.online = true;
                        }
                    }
                    peers.insert(0, peer);
                    if last_write_time.map(|t| t.elapsed().as_millis() > 300).unwrap_or(true)  {
                        config::LanPeers::store(&peers);
                        #[cfg(feature = "flutter")]
                        crate::flutter_ffi::main_load_lan_peers();
                        last_write_time = Some(Instant::now());
                    }
                }
                None => {
                    break
                }
            }
        }
    }

    config::LanPeers::store(&peers);
    #[cfg(feature = "flutter")]
    crate::flutter_ffi::main_load_lan_peers();
    Ok(())
}
