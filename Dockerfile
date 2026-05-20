# Gatus uptime monitor on Rock8Cloud
# Official image already listens on 8080 - matches the platform requirement.
# Config is baked in at build time; DB credentials arrive via linked env vars.
FROM docker.io/twinproduction/gatus:latest

COPY docker/config.yaml /config/config.yaml

EXPOSE 8080
