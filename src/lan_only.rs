use std::{
    io::{Error, ErrorKind, Result},
    net::{IpAddr, SocketAddr},
};

pub fn is_lan_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() || ip.is_link_local() || ip.is_loopback(),
        IpAddr::V6(ip) => {
            if let Some(ip) = ip.to_ipv4_mapped() {
                return is_lan_ip(IpAddr::V4(ip));
            }
            ip.is_loopback()
                || (ip.segments()[0] & 0xfe00) == 0xfc00
                || (ip.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

pub fn peer_addr(peer: &str, default_port: u16) -> Result<SocketAddr> {
    // Parse literals before opening a socket: DNS and proxies can leave the LAN.
    let addr = peer.parse::<SocketAddr>().ok().or_else(|| {
        peer.parse::<IpAddr>()
            .ok()
            .map(|ip| SocketAddr::new(ip, default_port))
    });
    match addr {
        Some(addr) if addr.port() != 0 && is_lan_ip(addr.ip()) => Ok(addr),
        _ => Err(Error::new(
            ErrorKind::PermissionDenied,
            "LAN-only: enter a private or link-local IP address, optionally with a port",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_lan_literals_and_ports() {
        for peer in [
            "10.0.0.1",
            "172.16.0.1",
            "192.168.1.20",
            "169.254.1.2",
            "127.0.0.1",
            "::1",
            "fd00::1",
            "fe80::1",
            "[fe80::1%3]:21118",
            "[::ffff:192.168.1.2]:21118",
        ] {
            assert!(peer_addr(peer, 21118).is_ok(), "{peer}");
        }
        assert_eq!(peer_addr("192.168.1.20", 21118).unwrap().port(), 21118);
        assert_eq!(
            peer_addr("192.168.1.20:12345", 21118).unwrap().port(),
            12345
        );
    }

    #[test]
    fn rejects_public_addresses_names_and_server_ids() {
        for peer in [
            "8.8.8.8",
            "1.1.1.1:21118",
            "172.32.0.1",
            "2001:4860:4860::8888",
            "[::ffff:8.8.8.8]:21118",
            "0.0.0.0",
            "::",
            "255.255.255.255",
            "224.0.0.1",
            "ff02::1",
            "localhost",
            "pc.local:21118",
            "123456789",
            "rustdesk.com:21118",
            "192.168.1.1:0",
            "192.168.1.1/r",
            "192.168.1.1@rustdesk.com",
            "https://192.168.1.1",
        ] {
            assert!(peer_addr(peer, 21118).is_err(), "{peer}");
        }
    }
}
