#!/bin/sh
# Rock8Cloud has no PVCs, so /space (SilverBullet's notes+attachments folder)
# can't just be a mounted volume - it would be wiped on every redeploy and
# every pod replacement. Instead, sync it with a git remote:
#   - on boot, this script clones (or pulls) the space from git
#   - SilverBullet's own git plug (enabled once, from the web UI, via
#     PLUGS + SETTINGS - see PROGRESS.md) auto-commits and pushes changes
#     back on a timer while running
#
# Deliberately generic: this script and this repo never name or reference
# any specific git remote. Configure via env vars on the Rock8Cloud service:
#   NOTES_GIT_REPO   - remote host+path, no scheme/credentials
#                      e.g. "git-host.example/owner/repo.git"
#   NOTES_GIT_TOKEN  - a token with write access to that repo, used as an
#                      OAuth2 bearer credential for the clone/pull/push URL
#   NOTES_GIT_BRANCH - defaults to "main" if unset
set -e

SPACE="${SB_FOLDER:-/space}"
BRANCH="${NOTES_GIT_BRANCH:-main}"
mkdir -p "$SPACE"

if [ -n "${NOTES_GIT_REPO:-}" ] && [ -n "${NOTES_GIT_TOKEN:-}" ]; then
    # Accept whatever shape got pasted into the env var - strip a leading
    # scheme (https://, ssh://), strip a leading "user@", and turn a
    # "host:owner/repo" SSH-shorthand colon into "host/owner/repo" - so we
    # always end up with a bare "host/owner/repo.git" for the URL below.
    REPO_HOSTPATH=$(echo "$NOTES_GIT_REPO" \
        | sed -E 's#^[a-zA-Z]+://##; s#^[^/@]+@##; s#^([^/:]+):#\1/#')
    REMOTE_URL="https://oauth2:${NOTES_GIT_TOKEN}@${REPO_HOSTPATH}"

    if [ -d "$SPACE/.git" ]; then
        echo "[entrypoint] Existing space git repo found, pulling latest..."
        git -C "$SPACE" remote set-url origin "$REMOTE_URL"
        git -C "$SPACE" pull --rebase origin "$BRANCH" \
            || echo "[entrypoint] WARNING: git pull failed - continuing with the space as it currently is on disk"
    elif [ -z "$(ls -A "$SPACE" 2>/dev/null)" ]; then
        echo "[entrypoint] Empty space - cloning from the configured git remote..."
        if ! git clone --branch "$BRANCH" "$REMOTE_URL" "$SPACE" 2>&1; then
            echo "[entrypoint] Clone failed (likely an empty/new remote repo) - initializing a fresh space repo instead"
            git -C "$SPACE" init -q -b "$BRANCH"
            git -C "$SPACE" remote add origin "$REMOTE_URL"
        fi
    else
        echo "[entrypoint] WARNING: /space has content but no .git dir - leaving it alone, not overwriting anything"
    fi

    git -C "$SPACE" config user.email "silverbullet-sync@localhost"
    git -C "$SPACE" config user.name "SilverBullet Auto-sync"
    echo "[entrypoint] Notes will sync to the configured git remote (enable the Git plug + autoSync in SilverBullet's SETTINGS to actually push - see PROGRESS.md)."
else
    echo "[entrypoint] WARNING: NOTES_GIT_REPO/NOTES_GIT_TOKEN not set - /space is NOT persisted. Notes will be LOST on the next redeploy or pod replacement."
fi

# Everything above ran as root (simplest for the git-sync step - avoids
# fighting file ownership while cloning/pulling). The base image has no
# privilege-drop of its own (confirmed via runtime `ls -la /`: it's just a
# root-owned static binary at /silverbullet, no wrapper script) - so drop
# to the unprivileged "silverbullet" user ourselves before running it, via
# su-exec, so a compromised app process isn't root inside the pod.
chown -R silverbullet:silverbullet "$SPACE"

if [ -x /silverbullet ]; then
    if [ "$#" -eq 0 ]; then
        set -- "$SPACE"
    fi
    if [ -x /sbin/tini ]; then
        echo "[entrypoint] Handing off to /silverbullet as non-root, via tini: $*"
        exec su-exec silverbullet /sbin/tini -- /silverbullet "$@"
    else
        echo "[entrypoint] Handing off to /silverbullet as non-root (no tini found): $*"
        exec su-exec silverbullet /silverbullet "$@"
    fi
fi

# Fall back to searching for a wrapper entrypoint script, for other image
# variants/tags that might ship one after all.
BASE_ENTRYPOINT=""
for candidate in /docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh /entrypoint.sh; do
    if [ -f "$candidate" ]; then
        BASE_ENTRYPOINT="$candidate"
        break
    fi
done
if [ -z "$BASE_ENTRYPOINT" ]; then
    BASE_ENTRYPOINT=$(find / -xdev -maxdepth 3 -iname '*entrypoint*' -type f 2>/dev/null | head -1)
fi

if [ -n "$BASE_ENTRYPOINT" ]; then
    echo "[entrypoint] Handing off to base image entrypoint as non-root: $BASE_ENTRYPOINT (shebang: $(head -1 "$BASE_ENTRYPOINT" 2>/dev/null))"
    exec su-exec silverbullet /sbin/tini -- "$BASE_ENTRYPOINT" "$@"
else
    echo "[entrypoint] FATAL: could not locate the base image's own entrypoint or binary anywhere - listing / for debugging:"
    ls -la /
    exit 1
fi
