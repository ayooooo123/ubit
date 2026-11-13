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

fn ffprobe_streams_and_duration(path: &std::path::Path) -> (Vec<String>, f64) {
    let out = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type,codec_name:format=duration",
            "-of",
            "json",
            path.to_str().unwrap(),
        ])
        .output()
        .expect("ffprobe");
    assert!(
        out.status.success(),
        "ffprobe failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let j: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let mut streams: Vec<String> = j["streams"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            format!(
                "{}:{}",
                s["codec_type"].as_str().unwrap_or(""),
                s["codec_name"].as_str().unwrap_or("")
            )
        })
        .collect();
    streams.sort();
    let dur: f64 = j["format"]["duration"]
        .as_str()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.0);
    // Also verify every packet decodes cleanly with zero errors.
    let dec = Command::new("ffmpeg")
        .args([
            "-v",
            "error",
            "-xerror",
            "-i",
            path.to_str().unwrap(),
            "-f",
            "null",
            "-",
        ])
        .output()
        .expect("ffmpeg decode check");
    assert!(
        dec.status.success(),
        "ffmpeg decode errors on {}: {}",
        path.display(),
        String::from_utf8_lossy(&dec.stderr)
    );
    (streams, dur)
}

#[tokio::test]
async fn webm_mkv_remux_and_opus_flac_passthrough_without_ffmpeg() {
    let tmp = std::env::temp_dir().join(format!("ubit-sdk-remux-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();
    let fix = tmp.join("fixtures");
    std::fs::create_dir_all(&fix).unwrap();

    let run_ff = |args: &[&str]| {
        let st = Command::new("ffmpeg")
            .args(args)
            .status()
            .expect("ffmpeg fixture build");
        assert!(st.success(), "ffmpeg failed for {args:?}");
    };

    // 1. Split VP9 video.webm + Opus audio.webm + AAC audio.m4a + lossless track.flac + 3-segment Ogg Opus HLS
    let v_webm = fix.join("video.webm");
    let a_webm = fix.join("audio.webm");
    let a_m4a = fix.join("audio.m4a");
    let flac_f = fix.join("track.flac");
    run_ff(&[
        "-y",
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc=duration=2:size=640x360:rate=24",
        "-c:v",
        "libvpx-vp9",
        "-b:v",
        "400k",
        "-an",
        v_webm.to_str().unwrap(),
    ]);
    run_ff(&[
        "-y",
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=2:sample_rate=48000",
        "-ac",
        "2",
        "-c:a",
        "libopus",
        "-b:a",
        "96k",
        "-vn",
        a_webm.to_str().unwrap(),
    ]);
    run_ff(&[
        "-y",
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=520:duration=2:sample_rate=48000",
        "-ac",
        "2",
        "-c:a",
        "aac",
        "-movflags",
        "+faststart",
        "-vn",
        a_m4a.to_str().unwrap(),
    ]);
    run_ff(&[
        "-y",
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=660:duration=2:sample_rate=44100",
        "-ac",
        "2",
        "-c:a",
        "flac",
        flac_f.to_str().unwrap(),
    ]);
    for seg in 0..3 {
        let p = fix.join(format!("seg{seg}.opus"));
        run_ff(&[
            "-y",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            &format!(
                "sine=frequency={}:duration=1:sample_rate=48000",
                330 + seg * 110
            ),
            "-ac",
            "2",
            "-c:a",
            "libopus",
            p.to_str().unwrap(),
        ]);
    }

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let fix_srv = fix.clone();

    let server = tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            let fix_dir = fix_srv.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let path = req
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().nth(1))
                    .unwrap_or("/");
                let reply = |ct: &str, body: Vec<u8>| -> Vec<u8> {
                    let mut r = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .into_bytes();
                    r.extend_from_slice(&body);
                    r
                };
                let payload = match path {
                    "/split-webm.m3u8" => reply(
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Opus\",DEFAULT=YES,URI=\"/a-webm.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360,AUDIO=\"aud\"\n/v-webm.m3u8\n".to_vec(),
                    ),
                    "/split-mixed.m3u8" => reply(
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"AAC\",DEFAULT=YES,URI=\"/a-m4a.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360,AUDIO=\"aud\"\n/v-webm.m3u8\n".to_vec(),
                    ),
                    "/v-webm.m3u8" => reply(
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\n/video.webm\n#EXT-X-ENDLIST\n".to_vec(),
                    ),
                    "/a-webm.m3u8" => reply(
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\n/audio.webm\n#EXT-X-ENDLIST\n".to_vec(),
                    ),
                    "/a-m4a.m3u8" => reply(
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\n/audio.m4a\n#EXT-X-ENDLIST\n".to_vec(),
                    ),
                    "/sc-opus.m3u8" => reply(
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:1.0,\n/seg0.opus\n#EXTINF:1.0,\n/seg1.opus\n#EXTINF:1.0,\n/seg2.opus\n#EXT-X-ENDLIST\n".to_vec(),
                    ),
                    "/flac-page" => reply(
                        "text/html",
                        format!("<html><head><title>Lossless FLAC</title><meta property=\"og:audio\" content=\"http://127.0.0.1:{port}/track.flac\"></head></html>").into_bytes(),
                    ),
                    other => {
                        let file = fix_dir.join(other.trim_start_matches('/'));
                        if let Ok(bytes) = std::fs::read(&file) {
                            reply("application/octet-stream", bytes)
                        } else {
                            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec()
                        }
                    }
                };
                let _ = sock.write_all(&payload).await;
            });
        }
    });

    let client = Client::with_address_filter(|ip| ip == IpAddr::V4(Ipv4Addr::LOCALHOST));
    let cfg = tmp.join("cfg");

    // Case 1a: Split VP9 WebM + Opus WebM -> native .webm remux (zero FFmpeg!)
    let out_webm = tmp.join("out-webm");
    let dl_webm = client
        .download(
            &format!("http://127.0.0.1:{port}/split-webm.m3u8"),
            &out_webm,
            DownloadOptions {
                config_dir: Some(cfg.clone()),
                ..Default::default()
            },
        )
        .await
        .expect("split VP9+Opus WebM remux");
    assert_eq!(
        dl_webm.path.extension().and_then(|e| e.to_str()),
        Some("webm")
    );
    let (st_webm, dur_webm) = ffprobe_streams_and_duration(&dl_webm.path);
    assert_eq!(st_webm, vec!["audio:opus", "video:vp9"]);
    assert!((dur_webm - 2.0).abs() < 0.3, "webm dur={dur_webm}");

    // Case 1b: Mixed VP9 WebM + AAC M4A -> native .mkv remux (zero FFmpeg!)
    let out_mkv = tmp.join("out-mkv");
    let dl_mkv = client
        .download(
            &format!("http://127.0.0.1:{port}/split-mixed.m3u8"),
            &out_mkv,
            DownloadOptions {
                config_dir: Some(cfg.clone()),
                ..Default::default()
            },
        )
        .await
        .expect("mixed VP9+AAC MKV remux");
    assert_eq!(
        dl_mkv.path.extension().and_then(|e| e.to_str()),
        Some("mkv")
    );
    let (st_mkv, dur_mkv) = ffprobe_streams_and_duration(&dl_mkv.path);
    assert_eq!(st_mkv, vec!["audio:aac", "video:vp9"]);
    assert!((dur_mkv - 2.0).abs() < 0.3, "mkv dur={dur_mkv}");

    // Case 2a: Lossless FLAC page passthrough -> .flac (zero FFmpeg!)
    let out_flac = tmp.join("out-flac");
    let dl_flac = client
        .download(
            &format!("http://127.0.0.1:{port}/flac-page"),
            &out_flac,
            DownloadOptions {
                config_dir: Some(cfg.clone()),
                ..Default::default()
            },
        )
        .await
        .expect("FLAC passthrough");
    assert_eq!(
        dl_flac.path.extension().and_then(|e| e.to_str()),
        Some("flac")
    );
    let (st_flac, dur_flac) = ffprobe_streams_and_duration(&dl_flac.path);
    assert_eq!(st_flac, vec!["audio:flac"]);
    assert!((dur_flac - 2.0).abs() < 0.2, "flac dur={dur_flac}");

    // Case 2b: Multi-segment Ogg Opus HLS -> single unchained .opus (~3.0s, NOT stuck at 1.0s!)
    let out_opus = tmp.join("out-opus");
    let dl_opus = client
        .download(
            &format!("http://127.0.0.1:{port}/sc-opus.m3u8"),
            &out_opus,
            DownloadOptions {
                config_dir: Some(cfg),
                ..Default::default()
            },
        )
        .await
        .expect("unchained Ogg Opus HLS");
    assert_eq!(
        dl_opus.path.extension().and_then(|e| e.to_str()),
        Some("opus")
    );
    let (st_opus, dur_opus) = ffprobe_streams_and_duration(&dl_opus.path);
    assert_eq!(st_opus, vec!["audio:opus"]);
    assert!(
        (dur_opus - 3.0).abs() < 0.3,
        "expected ~3.0s unchained opus, got {dur_opus}"
    );

    server.abort();
    let _ = std::fs::remove_dir_all(&tmp);
}
