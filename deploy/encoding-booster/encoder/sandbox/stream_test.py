"""Run inside the Linux test image containing the broker, launcher and adapter."""
import http.server
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading


with tempfile.TemporaryDirectory() as folder:
    job = Path(folder)
    subprocess.run([
        "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
        "testsrc2=size=256x144:rate=25", "-t", "5", "-c:v", "libx264",
        "-preset", "ultrafast", str(job / "source.mp4"),
    ], check=True)
    content = (job / "source.mp4").read_bytes()
    requests = []

    class Origin(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            assert self.path == "/source?signature=test-only"
            assert self.headers.get("Referer") == "test-only-private-referer"
            span = self.headers.get("Range")
            requests.append(span)
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", span or "")
            start = int(match[1]) if match else 0
            end = int(match[2]) if match and match[2] else len(content) - 1
            self.send_response(206 if match else 200)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            if match:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(content)}")
            self.end_headers()
            try:
                self.wfile.write(content[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    source = f"http://127.0.0.1:{server.server_port}/source?signature=test-only"
    headers = ["-headers", "Referer: test-only-private-referer\r\n"]
    launcher = ["mave-media-broker", "--scratch", str(job), "--"]
    env = dict(os.environ, AWS_SECRET_ACCESS_KEY="test-only-parent-secret")

    def run(tool, args, **kwargs):
        executable = subprocess.check_output(["which", tool], text=True).strip()
        return subprocess.run(launcher + [executable] + args, env=env, check=True,
                              timeout=60, **kwargs)

    probe = run("ffprobe", ["-v", "error"] + headers + ["-show_entries", "format=duration", source],
                stdout=subprocess.PIPE, text=True)
    assert "duration=5." in probe.stdout, probe.stdout
    run("ffmpeg", ["-nostdin", "-v", "error"] + headers + ["-ss", "2", "-i", source,
                  "-t", "0.5", "-c:v", "libx264", str(job / "encoded.mp4")])
    run("ffmpeg", ["-nostdin", "-v", "error", "-i", str(job / "encoded.mp4"),
                  "-c", "copy", "-f", "hls", str(job / "playlist.m3u8")])
    # Remote concat entries are delivered over stdin by the CPU booster.
    run("ffmpeg", ["-nostdin", "-v", "error"] + headers + ["-protocol_whitelist", "file,http,tcp,pipe",
                  "-f", "concat", "-safe", "0", "-i", "pipe:0", "-c", "copy", str(job / "concat.mp4")],
        input=f"file '{source}'\nfile '{source}'\n", text=True)
    assert (job / "playlist.m3u8").stat().st_size > 0
    assert (job / "concat.mp4").stat().st_size > len(content)
    assert any(span and span != "bytes=0-" for span in requests), requests
    server.shutdown()
    print("confined streaming, seek, probe, encode, concat and HLS passed")
