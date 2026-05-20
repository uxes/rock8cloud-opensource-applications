# Two-stage build:
#   "build" - fetches PG4WP + S3-Uploads and installs S3-Uploads' Composer deps
#   (final) - the actual WordPress image: PHP pgsql extension, WP core,
#             patched PG4WP (Postgres driver) + S3-Uploads plugin baked in.
#
# Build-time patch logic lives in docker/build/ (one file per concern) rather
# than inline here - see those files for why each patch exists.

FROM debian:bookworm-slim AS build

ARG PG4WP_VERSION=3.4.1
ARG S3_UPLOADS_VERSION=3.0.3
ARG ELEMENTOR_VERSION=4.2.3
ARG HELLO_ELEMENTOR_VERSION=3.4.9

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget unzip composer \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN wget -O pg4wp.zip "https://github.com/PostgreSQL-For-Wordpress/postgresql-for-wordpress/archive/refs/tags/v${PG4WP_VERSION}.zip" \
    && wget -O s3-uploads.zip "https://github.com/humanmade/S3-Uploads/archive/refs/tags/${S3_UPLOADS_VERSION}.zip" \
    && unzip pg4wp.zip \
    && unzip s3-uploads.zip

WORKDIR /tmp/S3-Uploads-${S3_UPLOADS_VERSION}
RUN composer config allow-plugins.composer/installers true \
    && composer install --no-dev --optimize-autoloader --ignore-platform-reqs

# MCP Adapter (github.com/WordPress/mcp-adapter) is a fast-moving, official
# WP project without stable version tags yet, so unlike PG4WP/S3-Uploads we
# intentionally track "latest" here rather than pinning - revisit once it
# has a stable release cadence. The release zip's internal layout isn't
# guaranteed (may or may not have a wrapping folder), so normalise it into
# a predictable /tmp/mcp-adapter path regardless.
WORKDIR /tmp
RUN wget -O mcp-adapter.zip "https://github.com/WordPress/mcp-adapter/releases/latest/download/mcp-adapter.zip" \
    && unzip -q mcp-adapter.zip -d mcp-adapter-raw \
       && if [ -f mcp-adapter-raw/mcp-adapter.php ]; then mv mcp-adapter-raw mcp-adapter; \
       else mv "$(find mcp-adapter-raw -mindepth 1 -maxdepth 1 -type d | head -1)" mcp-adapter; fi

# Elementor (page builder) + Hello Elementor theme, pinned via ARGs above.
# Even though both zips come from WP.org (whose layout is normally stable),
# apply the same defensive normalisation as mcp-adapter above: don't trust
# the zip's internal structure blindly. Fails loudly if no directory is found.
WORKDIR /tmp
RUN wget -O elementor.zip "https://downloads.wordpress.org/plugin/elementor.${ELEMENTOR_VERSION}.zip" \
    && wget -O hello-elementor.zip "https://downloads.wordpress.org/theme/hello-elementor.${HELLO_ELEMENTOR_VERSION}.zip" \
    && for slug in elementor hello-elementor; do \
         unzip -q ${slug}.zip -d ${slug}-raw; \
         if [ -d "${slug}-raw/${slug}" ]; then mv "${slug}-raw/${slug}" "/tmp/${slug}"; \
         else mv "$(find ${slug}-raw -mindepth 1 -maxdepth 1 -type d | head -1)" "/tmp/${slug}"; fi; \
       done


FROM wordpress:php8.5-apache

# ARGs don't survive across FROM boundaries, so re-declare for this stage.
ARG PG4WP_VERSION=3.4.1
ARG S3_UPLOADS_VERSION=3.0.3
ARG ELEMENTOR_VERSION=4.2.3
ARG HELLO_ELEMENTOR_VERSION=3.4.9

# --- PHP Postgres extension -------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev \
    && docker-php-ext-configure pgsql --with-pgsql=/usr/local/pgsql \
    && docker-php-ext-install pgsql pdo_pgsql \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --- Static config, mu-plugins, build-time patch scripts --------------------
COPY docker/disable-sendmail.ini /usr/local/etc/php/conf.d/disable-sendmail.ini
COPY docker/php-memory.ini /usr/local/etc/php/conf.d/zz-memory.ini
COPY docker/php-uploads.ini /usr/local/etc/php/conf.d/zz-uploads.ini
COPY docker/apache-servername.conf /etc/apache2/conf-available/servername.conf
COPY docker/wp-config-extra.php /usr/local/etc/wp-config-extra.php
COPY docker/htaccess /var/www/html/.htaccess
COPY docker/health.php /var/www/html/health.php
COPY docker/mu-plugins/ /var/www/html/wp-content/mu-plugins/
COPY docker/build/ /usr/local/src/build/

# --- WordPress core + env-driven wp-config.php ------------------------------
RUN a2enconf servername \
    && a2enmod rewrite \
    && printf '<Directory /var/www/html>\n    AllowOverride All\n    Require all granted\n</Directory>\n' > /etc/apache2/conf-available/wordpress-htaccess.conf \
    && a2enconf wordpress-htaccess \
    && cp -r /usr/src/wordpress/* /var/www/html/ \
    && sh /usr/local/src/build/prepare-wp-config.sh

# --- PG4WP (Postgres driver) + S3-Uploads plugin, patched -------------------
COPY --from=build /tmp/postgresql-for-wordpress-${PG4WP_VERSION}/pg4wp /var/www/html/wp-content/pg4wp
COPY --from=build /tmp/postgresql-for-wordpress-${PG4WP_VERSION}/pg4wp/db.php /var/www/html/wp-content/db.php
COPY --from=build /tmp/S3-Uploads-${S3_UPLOADS_VERSION} /var/www/html/wp-content/plugins/s3-uploads
COPY --from=build /tmp/mcp-adapter /var/www/html/wp-content/plugins/mcp-adapter
COPY --from=build /tmp/elementor /var/www/html/wp-content/plugins/elementor
COPY --from=build /tmp/hello-elementor /var/www/html/wp-content/themes/hello-elementor

# No chown here: DISALLOW_FILE_MODS/DISALLOW_FILE_EDIT (wp-config-extra.php)
# block wp-admin from ever writing to this tree, and uploads go straight to
# S3 (S3-Uploads plugin) rather than local disk - www-data only ever needs
# to *read* these files to serve PHP, which root-owned COPY'd/unzipped files
# already allow. A recursive chown over the full WP core + plugin tree here
# was previously the single most expensive step in the build (minutes on
# slower storage) for zero runtime benefit.
RUN sh /usr/local/src/build/patch-pg4wp.sh \
    && sh /usr/local/src/build/patch-s3-uploads.sh \
    && rm -rf /usr/local/src/build

# --- Apache listens on 8080, matching Rock8Cloud's expected service port --------
RUN sed -i 's/Listen 80/Listen 8080/g' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost \*:8080>/g' /etc/apache2/sites-available/*.conf

EXPOSE 8080

ENTRYPOINT []
CMD ["apache2-foreground"]
