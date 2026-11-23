#!/usr/bin/env python3
"""Compare two Swift CLI builds against media made by FFmpeg.

Usage: python3 tests/media/gate.py BASE_UBIT HEAD_UBIT [NEW_WORK_DIR]

Head must save one decodable file per case. For video layouts the gate compares
all decoded pictures, in order, with the source. It reports base inexactness but
allows none on head. If base succeeds, head may not send both 10% and 64 KiB more.
The range checks use HTTP/1.1 on loopback only. Requires FFmpeg with libx264.
"""
import argparse
from contextlib import contextmanager
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading


SECTIONS = (None, "0.5-1.5", "1.2-2.7", "2.0-3.0")
FRACTIONAL = (None, "0.4-0.49999", "0.4-0.5", "0.4-0.50001")
VOD = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n"
END = "#EXT-X-ENDLIST\n"


def ff(*args):
    subprocess.run(["ffmpeg", "-y", "-v", "error", *args], check=True)


def make_layouts(media):
    source = media / "source.mp4"
    ff("-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=4",
       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "15", "-bf", "2",
       "-c:a", "aac", "-b:a", "64k", str(source))
    layouts = {}
    for name, flags in (("mp4-bframes", ""), ("mp4-faststart", "+faststart"),
                        ("mp4-negcts", "+negative_cts_offsets"),
                        ("mp4-sidx", "+frag_keyframe+empty_moov+global_sidx+dash"),
                        ("fmp4", "+frag_keyframe+empty_moov+default_base_moof")):
        rel = f"{name}.mp4"
        ff("-i", str(source), "-c", "copy", *(["-movflags", flags] if flags else []), str(media / rel))
        layouts[name] = rel
    ff("-i", str(source), "-c", "copy", "-map", "0:a", str(media / "audio.m4a"))
    layouts["m4a"] = "audio.m4a"
    # Sound starts 0.5 s after the picture. FFmpeg writes an empty edit before the sound.
    ff("-i", str(source), "-itsoffset", "0.5", "-i", str(source), "-map", "0:v", "-map", "1:a",
       "-c", "copy", str(media / "mp4-delay.mp4"))
    layouts["mp4-delay"] = "mp4-delay.mp4"

    for name, kind, ext in (("hls-ts", "mpegts", "ts"), ("hls-fmp4", "fmp4", "m4s")):
        directory = media / name
        directory.mkdir()
        init = ["-hls_fmp4_init_filename", "init.mp4"] if kind == "fmp4" else []
        ff("-i", str(source), "-c", "copy", "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod",
           "-hls_segment_type", kind, *init, "-hls_segment_filename", str(directory / f"seg_%03d.{ext}"),
           str(directory / "index.m3u8"))
        layouts[name] = f"{name}/index.m3u8"
    split = media / "hls-split"
    split.mkdir()
    ff("-i", str(source), "-map", "0:v", "-map", "0:a", "-c", "copy", "-f", "hls", "-hls_time", "1",
       "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init_%v.mp4",
       "-var_stream_map", "v:0,agroup:aud a:0,agroup:aud", "-master_pl_name", "master.m3u8",
       "-hls_segment_filename", str(split / "s%v_%03d.m4s"), str(split / "p%v.m3u8"))
    layouts["hls-split"] = "hls-split/master.m3u8"

    solo = media / "hls-solo"
    solo.mkdir()
    # The keyframe interval is 1/3 s, which EXTINF cannot represent exactly.
    ff("-i", str(source), "-an", "-c:v", "libx264", "-g", "10", "-sc_threshold", "0", "-bf", "0",
       "-video_track_timescale", "30000", "-f", "hls", "-hls_time", "0.333", "-hls_playlist_type", "vod",
       "-hls_segment_type", "fmp4", "-hls_segment_filename", str(solo / "s%03d.m4s"), str(solo / "index.m3u8"))
    layouts["hls-solo"] = "hls-solo/index.m3u8"

    dash = media / "dash"
    dash.mkdir()
    ff("-i", str(source), "-map", "0:v", "-map", "0:a", "-c", "copy", "-f", "dash",
       "-seg_duration", "1", "-use_template", "1", "-use_timeline", "1", str(dash / "manifest.mpd"))
    layouts["dash"] = "dash/manifest.mpd"
    return layouts


def make_range_cases(media):
    # The second period starts with tfdt=0, behind the first period's decode time.
    (media / "hls-fmp4" / "reset.m3u8").write_text(
        VOD + '#EXT-X-MAP:URI="init.mp4"\n#EXTINF:1,\nseg_002.m4s\n#EXT-X-DISCONTINUITY\n'
        '#EXTINF:1,\nseg_000.m4s\n#EXTINF:1,\nseg_001.m4s\n' + END)
    split = media / "hls-split"
    video = [split / "init_0.mp4", split / "s0_000.m4s", split / "s0_001.m4s"]
    audio = [split / "init_1.mp4", split / "s1_000.m4s", split / "s1_001.m4s"]
    init, origin = (part.read_bytes() for part in video[:2])
    prefix = len(init) + len(origin)
    (split / "origin.mp4").write_bytes(init + origin + bytes(1024 * 1024))
    (split / "bounded.m3u8").write_text(
        VOD + f'#EXT-X-MAP:URI="origin.mp4",BYTERANGE="{len(init)}@0"\n'
        f'#EXTINF:1,\n#EXT-X-BYTERANGE:{len(origin)}@{len(init)}\norigin.mp4\n'
        '#EXTINF:1,\ns0_001.m4s\n#EXTINF:1,\ns0_002.m4s\n' + END)

    # One unchanged, tagged pack, with two URI spellings in the picture playlist
    # and one in the sound playlist. The paths resolve to the same server object.
    with (split / "shared.bin").open("wb") as pack:
        for stem, parts in (("packed-video", video), ("packed-audio", audio)):
            lines = [VOD]
            for index, part in enumerate(parts):
                data = part.read_bytes()
                span = f"{len(data)}@{pack.tell()}"
                pack.write(data)
                if index == 0:
                    lines.append(f'#EXT-X-MAP:URI="shared.bin",BYTERANGE="{span}"\n')
                else:
                    uri = "shared.bin#" if index == 2 and stem == "packed-video" else "shared.bin"
                    lines.append(f"#EXTINF:1,\n#EXT-X-BYTERANGE:{span}\n{uri}\n")
            (split / f"{stem}.m3u8").write_text("".join(lines) + END)
    (split / "packed.m3u8").write_text(
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="main",DEFAULT=YES,URI="packed-audio.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=128x96,CODECS="avc1.64000a,mp4a.40.2",AUDIO="a"\n'
        'packed-video.m3u8\n')
    return prefix


@contextmanager
def serve(root):
    requests = []
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_HEAD(self):
            self.answer(False)

        def do_GET(self):
            self.answer(True)

        def answer(self, body):
            path = (root / re.split(r"[?#]", self.path, 1)[0].lstrip("/")).resolve()
            if root not in path.parents or not path.is_file():
                self.send_error(404)
                return
            data = path.read_bytes()
            etag = None if path.name == "origin.mp4" else '"' + hashlib.sha256(data).hexdigest()[:16] + '"'
            if self.headers.get("If-Match") not in (None, etag):
                self.send_error(412)
                return
            start, end, partial = 0, len(data) - 1, False
            rng = self.headers.get("Range")
            if rng:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", rng)
                if match is None:
                    self.send_error(400)
                    return
                start = int(match[1])
                if match[2]:
                    end = min(end, int(match[2]))
                if start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(data)}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                partial = True
            self.send_response(206 if partial else 200)
            if etag:
                self.send_header("ETag", etag)
            self.send_header("Accept-Ranges", "bytes")
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            if body:
                chunk = memoryview(data)[start:end + 1]
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    # Count the response size even when the client stops reading early.
                    pass
                with lock:
                    requests.append((str(path.relative_to(root)), rng, len(chunk)))

        def log_message(self, *_):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}", requests
        finally:
            server.shutdown()
            thread.join()


def ffprobe(path, *args):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", *args, "-of", "json", str(path)]))


def frames(path):
    result = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0", "-an",
                             "-f", "framemd5", "-"], capture_output=True, text=True, check=True)
    return [line.rsplit(",", 1)[1].strip() for line in result.stdout.splitlines() if line and not line.startswith("#")]


def layout_index(media, rel):
    path = media / rel
    if path.suffix == ".mpd":
        # FFmpeg may not have a DASH reader. Join the picture representation for the reference.
        joined = media / "dash-video.mp4"
        with joined.open("wb") as file:
            for part in [path.parent / "init-stream0.m4s", *sorted(path.parent.glob("chunk-stream0-*.m4s"))]:
                file.write(part.read_bytes())
        path = joined
    pictures = frames(path)
    info = ffprobe(path, "-show_entries", "format=start_time", "-select_streams", "v:0",
                   "-show_entries", "frame=pts_time,key_frame")
    start = float(info["format"].get("start_time") or 0)
    rows = info["frames"]
    if not pictures or len(pictures) != len(rows):
        raise ValueError(f"{rel}: FFmpeg hashes and ffprobe timestamps do not match")
    return pictures, [float(row["pts_time"]) - start for row in rows], [row["key_frame"] == 1 for row in rows]


def expected(section, times, keys):
    if section is None:
        return 0, len(times) - 1
    start, end = map(float, section.split("-"))
    # ffprobe prints microseconds. Use a one-microsecond margin at an exact boundary.
    first = max((i for i, time in enumerate(times) if keys[i] and time <= start + 1e-6), default=0)
    last = max(i for i, time in enumerate(times) if time < end - 1e-6)
    return first, last


def shown_range(shown, source):
    if shown:
        for i, picture in enumerate(source):
            if shown[0] == picture and source[i:i + len(shown)] == shown:
                return f"{i}..{i + len(shown) - 1}"
    return "?"


def download(binary, work, media, rel, section, label):
    out, cfg = work / "out" / label, work / "cfg" / label
    out.mkdir(parents=True)
    cfg.mkdir(parents=True)
    args = [binary, "get", "--no-cookies", "--no-library", "--json", "-o", str(out)]
    if section:
        args += ["--section", section]
    env = {k: v for k, v in os.environ.items() if k.lower() not in {"http_proxy", "https_proxy", "all_proxy"}}
    env.update(UBIT_CONFIG_DIR=str(cfg), NO_PROXY="*", no_proxy="*")
    with serve(media) as (url, requests):
        proc = subprocess.run(args + [f"{url}/{rel}"], env=env, capture_output=True, text=True, timeout=120)
    files = list(out.iterdir())
    last = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else proc.stderr.strip()
    if proc.returncode or len(files) != 1 or not files[0].is_file():
        return None, requests, f"exit={proc.returncode}: {last}"
    check = subprocess.run(["ffmpeg", "-v", "error", "-i", str(files[0]), "-f", "null", "-"], capture_output=True, text=True)
    if check.returncode or check.stderr.strip():
        return None, requests, f"decode: {check.stderr.strip()}"
    return files[0], requests, ""


def matrix(base, head, work, media, layouts):
    failures = []
    print(f"{'layout':13} {'section':12} {'base (seen/expected)':33} head (seen/expected)")
    for name, rel in layouts.items():
        index = None if name == "m4a" else layout_index(media, rel)
        for section in FRACTIONAL if name == "hls-solo" else SECTIONS:
            row = f"{name}-{section or 'whole'}"
            results = []
            for label, binary in (("base", base), ("head", head)):
                path, requests, error = download(binary, work, media, rel, section, f"{row}-{label}")
                sent = sum(size for _, _, size in requests)
                shown, exact = "", True
                if index is not None and path is not None:
                    source, times, keys = index
                    first, last = expected(section, times, keys)
                    try:
                        pictures = frames(path)
                    except subprocess.CalledProcessError:
                        pictures = []
                    shown = f" x={pictures == source[first:last + 1]} {shown_range(pictures, source)}/{first}..{last}"
                    exact = pictures == source[first:last + 1]
                results.append((path, sent, f"{'ok' if path else 'FAIL'}{shown} {sent} B"))
                if label == "head" and (path is None or not exact):
                    failures.append(f"{row}: {error or 'head shows the wrong pictures'}")
            b, h = results
            if b[0] and h[1] > b[1] * 1.1 and h[1] - b[1] > 65536:
                failures.append(f"{row}: head sends {h[1]} B, base {b[1]} B")
            print(f"{name:13} {section or 'whole':12} {b[2]:33} {h[2]}")
    return failures


def range_cases(head, work, media, prefix):
    failures = []
    for name, rel, section in (("hls-reset", "hls-fmp4/reset.m3u8", "2.2-2.8"),
                               ("hls-bounded-origin", "hls-split/bounded.m3u8", "2.2-2.8"),
                               ("hls-shared-spellings", "hls-split/packed.m3u8", None)):
        path, requests, error = download(head, work, media, rel, section, name)
        if path is not None:
            if name == "hls-reset" and any(part == "hls-fmp4/seg_002.m4s" for part, _, _ in requests):
                error = "fetched the segment before the discontinuity"
            elif name == "hls-bounded-origin":
                reads = [(rng, size) for part, rng, size in requests if part == "hls-split/origin.mp4"]
                if reads != [(f"bytes=0-{prefix - 1}", prefix)]:
                    error = f"expected one bounded init and clock read; got {reads}"
            elif name == "hls-shared-spellings":
                streams = ffprobe(path, "-show_entries", "stream=codec_type")["streams"]
                if {stream["codec_type"] for stream in streams} != {"audio", "video"}:
                    error = "the shared pack did not save both tracks"
        if error:
            failures.append(f"{name}: {error}")
        print(f"{name}: {'FAIL' if error else 'PASS'}")
    return failures


def main(base, head, work):
    media = work / "media"
    media.mkdir()
    layouts = make_layouts(media)
    prefix = make_range_cases(media)
    failures = matrix(base, head, work, media, layouts) + range_cases(head, work, media, prefix)
    if failures:
        print("\nGATE FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("\nGATE PASSED")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", type=Path)
    parser.add_argument("head", type=Path)
    parser.add_argument("work", type=Path, nargs="?")
    args = parser.parse_args()
    if args.work is not None:
        args.work.mkdir()
        raise SystemExit(main(args.base.resolve(), args.head.resolve(), args.work.resolve()))
    with tempfile.TemporaryDirectory(prefix="ubit-media-") as directory:
        raise SystemExit(main(args.base.resolve(), args.head.resolve(), Path(directory).resolve()))
