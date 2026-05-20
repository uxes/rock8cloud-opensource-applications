#!/usr/bin/env bash
# Load test for MediaWiki deployment using ApacheBench (ab).
#
# Usage:
#   ./tests/load_test.sh [BASE_URL]
#
# Environment overrides:
#   REQUESTS   total requests per scenario   (default 200)
#   CONCURRENCY  parallel clients            (default 10)
#   TIMEOUT    seconds per request          (default 15)
#
# Requires: ab (/usr/sbin/ab)

set -u

BASE_URL="${1:-${BASE_URL:-https://your-deployment.apps.rock8.cloud}}"
BASE_URL="${BASE_URL%/}"
REQUESTS="${REQUESTS:-200}"
CONCURRENCY="${CONCURRENCY:-10}"
TIMEOUT="${TIMEOUT:-15}"

if ! command -v ab >/dev/null 2>&1; then
    echo "Error: 'ab' not found (install apache2-utils / httpd-tools)" >&2
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

run_scenario() {
    local name="$1"; shift
    local url="$1"
    echo ""
    echo "--- $name: $url ---"
    # -H UA so proxy/MW logs identify the test
    # NOTE: no -k (keepalive hangs behind the envoy proxy), no -t
    ab -n "$REQUESTS" -c "$CONCURRENCY" -s "$TIMEOUT" \
       -H "User-Agent: mw-loadtest/1.0" \
       "$url" > "$TMPDIR/out.txt" 2>&1
    if [ $? -ne 0 ] || ! grep -q "Concurrency Level" "$TMPDIR/out.txt"; then
        echo "FAILED:" >&2
        cat "$TMPDIR/out.txt" >&2
        return 1
    fi
    grep -E "Failed requests|Requests per second|Time per request|50%|95%|99%" "$TMPDIR/out.txt" |
        sed 's/^[[:space:]]*//'
}

echo "=== MediaWiki load test ==="
echo "Target:      $BASE_URL"
echo "Requests:    $REQUESTS per scenario"
echo "Concurrency: $CONCURRENCY"

FAIL=0

run_scenario "Main page"     "$BASE_URL/Main_Page" || FAIL=$((FAIL+1))
run_scenario "CSS load.php"  "$BASE_URL/load.php?lang=en&modules=skins.vector.styles&skin=vector-2022" || FAIL=$((FAIL+1))
run_scenario "Favicon"       "$BASE_URL/favicon.ico" || FAIL=$((FAIL+1))
run_scenario "API query"     "$BASE_URL/api.php?action=query&meta=siteinfo&format=json" || FAIL=$((FAIL+1))

echo ""
echo "=== Done ($FAIL scenario failures) ==="
exit "$FAIL"
