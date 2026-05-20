#!/usr/bin/env python3
"""S3 upload smoke test for MediaWiki + Extension:AWS.

Verifies that file uploads work through the S3 backend and specifically
that the old local-disk stash failure does NOT reappear:

    "Could not create directory \"mwstore://local-backend/local-temp/...\""

Steps:
  1. Login as Admin via the API (web-form login is broken behind the Rock8
     proxy - see README "Known Issues").
  2. Upload a small generated PNG via action=upload.
  3. Assert upload result is Success/Warning and the response contains no
     mwstore://local-backend/local-temp directory error.
  4. Query imageinfo for the uploaded file and fetch it back over HTTP.

Usage:
  python3 tests/test_s3_upload.py [BASE_URL]
  BASE_URL env var also works. Default: current live service URL.
"""

import json
import os
import struct
import sys
import urllib.request
import urllib.parse
import uuid
import zlib

BASE_URL = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
    "BASE_URL", "https://your-deployment.apps.rock8.cloud"
)
USERNAME = os.environ.get("MW_USER", "Admin")
PASSWORD = os.environ.get("MW_PASS", "MediaWikiAdmin2026!")

FAILURES = []


def check(name, ok, detail=""):
    print(("✅" if ok else "❌") + " " + name + (f": {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


def api_get(session, params):
    url = BASE_URL + "/api.php?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "S3-SmokeTest/1.0"})
    return json.loads(session.open(req, timeout=30).read().decode())


def api_post(session, params, files=None):
    # NOTE: boundary must be a str - interpolating a bytes object into an
    # f-string produces "--b'----...'" which makes the whole multipart body
    # invalid (PHP sees no POST fields and MediaWiki answers with its API
    # help page instead of JSON).
    boundary = "----smoketestboundary1234"
    parts = []
    for k, v in params.items():
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
        )
    if files:
        fname, content, ctype = files
        parts.append(
            (
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
                f"filename=\"{fname}\"\r\nContent-Type: {ctype}\r\n\r\n"
            ).encode() + content + b"\r\n"
        )
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(
        BASE_URL + "/api.php",
        data=b"".join(parts),
        headers={
            "User-Agent": "S3-SmokeTest/1.0",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    resp = session.open(req, timeout=120)
    raw = resp.read().decode()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise RuntimeError(
            f"API returned non-JSON (HTTP {resp.status}): {raw[:200]!r}"
        )


def make_png():
    """Minimal valid 1x1 red PNG."""
    def chunk(ctype, payload):
        c = ctype + payload
        return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    idat = zlib.compress(b"\x00\xff\x00\x00")
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )


def main():
    import http.cookiejar
    jar = http.cookiejar.CookieJar()
    session = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    # --- Step 1: login -----------------------------------------------------
    tok = api_get(session, {"action": "query", "meta": "tokens", "type": "login", "format": "json"})
    login_token = tok["query"]["tokens"]["logintoken"]
    r = api_post(session, {
        "action": "login", "lgname": USERNAME, "lgpassword": PASSWORD,
        "lgtoken": login_token, "format": "json",
    })
    check("API login", r.get("login", {}).get("result") == "Success",
          r.get("login", {}).get("result", str(r))[:120])
    if FAILURES:
        return 1

    # --- Step 2: upload ----------------------------------------------------
    csrf = api_get(session, {"action": "query", "meta": "tokens", "format": "json"})
    csrf_token = csrf["query"]["tokens"]["csrftoken"]

    filename = f"s3-smoke-{uuid.uuid4().hex[:8]}.png"
    # ignorewarnings is REQUIRED: without it MediaWiki returns result=Warning
    # (e.g. "duplicate" - same 1x1 PNG was uploaded before) plus a filekey and
    # does NOT publish the file until the client confirms. The imageinfo query
    # below would then report the file as missing.
    r = api_post(session, {
        "action": "upload", "filename": filename,
        "comment": "S3 backend smoke test", "token": csrf_token,
        "ignorewarnings": "1", "format": "json",
    }, files=(filename, make_png(), "image/png"))

    raw = json.dumps(r)
    upload = r.get("upload", {})
    result = upload.get("result")

    # The critical assertion: no local-stash mwstore failure.
    stash_error = ("Could not create directory" in raw
                   or "mwstore://local-backend/local-temp" in raw)
    check(f"Upload result ({result})", result in ("Success", "Warning"), raw[:200])
    check("No 'mwstore://local-backend/local-temp' stash error", not stash_error)

    # --- Step 3: fetch the file back ---------------------------------------
    ii = api_get(session, {
        "action": "query", "titles": f"File:{filename}",
        "prop": "imageinfo", "iiprop": "url|size", "format": "json",
    })
    pages = ii.get("query", {}).get("pages", {})
    info = next(iter(pages.values()), {}).get("imageinfo", [{}])[0]
    url = info.get("url")
    check("imageinfo URL present", bool(url), str(ii)[:200])

    if url:
        req = urllib.request.Request(url, headers={"User-Agent": "S3-SmokeTest/1.0"})
        try:
            resp = session.open(req, timeout=30)
            body = resp.read()
            ctype = resp.headers.get("Content-Type", "")
            check(f"File served from {url}", resp.status == 200 and body.startswith(b"\x89PNG"),
                  f"status={resp.status}, type={ctype}, bytes={len(body)}")
        except Exception as e:  # noqa: BLE001
            check("File fetch", False, str(e))

    print()
    if FAILURES:
        print(f"=== FAILED: {len(FAILURES)} check(s): {', '.join(FAILURES)} ===")
        return 1
    print("=== ALL CHECKS PASSED: uploads go through the S3 backend ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
