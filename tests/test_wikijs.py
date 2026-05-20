#!/usr/bin/env python3
"""Smoke test for the Wiki.js deployment. Usage: test_wikijs.py <BASE_URL>"""
import sys
import requests

base_url = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:3000"


def check(name, path, expected_statuses=(200,)):
    url = f"{base_url}{path}"
    r = requests.get(url, timeout=10, allow_redirects=True)
    ok = r.status_code in expected_statuses
    print(f"[{'OK' if ok else 'FAIL'}] {name}: {url} -> {r.status_code}")
    return ok


results = [
    # First boot may show the setup wizard (200) or, once configured, the
    # login page (200) - either way the server should respond, not error out.
    check("root page", "/"),
]

if not all(results):
    sys.exit(1)
print("All checks passed.")
