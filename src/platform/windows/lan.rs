use std::{
    ffi::CStr,
    mem::{size_of, zeroed},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    ptr::null_mut,
    time::Duration,
};
use winapi::{
    shared::{
        winerror::{ERROR_BUFFER_OVERFLOW, ERROR_NO_DATA, ERROR_SUCCESS},
        ws2def::{AF_INET, AF_INET6, AF_UNSPEC, SOCKADDR_IN},
        ws2ipdef::SOCKADDR_IN6,
    },
    um::{
        iphlpapi::GetAdaptersAddresses,
        iptypes::{
            GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST,
            IP_ADAPTER_ADDRESSES_LH,
        },
    },
};

pub(crate) fn local_interfaces() -> Vec<(IpAddr, String)> {
    let mut size = 15_000;
    let mut interfaces = Vec::new();
    for _ in 0..2 {
        // Typed storage supplies the alignment required by Windows' linked structures.
        let mut buffer = vec![
            unsafe { zeroed::<IP_ADAPTER_ADDRESSES_LH>() };
            size as usize / size_of::<IP_ADAPTER_ADDRESSES_LH>() + 1
        ];
        let status = unsafe {
            GetAdaptersAddresses(
                AF_UNSPEC as _,
                GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_MULTICAST,
                null_mut(),
                buffer.as_mut_ptr(),
                &mut size,
            )
        };
        if status == ERROR_BUFFER_OVERFLOW {
            continue;
        }
        if status == ERROR_NO_DATA {
            return interfaces;
        }
        if status != ERROR_SUCCESS {
            hbb_common::throttled_log!(
                Duration::from_secs(30),
                warn,
                "Cannot enumerate LAN interfaces: {}",
                std::io::Error::from_raw_os_error(status as _)
            );
            return interfaces;
        }
        // All returned pointers belong to buffer, which remains alive during traversal.
        unsafe {
            let mut adapter = buffer.as_ptr();
            while !adapter.is_null() {
                let name = if (*adapter).AdapterName.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr((*adapter).AdapterName)
                        .to_string_lossy()
                        .into_owned()
                };
                let mut address = (*adapter).FirstUnicastAddress;
                while !address.is_null() {
                    let socket = (*address).Address.lpSockaddr;
                    let length = (*address).Address.iSockaddrLength;
                    if !socket.is_null() {
                        let ip = match (*socket).sa_family as i32 {
                            AF_INET if length >= size_of::<SOCKADDR_IN>() as i32 => {
                                let addr = &*(socket as *const SOCKADDR_IN);
                                Some(IpAddr::V4(Ipv4Addr::from(
                                    addr.sin_addr.S_un.S_addr().to_ne_bytes(),
                                )))
                            }
                            AF_INET6 if length >= size_of::<SOCKADDR_IN6>() as i32 => {
                                let addr = &*(socket as *const SOCKADDR_IN6);
                                Some(IpAddr::V6(Ipv6Addr::from(*addr.sin6_addr.u.Byte())))
                            }
                            _ => None,
                        };
                        if let Some(ip) = ip {
                            interfaces.push((ip, name.clone()));
                        }
                    }
                    address = (*address).Next;
                }
                adapter = (*adapter).Next;
            }
        }
        return interfaces;
    }
    hbb_common::throttled_log!(
        Duration::from_secs(30),
        warn,
        "LAN interface list changed during enumeration"
    );
    interfaces
}

#[cfg(test)]
#[test]
fn lan_interface_enumeration_includes_loopback() {
    assert!(local_interfaces()
        .iter()
        .any(|(ip, name)| ip.is_loopback() && !name.is_empty()));
}
