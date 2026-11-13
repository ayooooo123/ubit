use std::net::{IpAddr, Ipv4Addr};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use ubit::{CancelToken, Client, DownloadOptions, InfoOptions};

#[tokio::test]
async fn ssrf_blocks_loopback_by_default_and_blocks_private_redirects() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            tokio::spawn(async move {
                let mut buf = [0u8; 2048];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                if req.starts_with("GET /redir ") {
                    let resp = format!(
                        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.2:{port}/clip.mp4\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                } else {
                    let body = b"<html><head><meta property=\"og:title\" content=\"Loopback\"><meta property=\"og:video\" content=\"/clip.mp4\"></head></html>";
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                    let _ = sock.write_all(body).await;
                }
            });
        }
    });

    // 1. Default Client refuses 127.0.0.1 outright.
    let client = Client::new();
    let err = client
        .info_json(
            &format!("http://127.0.0.1:{port}/page"),
            InfoOptions::default(),
        )
        .await
        .expect_err("loopback must be blocked by SSRF policy");
    assert!(err.message.contains("127.0.0.1"), "unexpected error: {err}");

    // 2. Redirect to 127.0.0.2 is refused when only 127.0.0.1 is permitted.
    let only_lo1 = Client::with_address_filter(|ip| ip == IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)));
    let redir_err = only_lo1
        .info_json(
            &format!("http://127.0.0.1:{port}/redir"),
            InfoOptions::default(),
        )
        .await
        .expect_err("redirect to 127.0.0.2 must be blocked");
    assert!(!redir_err.message.is_empty());

    server.abort();
}

#[tokio::test]
async fn info_and_download_mux_and_instant_cancel() {
    let tmp = std::env::temp_dir().join(format!("ubit-sdk-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();
    let src_mp4 = tmp.join("fixture.mp4");

    // Generate a 2s H.264 + AAC MP4 fixture with ffmpeg.
    let status = Command::new("ffmpeg")
        .args([
            "-y",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=2:size=320x240:rate=24",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=2",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            "-movflags",
            "+faststart",
            src_mp4.to_str().unwrap(),
        ])
        .status()
        .expect("ffmpeg installed");
    assert!(status.success());
    let mp4_bytes = Arc::new(std::fs::read(&src_mp4).unwrap());

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mp4_srv = mp4_bytes.clone();

    let server = tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            let mp4 = mp4_srv.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let first = req.lines().next().unwrap_or("");
                if first.contains(" /watch ") {
                    let html = format!(
                        "<html><head><title>SDK Clip</title><meta property=\"og:title\" content=\"SDK Clip\"><meta property=\"og:video\" content=\"http://127.0.0.1:{port}/clip.mp4\"></head></html>"
                    );
                    let hdr = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        html.len()
                    );
                    let _ = sock.write_all(hdr.as_bytes()).await;
                    let _ = sock.write_all(html.as_bytes()).await;
                } else if first.contains(" /hang.mp4 ") {
                    let is_head = first.starts_with("HEAD ");
                    let is_probe = req.to_ascii_lowercase().contains("range: bytes=0-0");
                    if is_head {
                        let _ = sock
                            .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 10000000\r\nConnection: close\r\n\r\n")
                            .await;
                    } else if is_probe {
                        let _ = sock
                            .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 1\r\nConnection: close\r\n\r\n\0")
                            .await;
                    } else {
                        let _ = sock
                            .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 10000000\r\nConnection: close\r\n\r\n")
                            .await;
                        let _ = sock.write_all(&[0u8; 4096]).await;
                        tokio::time::sleep(Duration::from_millis(150)).await;
                        let _ = sock.write_all(&[0u8; 4096]).await;
                        tokio::time::sleep(Duration::from_secs(30)).await;
                    }
                } else if first.contains(" /clip.mp4 ") {
                    let range = req
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        .and_then(|l| l.split('=').nth(1))
                        .map(str::trim);
                    if let Some(spec) = range {
                        let mut parts = spec.split('-');
                        let start: usize = parts.next().unwrap_or("0").parse().unwrap_or(0);
                        let end: usize = parts
                            .next()
                            .filter(|s| !s.is_empty())
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(mp4.len() - 1)
                            .min(mp4.len() - 1);
                        let slice = &mp4[start..=end];
                        let hdr = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes {start}-{end}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            mp4.len(),
                            slice.len()
                        );
                        let _ = sock.write_all(hdr.as_bytes()).await;
                        let _ = sock.write_all(slice).await;
                    } else {
                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            mp4.len()
                        );
                        let _ = sock.write_all(hdr.as_bytes()).await;
                        let _ = sock.write_all(&mp4).await;
                    }
                }
            });
        }
    });

    let client = Client::with_address_filter(|ip| ip == IpAddr::V4(Ipv4Addr::LOCALHOST));
    let cfg_dir = tmp.join("cfg");
    let out_dir = tmp.join("out");

    // 1. Metadata extraction
    let info = client
        .info_json(
            &format!("http://127.0.0.1:{port}/watch"),
            InfoOptions {
                config_dir: Some(cfg_dir.clone()),
                ..Default::default()
            },
        )
        .await
        .expect("info_json succeeds");
    assert_eq!(info["title"], "SDK Clip");

    // 2. Full download + mux
    let samples = Arc::new(Mutex::new(Vec::new()));
    let samples_cb = samples.clone();
    let dl = client
        .download(
            &format!("http://127.0.0.1:{port}/watch"),
            &out_dir,
            DownloadOptions {
                config_dir: Some(cfg_dir.clone()),
                connections: 4,
                on_progress: Some(Box::new(move |p| {
                    samples_cb.lock().unwrap().push(p.downloaded)
                })),
                ..Default::default()
            },
        )
        .await
        .expect("download succeeds");
    assert!(dl.path.is_file());
    assert!(dl.size > 1000);
    let saved_hdr = &std::fs::read(&dl.path).unwrap()[4..8];
    assert_eq!(saved_hdr, b"ftyp");

    // 3. Hard socket shutdown on CancelToken::cancel()
    let cancel = CancelToken::new();
    let cancel_trigger = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        cancel_trigger.cancel();
    });
    let t0 = Instant::now();
    let hang_err = client
        .download(
            &format!("http://127.0.0.1:{port}/hang.mp4"),
            &out_dir,
            DownloadOptions {
                config_dir: Some(cfg_dir.clone()),
                connections: 1,
                cancel: Some(cancel),
                ..Default::default()
            },
        )
        .await
        .expect_err("cancelled download must fail");
    assert!(
        hang_err.is_cancelled(),
        "expected Cancelled, got {hang_err:?}"
    );
    assert!(
        t0.elapsed() < Duration::from_secs(3),
        "cancel took {:?}",
        t0.elapsed()
    );

    // 4. Stall watchdog shuts down hung stream and surfaces Source stalled
    let t_stall = Instant::now();
    let stall_err = client
        .download(
            &format!("http://127.0.0.1:{port}/hang.mp4"),
            &out_dir,
            DownloadOptions {
                config_dir: Some(cfg_dir),
                connections: 1,
                stall_timeout: Duration::from_millis(250),
                ..Default::default()
            },
        )
        .await
        .expect_err("stalled download must fail");
    assert!(
        stall_err.is_timed_out(),
        "expected TimedOut, got {stall_err:?}"
    );
    assert_eq!(stall_err.message, "Source stalled");
    assert!(t_stall.elapsed() < Duration::from_secs(60));

    server.abort();
    let _ = std::fs::remove_dir_all(&tmp);
}
