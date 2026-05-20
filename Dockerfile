# Mattermost Team Edition on Rock8Cloud.
#
# Two reasons for this multi-stage setup:
# 1. The official mattermost-team-edition image is DISTROLESS (no /bin/sh),
#    so a wrapper entrypoint script cannot run there.
# 2. The Mattermost binary is linked against GLIBC - an Alpine (musl) base
#    fails with "not found". Debian bookworm-slim has both a shell AND glibc.
#
# S3: Mattermost has no PathStyle setting and minio-go defaults to
# PATH-STYLE for custom endpoints, but Rock8Cloud's Garage gateway serves
# VIRTUAL-HOSTED style only (path-style = bare 404). A local nginx
# translates path-style -> virtual-hosted; see docker/nginx-s3.conf.template.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata curl nginx \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 2000 mattermost \
    && useradd -u 2000 -g mattermost -M -d /mattermost -s /usr/sbin/nologin mattermost \
    && mkdir -p /mattermost/data /mattermost/plugins /mattermost/client/plugins /mattermost/logs /mattermost/config \
    && chown -R mattermost:mattermost /mattermost

COPY --from=docker.io/mattermost/mattermost-team-edition:latest --chown=2000:2000 /mattermost /mattermost

COPY docker/entrypoint.sh /opt/rock8-entrypoint.sh
COPY docker/nginx-s3.conf.template /etc/nginx/templates/s3.conf.template
RUN chmod +x /opt/rock8-entrypoint.sh

WORKDIR /mattermost
USER mattermost
EXPOSE 8080
ENTRYPOINT ["/opt/rock8-entrypoint.sh"]
