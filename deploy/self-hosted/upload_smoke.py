#!/usr/bin/env python3
"""Exercise the configured upload image through the actual quickstart entrypoint."""
import http.client
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()

root = Path(__file__).resolve().parents[2]
config = json.loads(docker("compose", "--env-file", "/dev/null", "-f",
                           str(root / "compose.yaml"), "config", "--format", "json"))
upload = config["services"]["upload"]
image = sys.argv[1] if len(sys.argv) > 1 else upload["image"]
entrypoint, *entry_args = upload["entrypoint"]
assert docker("run", "--rm", "--entrypoint", "id", image, "-u") == "1000"
# Use public synthetic values, never the installation's generated credentials.
fixture = tempfile.TemporaryDirectory(prefix="mave-upload-smoke-")
setup = Path(fixture.name)
setup.chmod(0o755)
environment = setup / "environment.sh"
environment.write_text("export POSTGRES_PASSWORD=test S3_ACCESS_KEY=test "
                       "S3_SECRET_KEY=test MAVE_UPLOAD_HOOK_SECRET=test\n")
environment.chmod(0o644)
mounts = ("-v", f"{setup}:/setup:ro", "-v",
          f"{root / 'deploy/self-hosted/quickstart'}:/bootstrap:ro")
container = docker("run", "-d", "-p", "127.0.0.1::8080", *mounts,
                   "--entrypoint", entrypoint, image, *entry_args,
                   "-host=0.0.0.0", "-port=8080", "-upload-dir=/srv/tusd-data",
                   # Empty selects all hooks in tusd. Only enable a nonblocking
                   # event here; smoke.sh tests real hooks against the app.
                   "-hooks-enabled-events=post-finish")
try:
    ports = json.loads(docker("inspect", container))[0]["NetworkSettings"]["Ports"]
    if not ports.get("8080/tcp"):
        raise AssertionError("quickstart upload failed to start: " + docker("logs", container))
    port = int(ports["8080/tcp"][0]["HostPort"])
    def request(method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request(method, path, body, headers or {})
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        conn.close()
        return result
    for attempt in range(40):
        try:
            status, _, _ = request("OPTIONS", "/files/")
            if status == 200: break
        except (OSError, http.client.HTTPException): pass
        time.sleep(0.25)
    else: raise AssertionError("tusd did not become ready")
    version = {"Tus-Resumable": "1.0.0"}
    status, headers, _ = request("POST", "/files/", headers={**version, "Upload-Length": "6"})
    assert status == 201, status
    from urllib.parse import urlsplit
    path = urlsplit(headers["Location"]).path
    patch = {**version, "Content-Type": "application/offset+octet-stream"}
    assert request("PATCH", path, b"abc", {**patch, "Upload-Offset": "0"})[0] == 204
    status, headers, _ = request("HEAD", path, headers=version)
    assert status == 200 and headers["Upload-Offset"] == "3"
    assert request("PATCH", path, b"bad", {**patch, "Upload-Offset": "0"})[0] == 409
    assert request("PATCH", path, b"def", {**patch, "Upload-Offset": "3"})[0] == 204
    status, headers, _ = request("HEAD", path, headers=version)
    assert status == 200 and headers["Upload-Offset"] == "6"
    print("PASS: quickstart entrypoint, unprivileged user, create/PATCH/resume/conflict/completion")
finally:
    subprocess.run(["docker", "rm", "-f", container], check=False, stdout=subprocess.DEVNULL)
    fixture.cleanup()
