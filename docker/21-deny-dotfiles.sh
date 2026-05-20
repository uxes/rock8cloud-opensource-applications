#!/bin/sh
# Patches the ALREADY-RENDERED /etc/nginx/conf.d/default.conf (produced by
# the base nginx image's own 20-envsubst-on-templates.sh, which runs
# immediately before this - numbered 21 to run right after it) instead of
# shipping a full copy of default.conf.template. A full-template copy was
# tried first and broke nginx startup ("unknown \"server_header\"
# variable") - the actually-published image's template/env-var defaults
# don't match what's on the coreruleset/modsecurity-crs-docker GitHub
# "main" branch (same version-skew lesson as the silverbullet branch).
# Patching the rendered output only touches what we actually add, so it
# can't drift from whatever the real template happens to contain.
set -e

CONF=/etc/nginx/conf.d/default.conf

if [ -f "$CONF" ] && ! grep -q "deny-dotfiles" "$CONF"; then
    # Insert before every "location / {" line - regex locations take
    # nginx-matching precedence over the plain "/" prefix regardless of
    # position, so this works even though it's a textual insertion above it.
    sed -i '/location \/ {/i\
    # deny-dotfiles\
    location ~ /\\.(git|env|htaccess|htpasswd) {\
        deny all;\
        return 404;\
    }\
' "$CONF"
    echo "[21-deny-dotfiles] Inserted dotfile-deny location block into $CONF"
fi
