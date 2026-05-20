# SilverBullet on Rock8Cloud.
#
# SilverBullet stores everything as plain markdown + attachment files under
# /space, which normally needs a persistent volume (the official image
# expects `-v ./space:/space`). Rock8Cloud has no PVCs, so instead of local
# storage this bakes in a git-based sync: docker/entrypoint.sh clones the
# space from a git remote on boot and lets SilverBullet's own git plug
# push changes back on a timer - see PROGRESS.md for the full reasoning
# and docker/entrypoint.sh for exactly which env vars drive it. This
# Dockerfile intentionally never names or references any specific git
# remote/repo - that's runtime configuration (Rock8Cloud env vars) only.
FROM docker.io/zefhemel/silverbullet:latest

# Unlike some Alpine images of this app, the published :latest tag has no
# built-in privilege-drop (it's just a root-owned static binary at
# /silverbullet, see PROGRESS.md) - so this Dockerfile creates its own
# unprivileged user and entrypoint.sh drops into it (via su-exec) right
# before running the app, after the git-sync step that still needs root.
USER root
RUN apk add --no-cache git su-exec \
    && adduser -D -u 1000 -h /home/silverbullet silverbullet

COPY docker/entrypoint.sh /usr/local/bin/notes-sync-entrypoint.sh
RUN chmod +x /usr/local/bin/notes-sync-entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/notes-sync-entrypoint.sh"]
