# Official Wiki.js image, pulled from Docker Hub.
FROM docker.io/requarks/wiki:2

# Base image runs as a non-root user by default, which can't install
# packages or chmod files under /usr/local/bin - stay root only for the
# build-time steps below (package install, chmod, symlink swap).
USER root
RUN apk add --no-cache stunnel

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Wiki.js reads config from /wiki/config.yml, interpolating $(VAR) tokens
# against env vars itself at load time (a Wiki.js feature, not shell
# templating). See docker/config.yml and docker/entrypoint.sh for why the DB
# host/port point at a local stunnel proxy instead of Postgres directly.
COPY docker/config.yml /wiki/config.yml

# Rock8Cloud's runtime filesystem is read-only outside /tmp (confirmed: mkdir
# under /wiki/data fails with EACCES even running as root here, while
# /tmp/stunnel-pg.conf writes fine) - move Wiki.js's writable data dir
# (cache, sessions, upload staging) onto /tmp via a symlink baked at build
# time, when the filesystem is still fully writable. Done here rather than
# in the entrypoint because an entrypoint-time rm/ln against /wiki would hit
# the exact same read-only restriction.
RUN rm -rf /wiki/data && ln -s /tmp/wiki-data /wiki/data

# Back to the base image's own non-root user for runtime. Nothing in
# entrypoint.sh needs root: stunnel only binds a high port (127.0.0.1:15432,
# no privilege required) and connects outbound, and /tmp is world-writable
# (sticky bit) for both the stunnel config and the /tmp/wiki-data symlink
# target - confirmed via requarks/wiki's own Dockerfile source, not guessed.
USER node

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["node", "server"]
