#!/usr/bin/env python3
"""Check the tusd image trust bundle and resumable-upload contract in isolation."""
import hashlib
import http.client
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import time

image = sys.argv[1]

def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()

pem = docker("run", "--rm", "--network=none", "--entrypoint", "cat", image,
             "/etc/ssl/certs/ca-certificates.crt")
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.load_verify_locations(cadata=pem)
blocked = {"86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b",
           "d7a7a0fb5d7e2731d771e9484ebcdef71d5f0c3e0a2948782bc83ee0ea699ef4",
           "7dd78d5f4f13459a83dff9abbba62edbaf6f2d102bf257fd712f4d9f2746ed8d",
           "f2edaaff3d9b701fb4d14c9f285f8c0bad90fc3bcc1fa07d47f4718edaba34a5"}
fingerprints = {hashlib.sha256(c).hexdigest() for c in context.get_ca_certs(binary_form=True)}
assert len(fingerprints) > 100 and not fingerprints.intersection(blocked)
assert "Version: v2.5.0" in docker("run", "--rm", image, "-version")
assert docker("run", "--rm", "--entrypoint", "id", image, "-u") == "1000"
container = docker("run", "-d", "--rm", "-p", "127.0.0.1::8080", image,
                   "-host=0.0.0.0", "-port=8080", "-upload-dir=/srv/tusd-data")
try:
    port = int(json.loads(docker("inspect", container))[0]["NetworkSettings"]["Ports"]["8080/tcp"][0]["HostPort"])
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
    print("PASS: hardened roots, unprivileged user, create/PATCH/resume/conflict/completion")
finally:
    subprocess.run(["docker", "rm", "-f", container], check=False, stdout=subprocess.DEVNULL)
