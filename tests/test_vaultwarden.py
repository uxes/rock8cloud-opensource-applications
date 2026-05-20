#!/usr/bin/env python3
"""Smoke test for the Vaultwarden deployment. Usage: test_vaultwarden.py <BASE_URL>"""
import sys
import requests

base_url = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:8080"


def check(name, path, expected_status=200):
    url = f"{base_url}{path}"
    r = requests.get(url, timeout=10)
    ok = r.status_code == expected_status
    print(f"[{'OK' if ok else 'FAIL'}] {name}: {url} -> {r.status_code}")
    return ok


results = [
    check("alive endpoint", "/alive"),
    check("web vault login page", "/"),
    check("api config endpoint", "/api/config"),
]

if not all(results):
    sys.exit(1)
print("All checks passed.")
