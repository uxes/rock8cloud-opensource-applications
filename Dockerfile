# MediaWiki on PHP 8.5 + Apache + PostgreSQL
# Build: 2026-08-21-fix13
#
# Downloads MediaWiki core during build, configures PHP extensions,
# sets up Apache with URL rewriting for clean URLs.

FROM debian:bookworm-slim

ARG MEDIAWIKI_VERSION=1.43.2
ARG CACHE_BUST=20260821-17

# Install dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        apache2 \
        libapache2-mod-php8.2 \
        php8.2 \
        php8.2-pgsql \
        php8.2-curl \
        php8.2-gd \
        php8.2-intl \
        php8.2-mbstring \
        php8.2-xml \
        php8.2-zip \
        php8.2-readline \
        php8.2-bcmath \
        php8.2-imap \
        postgresql-client \
        wget \
        unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Download and extract MediaWiki
WORKDIR /tmp
RUN wget -O mediawiki.tar.gz "https://releases.wikimedia.org/mediawiki/${MEDIAWIKI_VERSION%.*}/mediawiki-${MEDIAWIKI_VERSION}.tar.gz" \
    && mkdir -p /var/www/html \
    && tar xzf mediawiki.tar.gz --strip-components=1 -C /var/www/html \
    && rm mediawiki.tar.gz

# Download Vector skin (no longer bundled with MediaWiki 1.43+)
# NOTE: the directory MUST be named exactly "Vector" (capital V).
# wfLoadSkin('Vector') resolves $wgStyleDirectory/Vector/skin.json and Linux
# is case-sensitive - a lowercase skins/vector/ directory is silently not found.
RUN apt-get update && apt-get install -y --no-install-recommends git && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/www/html/skins/vector /var/www/html/skins/Vector \
    && cd /tmp \
    && git clone --branch REL1_43 --depth 1 https://github.com/wikimedia/mediawiki-skins-Vector.git Vector \
    && mkdir -p /var/www/html/skins/Vector \
    && mv Vector/* /var/www/html/skins/Vector/ \
    && rm -rf Vector

# Install Extension:AWS (S3 file backend) - the official, maintained
# extension for this (github.com/edwardspec/mediawiki-aws-s3), not a
# hand-rolled hook. MediaWiki has no S3 support in core; a custom
# FileSaveComplete-style hook only fires AFTER the upload stash step, but
# that stash step itself writes to local disk first (mwstore://local-backend/
# local-temp/...) - with no PVC here, that first local write is exactly what
# was failing, before any custom hook could ever intervene. Extension:AWS
# replaces the backend itself, so the stash phase goes to S3 too.
RUN apt-get update && apt-get install -y --no-install-recommends curl git \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && git clone --branch master --depth 1 https://github.com/edwardspec/mediawiki-aws-s3.git /var/www/html/extensions/AWS \
    && cd /var/www/html/extensions/AWS \
    && composer install --no-dev --optimize-autoloader \
    && apt-get remove -y curl git \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Enable Apache modules
RUN a2enmod rewrite \
    && a2enmod env \
    && a2enmod expires \
    && a2enmod headers \
    && a2enmod php8.2

# --- Apache logging to stderr (visible in container logs) ---------------------
RUN sed -i 's|ErrorLog.*|ErrorLog /proc/self/fd/2|' /etc/apache2/apache2.conf \
    && sed -i 's|CustomLog.*|CustomLog /proc/self/fd/2 combined|' /etc/apache2/apache2.conf

# --- Apache config ----------------------------------------------------------
RUN printf '<Directory /var/www/html>\n    AllowOverride All\n    Require all granted\n</Directory>\n' > /etc/apache2/conf-available/mediawiki-htaccess.conf \
    && a2enconf mediawiki-htaccess

# Listen on 8080 for Rock8Cloud
RUN sed -i 's/Listen 80/Listen 8080/g' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost \*:8080>/g' /etc/apache2/sites-available/*.conf

# --- PHP config -------------------------------------------------------------
RUN printf 'memory_limit = 256M\nupload_max_filesize = 100M\npost_max_size = 100M\nmax_execution_time = 300\n' \
    > /etc/php/8.2/apache2/conf.d/zz-uploads.ini

# --- Cache bust --------------------------------------------------------------
# MUST run BEFORE the COPY steps below. Docker only invalidates its build cache
# from the first instruction that USES an ARG - an ARG declared at the top but
# referenced in the last RUN does nothing for COPY layers, which is exactly how
# a stale LocalSettings.php survived a CACHE_BUST bump and got baked into the
# deployed image.
RUN echo "Build cache bust: ${CACHE_BUST}"

# --- .htaccess for clean URLs -----------------------------------------------
COPY docker/mediawiki.htaccess /var/www/html/.htaccess

# --- LocalSettings.php: baked into the image --------------------------------
# Single source of truth for runtime config (env-driven DB creds, secrets,
# wfLoadSkin('Vector') + vector-2022 default). The entrypoint must never
# regenerate it.
COPY docker/LocalSettings.php /var/www/html/LocalSettings.php

# --- Static assets ----------------------------------------------------------
COPY docker/favicon.ico /var/www/html/favicon.ico
COPY docker/health.php /var/www/html/health.php

# --- Silence Apache ServerName warning --------------------------------------
COPY docker/apache-servername.conf /etc/apache2/conf-available/servername.conf
RUN a2enconf servername

# No blanket chown/chmod 777 over the whole tree: it made the entire MediaWiki
# core + extensions world-writable for no runtime benefit, and was the most
# expensive single step in the build (minutes, on top of the security
# exposure). The entrypoint runs update.php/createAndPromote.php as root
# BEFORE Apache starts, so schema setup and any l10n cache priming already
# happen with root's write access - Apache's www-data workers (which serve
# requests afterward) only ever need read access to the tree.
# The only actually-needed write targets: MW's local l10n/message cache dir
# (regenerated by update.php as root, but www-data may still touch it under
# some request paths) and images/ (present for completeness even though
# Extension:AWS below replaces the upload backend with S3 - cheap to keep,
# not worth the risk of removing without deeper verification).
RUN mkdir -p /var/www/html/images /var/www/html/cache /tmp/uploads \
    && chown -R www-data:www-data /var/www/html/images /var/www/html/cache /tmp/uploads \
    && chmod 644 /var/www/html/LocalSettings.php

# --- Entrypoint: runs schema updater before Apache starts -------------------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []