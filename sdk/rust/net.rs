use std::collections::HashMap;
use std::ffi::{c_char, c_void};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

use crate::ffi::ubit_net_vtable;

const MAX_CONNECTIONS: usize = 64;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(25);
const IO_TIMEOUT: Duration = Duration::from_secs(30);

const BLOCKED_V4: &[(u32, u32)] = &[
    (u32::from_be_bytes([0, 0, 0, 0]), 8),
    (u32::from_be_bytes([10, 0, 0, 0]), 8),
    (u32::from_be_bytes([100, 64, 0, 0]), 10),
    (u32::from_be_bytes([127, 0, 0, 0]), 8),
    (u32::from_be_bytes([169, 254, 0, 0]), 16),
    (u32::from_be_bytes([172, 16, 0, 0]), 12),
    (u32::from_be_bytes([192, 0, 0, 0]), 24),
    (u32::from_be_bytes([192, 0, 2, 0]), 24),
    (u32::from_be_bytes([192, 88, 99, 0]), 24),
    (u32::from_be_bytes([192, 168, 0, 0]), 16),
    (u32::from_be_bytes([198, 18, 0, 0]), 15),
    (u32::from_be_bytes([198, 51, 100, 0]), 24),
    (u32::from_be_bytes([203, 0, 113, 0]), 24),
    (u32::from_be_bytes([224, 0, 0, 0]), 4),
    (u32::from_be_bytes([240, 0, 0, 0]), 4),
];

fn public4(ip: Ipv4Addr) -> bool {
    let n = u32::from(ip);
    !BLOCKED_V4.iter().any(|&(base, bits)| {
        let mask = if bits == 0 { 0 } else { !0u32 << (32 - bits) };
        (n & mask) == (base & mask)
    })
}

/// True only for globally routable unicast addresses (checked against IANA's IPv4 and IPv6
/// special-purpose registries, matching `bare-ubit`'s `isPublicAddress`).
pub fn is_public_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => public4(v4),
        IpAddr::V6(v6) => {
            let g = v6.segments();
            let v4_in = |hi: u16, lo: u16| Ipv4Addr::from(((hi as u32) << 16) | (lo as u32));
            if g[..5] == [0; 5] && g[5] == 0xffff {
                return public4(v4_in(g[6], g[7])); // ::ffff:a.b.c.d
            }
            if g[0] == 0x0064 && g[1] == 0xff9b && g[2..6] == [0; 4] {
                return public4(v4_in(g[6], g[7])); // well-known NAT64 64:ff9b::/96
            }
            if g[0] == 0x0064 && g[1] == 0xff9b && g[2] == 1 {
                return false; // local-use NAT64 64:ff9b:1::/48 (RFC 8215)
            }
            if g[0] == 0x2002 {
                return public4(v4_in(g[1], g[2])); // 6to4 2002::/16
            }
            if g[..6] == [0; 6] {
                return false; // ::, ::1 and IPv4-compatible
            }
            if (g[0] & 0xfe00) == 0xfc00 {
                return false; // unique local fc00::/7
            }
            if (g[0] & 0xffc0) == 0xfe80 || (g[0] & 0xffc0) == 0xfec0 {
                return false; // link-local and site-local
            }
            if (g[0] & 0xff00) == 0xff00 {
                return false; // multicast
            }
            if g[0] == 0x2001 && (g[1] == 0x0db8 || g[1] < 0x0200) {
                return false; // documentation, Teredo and IETF 2001::/23 blocks
            }
            if g[0] == 0x3fff && (g[1] & 0xf000) == 0 {
                return false; // 3fff::/20 documentation (RFC 9637)
            }
            if g[0] == 0x5f00 {
                return false; // SRv6 SIDs (RFC 9602)
            }
            if g[0] == 0x0100 && g[1] == 0 && g[2] == 0 && (g[3] & 0xfffe) == 0 {
                return false; // discard 100::/64 and dummy 100:0:0:1::/64 (RFC 9780)
            }
            true
        }
    }
}

static TLS_CONFIG: LazyLock<Arc<ClientConfig>> = LazyLock::new(|| {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let cfg =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("rustls protocol versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
    Arc::new(cfg)
});

enum Transport {
    Plain(TcpStream),
    Tls(Box<StreamOwned<ClientConnection, TcpStream>>),
}

impl Transport {
    fn read_some(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Self::Plain(s) => s.read(buf),
            Self::Tls(s) => s.read(buf),
        }
    }

    fn write_some(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Plain(s) => s.write(buf),
            Self::Tls(s) => s.write(buf),
        }
    }
}

struct ConnEntry {
    io: Arc<Mutex<Transport>>,
    raw: TcpStream,
}

pub type AddressFilter = Arc<dyn Fn(IpAddr) -> bool + Send + Sync>;

pub(crate) struct NetSession {
    allow: AddressFilter,
    aborted: AtomicBool,
    next_id: AtomicI32,
    conns: Mutex<HashMap<i32, ConnEntry>>,
}

impl NetSession {
    pub(crate) fn new(allow: AddressFilter) -> Arc<Self> {
        Arc::new(Self {
            allow,
            aborted: AtomicBool::new(false),
            next_id: AtomicI32::new(1),
            conns: Mutex::new(HashMap::new()),
        })
    }

    pub(crate) fn abort(&self) {
        self.aborted.store(true, Ordering::SeqCst);
        let mut conns = self.conns.lock().unwrap();
        for (_, entry) in conns.drain() {
            let _ = entry.raw.shutdown(Shutdown::Both);
        }
    }

    fn open(&self, host_bytes: &[u8], port: i32, use_tls: bool) -> i32 {
        if self.aborted.load(Ordering::SeqCst) || !(1..=65535).contains(&port) {
            return -1;
        }
        if host_bytes.is_empty()
            || host_bytes.len() > 255
            || host_bytes.iter().any(|&c| !(0x21..=0x7e).contains(&c))
        {
            return -1;
        }
        let Ok(raw_host) = std::str::from_utf8(host_bytes) else {
            return -1;
        };
        if raw_host.contains(['/', '\\', '@']) {
            return -1;
        }
        if self.conns.lock().unwrap().len() >= MAX_CONNECTIONS {
            return -1;
        }

        let clean_host = raw_host
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .unwrap_or(raw_host);
        let port_u16 = port as u16;
        let addrs: Vec<SocketAddr> = if let Ok(ip) = clean_host.parse::<IpAddr>() {
            vec![SocketAddr::new(ip, port_u16)]
        } else {
            match (clean_host, port_u16).to_socket_addrs() {
                Ok(iter) => iter.collect(),
                Err(_) => return -1,
            }
        };

        // Every resolved record must pass the address policy so DNS with one private A/AAAA cannot steer there.
        if addrs.is_empty() || !addrs.iter().all(|a| (self.allow)(a.ip())) {
            return -1;
        }

        let mut connected = None;
        for addr in &addrs {
            if self.aborted.load(Ordering::SeqCst) {
                return -1;
            }
            if let Ok(tcp) = TcpStream::connect_timeout(addr, CONNECT_TIMEOUT) {
                let _ = tcp.set_nodelay(true);
                let _ = tcp.set_read_timeout(Some(IO_TIMEOUT));
                let _ = tcp.set_write_timeout(Some(IO_TIMEOUT));
                connected = Some(tcp);
                break;
            }
        }
        let Some(tcp) = connected else {
            return -1;
        };
        let Ok(raw) = tcp.try_clone() else {
            return -1;
        };

        let transport = if use_tls {
            let Ok(server_name) = ServerName::try_from(clean_host.to_owned()) else {
                return -1;
            };
            let Ok(mut tls_conn) = ClientConnection::new(TLS_CONFIG.clone(), server_name) else {
                return -1;
            };
            let mut tcp_stream = tcp;
            if tls_conn.complete_io(&mut tcp_stream).is_err() {
                return -1;
            }
            Transport::Tls(Box::new(StreamOwned::new(tls_conn, tcp_stream)))
        } else {
            Transport::Plain(tcp)
        };

        let handle = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut conns = self.conns.lock().unwrap();
        if self.aborted.load(Ordering::SeqCst) || conns.len() >= MAX_CONNECTIONS {
            let _ = raw.shutdown(Shutdown::Both);
            return -1;
        }
        conns.insert(
            handle,
            ConnEntry {
                io: Arc::new(Mutex::new(transport)),
                raw,
            },
        );
        handle
    }

    fn read(&self, handle: i32, out: &mut [u8]) -> i32 {
        if self.aborted.load(Ordering::SeqCst) || out.is_empty() {
            return -1;
        }
        let io = {
            let conns = self.conns.lock().unwrap();
            let Some(entry) = conns.get(&handle) else {
                return -1;
            };
            entry.io.clone()
        };
        let Ok(mut guard) = io.lock() else {
            return -1;
        };
        match guard.read_some(out) {
            Ok(n) => n as i32,
            Err(_) => -1,
        }
    }

    fn write(&self, handle: i32, data: &[u8]) -> i32 {
        if self.aborted.load(Ordering::SeqCst) {
            return -1;
        }
        if data.is_empty() {
            return 0;
        }
        let io = {
            let conns = self.conns.lock().unwrap();
            let Some(entry) = conns.get(&handle) else {
                return -1;
            };
            entry.io.clone()
        };
        let Ok(mut guard) = io.lock() else {
            return -1;
        };
        match guard.write_some(data) {
            Ok(n) => n as i32,
            Err(_) => -1,
        }
    }

    fn close(&self, handle: i32) {
        if let Some(entry) = self.conns.lock().unwrap().remove(&handle) {
            let _ = entry.raw.shutdown(Shutdown::Both);
        }
    }
}

extern "C" fn cb_open(
    ctx: *mut c_void,
    host: *const c_char,
    host_len: i32,
    port: i32,
    tls: i32,
) -> i32 {
    if ctx.is_null() || host.is_null() || host_len <= 0 {
        return -1;
    }
    let session = unsafe { &*(ctx as *const NetSession) };
    let bytes = unsafe { slice::from_raw_parts(host as *const u8, host_len as usize) };
    session.open(bytes, port, tls != 0)
}

extern "C" fn cb_write(ctx: *mut c_void, handle: i32, buf: *const c_void, len: i32) -> i32 {
    if ctx.is_null() || (buf.is_null() && len > 0) || len < 0 {
        return -1;
    }
    let session = unsafe { &*(ctx as *const NetSession) };
    let bytes = if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(buf as *const u8, len as usize) }
    };
    session.write(handle, bytes)
}

extern "C" fn cb_read(ctx: *mut c_void, handle: i32, buf: *mut c_void, cap: i32) -> i32 {
    if ctx.is_null() || buf.is_null() || cap <= 0 {
        return -1;
    }
    let session = unsafe { &*(ctx as *const NetSession) };
    let out = unsafe { slice::from_raw_parts_mut(buf as *mut u8, cap as usize) };
    session.read(handle, out)
}

extern "C" fn cb_close(ctx: *mut c_void, handle: i32) {
    if ctx.is_null() {
        return;
    }
    let session = unsafe { &*(ctx as *const NetSession) };
    session.close(handle);
}

pub(crate) static NET_VTABLE: ubit_net_vtable = ubit_net_vtable {
    open: Some(cb_open),
    write: Some(cb_write),
    read: Some(cb_read),
    close: Some(cb_close),
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_address_vectors_match_iana_policy() {
        let cases = [
            ("8.8.8.8", true),
            ("1.1.1.1", true),
            ("2606:4700:4700::1111", true),
            ("::ffff:8.8.8.8", true),
            ("64:ff9b::808:808", true),
            ("127.0.0.1", false),
            ("10.1.2.3", false),
            ("172.16.0.1", false),
            ("192.168.1.1", false),
            ("169.254.169.254", false),
            ("100.64.0.1", false),
            ("0.0.0.0", false),
            ("224.0.0.251", false),
            ("::1", false),
            ("::", false),
            ("fe80::1", false),
            ("fd00::1", false),
            ("ff02::1", false),
            ("::ffff:127.0.0.1", false),
            ("::ffff:10.0.0.1", false),
            ("64:ff9b::a00:1", false),
            ("2002:7f00:1::", false),
            ("2001:db8::1", false),
            ("64:ff9b:1::1", false),
            ("64:ff9b:1:ffff:ffff:ffff:ffff:ffff", false),
            ("3fff::1", false),
            ("3fff:fff:ffff::1", false),
            ("5f00::1", false),
            ("100::1", false),
            ("100:0:0:1::1", false),
        ];
        for (raw, want) in cases {
            let ip: IpAddr = raw.parse().expect(raw);
            assert_eq!(is_public_address(ip), want, "ip {raw}");
        }
    }
}
