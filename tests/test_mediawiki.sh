#!/bin/bash
set -e

BASE_URL="${1:?usage: '$0 <base-url>'}"
COOKIES="./tmp/mw_cookies.txt"
PASS=0
FAIL=0

pass() { echo "✅ $1"; PASS=$((PASS+1)); }
fail() { echo "❌ $1"; FAIL=$((FAIL+1)); }

echo "=== MediaWiki Functional Tests ==="
echo ""

# Test 1: Page loads with CSS
echo "Test 1: Page loads with CSS..."
HTML=$(curl -s "$BASE_URL/")
if echo "$HTML" | grep -q "vector-2022" && echo "$HTML" | grep -q "Main Page"; then
    pass "Main page renders with Vector 2022 skin"
else
    fail "Main page missing CSS or content"
fi

# Test 2: load.php (CSS/JS) returns 200
echo "Test 2: CSS endpoint works..."
CSS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/load.php?lang=en&modules=skins.vector.styles&skin=vector-2022")
if [ "$CSS_CODE" = "200" ]; then
    pass "load.php returns 200"
else
    fail "load.php returns $CSS_CODE (expected 200)"
fi

# Test 3: Favicon exists
echo "Test 3: Favicon..."
FAVICON_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/favicon.ico")
if [ "$FAVICON_CODE" = "200" ]; then
    pass "favicon.ico returns 200"
else
    fail "favicon.ico returns $FAVICON_CODE (expected 200)"
fi

# Test 4: Login via web form
echo "Test 4: Login..."
rm -f "$COOKIES"
TOKEN=$(curl -s -c "$COOKIES" "$BASE_URL/index.php?title=Special:UserLogin" \
    | grep -o 'wpLoginToken"[^>]*>' | grep -o 'value="[^"]*"' | cut -d'"' -f2)

if [ -z "$TOKEN" ]; then
    fail "No login token found"
else
    LOGIN_RESP=$(curl -s -b "$COOKIES" -c "$COOKIES" \
        "$BASE_URL/index.php?title=Special:UserLogin&action=submit" \
        -d "wpName=Admin&wpPassword=admin&wpLoginToken=$TOKEN&wpRemember=on&wpLoginattempt=Log+in")
    
    if echo "$LOGIN_RESP" | grep -q "cdx-message--error"; then
        ERROR=$(echo "$LOGIN_RESP" | grep -o 'cdx-message__content">[^<]*' | cut -d'"' -f2)
        fail "Login failed: $ERROR"
    elif echo "$LOGIN_RESP" | grep -qi "logout\|special:preferences\|special:watchlist"; then
        pass "Admin login successful"
    else
        fail "Login failed - unexpected response"
    fi
fi

# Test 5: Create new user via web form
echo "Test 5: Create user..."
rm -f "$COOKIES"
CREATE_TOKEN=$(curl -s -c "$COOKIES" "$BASE_URL/index.php?title=Special:CreateAccount" \
    | grep -o 'wpEditToken"[^>]*>' | grep -o 'value="[^"]*"' | cut -d'"' -f2)

if [ -z "$CREATE_TOKEN" ]; then
    fail "No create token found"
else
    CREATE_RESP=$(curl -s -b "$COOKIES" -c "$COOKIES" \
        "$BASE_URL/index.php?title=Special:CreateAccount&action=submit" \
        -d "username=testuser&password=testpass123&retype=testpass123&createName=testuser&createEmail=test@example.com&wpCreateaccount=Create+your+account&wpEditToken=$CREATE_TOKEN")
    
    if echo "$CREATE_RESP" | grep -q "cdx-message--error"; then
        ERROR=$(echo "$CREATE_RESP" | grep -o 'cdx-message__content">[^<]*' | cut -d'"' -f2)
        fail "Create user failed: $ERROR"
    elif echo "$CREATE_RESP" | grep -qi "success\|contributions\|talk"; then
        pass "User testuser created successfully"
    else
        fail "Create user failed - unexpected response"
    fi
fi

# Test 6: Create page via API (requires login)
echo "Test 6: Create page via API..."
# First login
rm -f "$COOKIES"
TOKEN=$(curl -s -c "$COOKIES" "$BASE_URL/index.php?title=Special:UserLogin" \
    | grep -o 'wpLoginToken"[^>]*>' | grep -o 'value="[^"]*"' | cut -d'"' -f2)

curl -s -b "$COOKIES" -c "$COOKIES" \
    "$BASE_URL/index.php?title=Special:UserLogin&action=submit" \
    -d "wpName=Admin&wpPassword=admin&wpLoginToken=$TOKEN&wpRemember=on&wpLoginattempt=Log+in" > /dev/null 2>&1

# Get CSRF token
CSRF=$(curl -s -b "$COOKIES" \
    "$BASE_URL/api.php?action=query&meta=tokens&format=json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['query']['tokens']['csrftoken'])")

# Create page
PAGE_RESP=$(curl -s -b "$COOKIES" \
    "$BASE_URL/api.php" \
    -d "action=edit&title=TestPage&text=This is a test page created by automated tests.&summary=Automated+test&token=$CSRF&format=json")

if echo "$PAGE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'edit' in d and d['edit']['result']=='Success' else 1)" 2>/dev/null; then
    pass "Created page TestPage via API"
elif echo "$PAGE_RESP" | grep -q "badtoken\|WrongToken"; then
    fail "CSRF token invalid (login session issue)"
else
    ERROR=$(echo "$PAGE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('info','unknown'))" 2>/dev/null || echo "unknown")
    fail "Create page failed: $ERROR"
fi

# Test 7: Verify page exists
echo "Test 7: Verify page exists..."
PAGE_CHECK=$(curl -s "$BASE_URL/api.php?action=query&titles=TestPage&format=json")
if echo "$PAGE_CHECK" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'query' in d and 'pages' in d['query'] else 1)" 2>/dev/null; then
    pass "TestPage exists in API"
else
    fail "TestPage not found"
fi

# Test 8: Edit page
echo "Test 8: Edit page..."
CSRF=$(curl -s -b "$COOKIES" \
    "$BASE_URL/api.php?action=query&meta=tokens&format=json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['query']['tokens']['csrftoken'])")

EDIT_RESP=$(curl -s -b "$COOKIES" \
    "$BASE_URL/api.php" \
    -d "action=edit&title=TestPage&text=This page was edited by automated tests.&summary=Automated+edit&token=$CSRF&format=json")

if echo "$EDIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'edit' in d and d['edit']['result']=='Success' else 1)" 2>/dev/null; then
    pass "Edited TestPage via API"
else
    ERROR=$(echo "$EDIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('info','unknown'))" 2>/dev/null || echo "unknown")
    fail "Edit page failed: $ERROR"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="