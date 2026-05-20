# Official Vaultwarden image runs as root by default with no built-in
# non-root option, and listens on privileged port 80 - both fixed here.
# See PROGRESS.md for the full reasoning.
FROM docker.io/vaultwarden/server:latest

# Debian-based (debian:trixie-slim, confirmed from upstream's own
# Dockerfile.debian source), not Alpine - useradd, not adduser -D.
RUN useradd -u 1000 -M vaultwarden && chown -R vaultwarden:vaultwarden /data

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Rocket (Vaultwarden's web framework) defaults to port 80, which needs
# root to bind - move it to an unprivileged port so USER below is real,
# not cosmetic. Matched in the Rock8Cloud service's own Port setting.
ENV ROCKET_PORT=8080

USER vaultwarden

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
