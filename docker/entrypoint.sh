#!/bin/sh
# Compose Mattermost env settings from linked Rock8Cloud service variables.
#
# Linked Postgres vars:  DB_HOST DB_PORT DB_DATABASE DB_USER DB_PASSWORD
# Linked S3 vars:        S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
#
# Rock8Cloud S3_ENDPOINT arrives bucket-prefixed with a ".https" artifact
# ("bucket.https/host") - normalize to the bare host like everywhere else.
set -e

: "${DB_PORT:=5432}"
export MM_SQLSETTINGS_DRIVERNAME=postgres
export MM_SQLSETTINGS_DATASOURCE="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_DATABASE}?sslmode=require&connect_timeout=10"

if [ -n "${S3_BUCKET}" ] && [ -n "${S3_ENDPOINT}" ]; then
    s3host=$(printf '%s' "$S3_ENDPOINT" | sed -e 's|^https\?://||' -e 's|\.https||')
    case "$s3host" in
        "${S3_BUCKET}."*) s3host=${s3host#"${S3_BUCKET}."} ;;
        "${S3_BUCKET}/"*) s3host=${s3host#"${S3_BUCKET}/"} ;;
    esac
    s3vhost="${S3_BUCKET}.${s3host}"

    # --- Local S3 proxy (nginx): User-Agent rewrite only --------------------
    # Rock8Cloud's Garage gateway 403s any signed S3 request whose User-Agent
    # contains "minio-go" (ROCK8_S3_UA_FILTER_REPORT.md) - Mattermost's Go
    # S3 client sends exactly that. Mattermost has no config knob to change
    # its own client's User-Agent, so a local proxy is the only lever
    # available; this one rewrites ONLY User-Agent and otherwise passes
    # requests through unmodified - see nginx-s3.conf.template for why it
    # must NOT touch Host: AWS SigV4 signs the Host header the client used,
    # and a proxy that changes Host after signing invalidates the signature
    # (confirmed empirically: rewriting Host to a virtual-hosted value
    # turned "bucket does not exist" into "Access Denied").
    RESOLVER=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
    mkdir -p /tmp/nginx/client /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi
    sed -e "s/__RESOLVER__/${RESOLVER}/" -e "s/__S3HOST__/${s3host}/g" \
        /etc/nginx/templates/s3.conf.template > /tmp/nginx-s3.conf
    nginx -c /tmp/nginx-s3.conf 2>&1 | head -3 || echo "[entrypoint] WARNING: nginx failed to start"
    sleep 1

    # Since the proxy can't touch Host, get minio-go to sign with the
    # CORRECT (already virtual-hosted) Host from the start instead: alias
    # the real bucket vhost to loopback, so the TCP connection routes to
    # our proxy while the HTTP Host header (and thus the SigV4 signature)
    # is built from the real vhost the whole time. Go's net/http Host
    # header comes from the configured endpoint URL, independent of which
    # IP it actually resolves to - this is what makes the alias work.
    if echo "127.0.0.1 ${s3vhost}" >> /etc/hosts 2>/tmp/hosts-write.err; then
        echo "[entrypoint] /etc/hosts alias added: ${s3vhost} -> 127.0.0.1"
    else
        echo "[entrypoint] WARNING: could not write /etc/hosts ($(cat /tmp/hosts-write.err 2>/dev/null)) - S3 vhost aliasing unavailable, uploads will likely fail"
    fi

    export MM_FILESETTINGS_DRIVERNAME=amazons3
    export MM_FILESETTINGS_AMAZONS3BUCKET="$S3_BUCKET"
    export MM_FILESETTINGS_AMAZONS3ACCESSKEYID="$S3_ACCESS_KEY"
    export MM_FILESETTINGS_AMAZONS3SECRETACCESSKEY="$S3_SECRET_KEY"
    export MM_FILESETTINGS_AMAZONS3REGION="${S3_REGION:-us-east-1}"
    # Endpoint is the REAL virtual-hosted bucket domain (aliased to the
    # local proxy above), not a bare local address - so minio-go signs
    # against the Host Garage actually expects. Explicit PathStyle=false
    # (Mattermost's real FileSettings.AmazonS3PathStyle, not a made-up
    # var) removes any ambiguity from minio-go's own custom-endpoint
    # heuristics about whether to also put the bucket in the path.
    export MM_FILESETTINGS_AMAZONS3ENDPOINT="${s3vhost}:9000"
    export MM_FILESETTINGS_AMAZONS3PATHSTYLE=false
    export MM_FILESETTINGS_AMAZONS3SSL=false
    echo "[entrypoint] S3 file storage: bucket=$S3_BUCKET endpoint=https://$s3host (via local proxy, vhost=${s3vhost})"
else
    echo "[entrypoint] WARNING: S3 vars not set - uploads go to ephemeral disk!"
fi

# Rock8Cloud requires the app to listen on 8080 (Mattermost defaults to 8065)
export MM_SERVICESETTINGS_LISTENADDRESS=":8080"
export MM_LOGSETTINGS_ENABLECONSOLE=true
export MM_LOGSETTINGS_CONSOLELEVEL=INFO
# Memory pressure guard: plugins (calls/AI/playbooks) are the largest RAM
# consumers and most need licenses anyway. Disable them wholesale.
export MM_PLUGINSETTINGS_ENABLE=false
export MM_SERVICESETTINGS_ENABLEDEVELOPER=false
export MM_SERVICESETTINGS_ENABLETESTING=false

# NOTE: this script IS the entrypoint (the base here is debian:bookworm-slim,
# not the official distroless/Alpine mattermost image - see Dockerfile for
# why: no /bin/sh in the official image, and it's musl-linked while the
# Mattermost binary needs glibc). Composes MM_* settings and execs the
# binary directly.
exec /mattermost/bin/mattermost server
