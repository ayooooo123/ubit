//! Embeddable Rust SDK for uBit: 35+ site extractors, HLS/DASH/MPEG-TS demuxing,
//! zero-FFmpeg fast-start MP4/M4A muxing, verified `rustls` TLS, and public-IP SSRF protection.

mod net;

use std::ffi::{c_char, c_void, CStr, CString};
use std::fmt;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub use net::{is_public_address, AddressFilter};
use net::{NetSession, NET_VTABLE};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[allow(non_camel_case_types)]
pub(crate) mod ffi {
    use std::ffi::{c_char, c_void};

    #[repr(C)]
    pub struct ubit_net_vtable {
        pub open: Option<
            extern "C" fn(
                ctx: *mut c_void,
                host: *const c_char,
                host_len: i32,
                port: i32,
                tls: i32,
            ) -> i32,
        >,
        pub write: Option<
            extern "C" fn(ctx: *mut c_void, handle: i32, buf: *const c_void, len: i32) -> i32,
        >,
        pub read:
            Option<extern "C" fn(ctx: *mut c_void, handle: i32, buf: *mut c_void, cap: i32) -> i32>,
        pub close: Option<extern "C" fn(ctx: *mut c_void, handle: i32)>,
    }

    #[repr(C)]
    pub struct ubit_cancel {
        _priv: [u8; 0],
    }

    pub type ubit_progress_fn = Option<
        extern "C" fn(
            ctx: *mut c_void,
            fraction: f64,
            downloaded: i64,
            total: i64,
            speed: i64,
            eta_secs: i32,
        ),
    >;
    pub type ubit_stage_fn = Option<extern "C" fn(ctx: *mut c_void, stage: *const c_char)>;

    extern "C" {
        pub fn ubit_cancel_new() -> *mut ubit_cancel;
        pub fn ubit_cancel_trip(cancel: *mut ubit_cancel);
        pub fn ubit_cancel_free(cancel: *mut ubit_cancel);

        pub fn ubit_sdk_info_json(
            url: *const c_char,
            config_dir: *const c_char,
            net: *const ubit_net_vtable,
            net_ctx: *mut c_void,
            out_json: *mut *mut c_char,
            out_error: *mut *mut c_char,
        ) -> i32;

        pub fn ubit_sdk_download(
            url: *const c_char,
            out_dir: *const c_char,
            config_dir: *const c_char,
            connections: i32,
            net: *const ubit_net_vtable,
            net_ctx: *mut c_void,
            on_progress: ubit_progress_fn,
            on_stage: ubit_stage_fn,
            cb_ctx: *mut c_void,
            cancel: *mut ubit_cancel,
            out_path: *mut *mut c_char,
            out_size: *mut i64,
            out_error: *mut *mut c_char,
        ) -> i32;

        pub fn ubit_sdk_free_string(str: *mut c_char);
    }
}

struct NativeCancel(*mut ffi::ubit_cancel);
unsafe impl Send for NativeCancel {}
unsafe impl Sync for NativeCancel {}

impl NativeCancel {
    fn new() -> Self {
        Self(unsafe { ffi::ubit_cancel_new() })
    }

    fn trip(&self) {
        if !self.0.is_null() {
            unsafe { ffi::ubit_cancel_trip(self.0) };
        }
    }
}

impl Drop for NativeCancel {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { ffi::ubit_cancel_free(self.0) };
        }
    }
}

fn take_cstr(ptr: *mut c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    unsafe { ffi::ubit_sdk_free_string(ptr) };
    Some(text)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    DrmProtected,
    Cancelled,
    TimedOut,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub kind: ErrorKind,
    pub message: String,
}

impl Error {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub fn is_drm(&self) -> bool {
        self.kind == ErrorKind::DrmProtected
    }

    pub fn is_cancelled(&self) -> bool {
        self.kind == ErrorKind::Cancelled
    }

    pub fn is_timed_out(&self) -> bool {
        self.kind == ErrorKind::TimedOut
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

/// Live progress sample emitted during `Client::download`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Progress {
    pub fraction: f64,
    pub downloaded: u64,
    pub total: Option<u64>,
    pub speed_bps: u64,
    pub eta_secs: Option<u32>,
}

/// Completed file output from `Client::download`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Downloaded {
    pub path: PathBuf,
    pub size: u64,
}

/// Thread-safe cancellation token: tripping it aborts worker threads and shuts down active sockets immediately.
#[derive(Clone, Default)]
pub struct CancelToken {
    inner: Arc<CancelInner>,
}

type CancelHook = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
struct CancelInner {
    cancelled: std::sync::atomic::AtomicBool,
    hooks: Mutex<Vec<CancelHook>>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.inner
            .cancelled
            .store(true, std::sync::atomic::Ordering::SeqCst);
        let hooks: Vec<_> = self.inner.hooks.lock().unwrap().drain(..).collect();
        for hook in hooks {
            hook();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner
            .cancelled
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    fn register(&self, hook: CancelHook) {
        if self.is_cancelled() {
            hook();
        } else {
            self.inner.hooks.lock().unwrap().push(hook);
        }
    }
}

#[derive(Clone)]
pub struct InfoOptions {
    pub config_dir: Option<PathBuf>,
    pub timeout: Duration,
    pub cancel: Option<CancelToken>,
}

impl Default for InfoOptions {
    fn default() -> Self {
        Self {
            config_dir: None,
            timeout: Duration::from_secs(45),
            cancel: None,
        }
    }
}

pub type ProgressCallback = Box<dyn FnMut(Progress) + Send>;
pub type StageCallback = Box<dyn FnMut(&str) + Send>;

pub struct DownloadOptions {
    pub config_dir: Option<PathBuf>,
    pub connections: u8,
    pub stall_timeout: Duration,
    pub cancel: Option<CancelToken>,
    pub on_progress: Option<ProgressCallback>,
    pub on_stage: Option<StageCallback>,
}

impl Default for DownloadOptions {
    fn default() -> Self {
        Self {
            config_dir: None,
            connections: 8,
            stall_timeout: Duration::from_secs(30),
            cancel: None,
            on_progress: None,
            on_stage: None,
        }
    }
}

/// Sandboxed uBit SDK client. Enforces `is_public_address` on all resolved DNS records and redirects by default.
#[derive(Clone)]
pub struct Client {
    allow_address: AddressFilter,
}

impl Default for Client {
    fn default() -> Self {
        Self::new()
    }
}

impl Client {
    pub fn new() -> Self {
        Self {
            allow_address: Arc::new(is_public_address),
        }
    }

    pub fn with_address_filter(filter: impl Fn(IpAddr) -> bool + Send + Sync + 'static) -> Self {
        Self {
            allow_address: Arc::new(filter),
        }
    }

    /// Probes a page or media URL and returns the structured `ubit info --json` metadata object.
    pub async fn info_json(&self, url: &str, opts: InfoOptions) -> Result<Value, Error> {
        if opts.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
            return Err(Error::new(ErrorKind::Cancelled, "Cancelled"));
        }
        let c_url = CString::new(url).map_err(|_| Error::new(ErrorKind::Failed, "Invalid URL"))?;
        let cfg_str = opts
            .config_dir
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        let c_cfg = CString::new(cfg_str)
            .map_err(|_| Error::new(ErrorKind::Failed, "Invalid config directory"))?;

        let session = NetSession::new(self.allow_address.clone());
        if let Some(cancel) = &opts.cancel {
            let s = session.clone();
            cancel.register(Arc::new(move || s.abort()));
        }

        let session_bg = session.clone();
        let mut task = tokio::task::spawn_blocking(move || {
            let mut out_json: *mut c_char = ptr::null_mut();
            let mut out_err: *mut c_char = ptr::null_mut();
            let code = unsafe {
                ffi::ubit_sdk_info_json(
                    c_url.as_ptr(),
                    c_cfg.as_ptr(),
                    &NET_VTABLE,
                    Arc::as_ptr(&session_bg) as *mut c_void,
                    &mut out_json,
                    &mut out_err,
                )
            };
            let json_str = take_cstr(out_json);
            let err_str = take_cstr(out_err);
            (code, json_str, err_str)
        });

        let timed = tokio::time::timeout(opts.timeout, &mut task).await;
        let (code, json_str, err_str) = match timed {
            Ok(Ok(res)) => res,
            Ok(Err(_)) => {
                return Err(Error::new(
                    ErrorKind::Failed,
                    "This page has no video ubit can read",
                ));
            }
            Err(_) => {
                session.abort();
                let _ = task.await;
                return Err(Error::new(
                    ErrorKind::TimedOut,
                    "This page has no video ubit can read",
                ));
            }
        };

        if opts.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
            return Err(Error::new(ErrorKind::Cancelled, "Cancelled"));
        }
        if code == 451 {
            return Err(Error::new(
                ErrorKind::DrmProtected,
                err_str.unwrap_or_else(|| "This video is DRM-protected".to_owned()),
            ));
        }
        if code != 0 {
            let msg = err_str
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "This page has no video ubit can read".to_owned());
            return Err(Error::new(ErrorKind::Failed, msg));
        }
        let raw =
            json_str.ok_or_else(|| Error::new(ErrorKind::Failed, "ubit returned no metadata"))?;
        let parsed: Value = serde_json::from_str(&raw)
            .ok()
            .filter(Value::is_object)
            .ok_or_else(|| Error::new(ErrorKind::Failed, "ubit returned no metadata"))?;
        if parsed
            .get("isDRM")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            return Err(Error::new(
                ErrorKind::DrmProtected,
                "This video is DRM-protected",
            ));
        }
        Ok(parsed)
    }

    /// Downloads and muxes a page or adaptive HLS/DASH stream into `out_dir` with stall watchdog & live progress.
    pub async fn download(
        &self,
        url: &str,
        out_dir: &Path,
        mut opts: DownloadOptions,
    ) -> Result<Downloaded, Error> {
        if opts.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
            return Err(Error::new(ErrorKind::Cancelled, "Cancelled"));
        }
        let c_url = CString::new(url).map_err(|_| Error::new(ErrorKind::Failed, "Invalid URL"))?;
        let c_out = CString::new(out_dir.to_string_lossy().as_bytes())
            .map_err(|_| Error::new(ErrorKind::Failed, "Invalid output directory"))?;
        let cfg_str = opts
            .config_dir
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        let c_cfg = CString::new(cfg_str)
            .map_err(|_| Error::new(ErrorKind::Failed, "Invalid config directory"))?;

        let session = NetSession::new(self.allow_address.clone());
        let native_cancel = Arc::new(NativeCancel::new());
        if let Some(cancel) = &opts.cancel {
            let s = session.clone();
            let nc = native_cancel.clone();
            cancel.register(Arc::new(move || {
                nc.trip();
                s.abort();
            }));
        }

        enum CbMsg {
            Progress(Progress),
            Stage(String),
        }

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<CbMsg>();

        struct BridgeCtx {
            tx: tokio::sync::mpsc::UnboundedSender<CbMsg>,
        }

        extern "C" fn progress_trampoline(
            ctx: *mut c_void,
            fraction: f64,
            downloaded: i64,
            total: i64,
            speed: i64,
            eta_secs: i32,
        ) {
            if ctx.is_null() {
                return;
            }
            let b = unsafe { &*(ctx as *const BridgeCtx) };
            let _ = b.tx.send(CbMsg::Progress(Progress {
                fraction,
                downloaded: downloaded.max(0) as u64,
                total: (total > 0).then_some(total as u64),
                speed_bps: speed.max(0) as u64,
                eta_secs: (eta_secs >= 0).then_some(eta_secs as u32),
            }));
        }

        extern "C" fn stage_trampoline(ctx: *mut c_void, stage: *const c_char) {
            if ctx.is_null() || stage.is_null() {
                return;
            }
            let b = unsafe { &*(ctx as *const BridgeCtx) };
            let s = unsafe { CStr::from_ptr(stage) }
                .to_string_lossy()
                .into_owned();
            let _ = b.tx.send(CbMsg::Stage(s));
        }

        let connections = i32::from(opts.connections.max(1));
        let session_bg = session.clone();
        let nc_bg = native_cancel.clone();

        let mut task = tokio::task::spawn_blocking(move || {
            let bridge = BridgeCtx { tx };
            let mut out_path: *mut c_char = ptr::null_mut();
            let mut out_size: i64 = 0;
            let mut out_err: *mut c_char = ptr::null_mut();
            let code = unsafe {
                ffi::ubit_sdk_download(
                    c_url.as_ptr(),
                    c_out.as_ptr(),
                    c_cfg.as_ptr(),
                    connections,
                    &NET_VTABLE,
                    Arc::as_ptr(&session_bg) as *mut c_void,
                    Some(progress_trampoline),
                    Some(stage_trampoline),
                    (&bridge as *const BridgeCtx) as *mut c_void,
                    nc_bg.0,
                    &mut out_path,
                    &mut out_size,
                    &mut out_err,
                )
            };
            drop(bridge);
            (code, take_cstr(out_path), out_size, take_cstr(out_err))
        });

        let stall = opts.stall_timeout;
        let startup = stall.max(Duration::from_secs(45));
        let process_wait = stall.saturating_mul(4).max(Duration::from_secs(120));
        let mut deadline = Box::pin(tokio::time::sleep(startup));
        let mut stalled = false;

        let joined = loop {
            tokio::select! {
                res = &mut task => break res,
                Some(msg) = rx.recv() => {
                    match msg {
                        CbMsg::Progress(p) => {
                            deadline = Box::pin(tokio::time::sleep(stall));
                            if let Some(cb) = opts.on_progress.as_mut() {
                                cb(p);
                            }
                        }
                        CbMsg::Stage(s) => {
                            deadline = Box::pin(tokio::time::sleep(process_wait));
                            if let Some(cb) = opts.on_stage.as_mut() {
                                cb(&s);
                            }
                        }
                    }
                }
                _ = &mut deadline, if !stalled => {
                    stalled = true;
                    native_cancel.trip();
                    session.abort();
                    deadline = Box::pin(tokio::time::sleep(Duration::from_secs(3600)));
                }
            }
        };

        // Drain any buffered progress/stage callbacks emitted just before exit.
        while let Ok(msg) = rx.try_recv() {
            match msg {
                CbMsg::Progress(p) => {
                    if let Some(cb) = opts.on_progress.as_mut() {
                        cb(p);
                    }
                }
                CbMsg::Stage(s) => {
                    if let Some(cb) = opts.on_stage.as_mut() {
                        cb(&s);
                    }
                }
            }
        }

        if opts.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
            return Err(Error::new(ErrorKind::Cancelled, "Cancelled"));
        }
        if stalled {
            return Err(Error::new(ErrorKind::TimedOut, "Source stalled"));
        }

        let (code, path_str, size, err_str) = joined
            .map_err(|_| Error::new(ErrorKind::Failed, "ubit failed to download this page"))?;

        if code == 130 {
            return Err(Error::new(ErrorKind::Cancelled, "Cancelled"));
        }
        if code == 451 {
            return Err(Error::new(
                ErrorKind::DrmProtected,
                err_str.unwrap_or_else(|| "This video is DRM-protected".to_owned()),
            ));
        }
        if code != 0 {
            let msg = err_str
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "ubit failed to download this page".to_owned());
            return Err(Error::new(ErrorKind::Failed, msg));
        }
        let Some(path_str) = path_str.filter(|s| !s.is_empty()) else {
            return Err(Error::new(
                ErrorKind::Failed,
                "ubit failed to download this page",
            ));
        };
        Ok(Downloaded {
            path: PathBuf::from(path_str),
            size: size.max(0) as u64,
        })
    }
}
