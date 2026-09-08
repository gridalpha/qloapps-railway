FROM php:8.3-apache

# QloApps 1.7.0 requires PHP >= 8.1 and < 8.5 (classes/ConfigurationTest.php).
ARG QLOAPPS_VERSION=1.7.0

ENV QLOAPPS_VERSION=${QLOAPPS_VERSION} \
    APP_DIR=/var/www/qloapps \
    SEED_DIR=/opt/qloapps-seed \
    DATA_DIR=/data

# PHP extensions QloApps' own requirement checker asks for:
# gd, intl, zip, soap, bcmath, pdo_mysql, mysqli, openssl (built in), mbstring (built in),
# simplexml (built in), zlib (built in), curl (built in).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
        libicu-dev libxml2-dev libzip-dev zlib1g-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" gd intl zip soap bcmath pdo_mysql mysqli exif opcache; \
    rm -rf /var/lib/apt/lists/*; \
    php -r 'foreach (["gd","intl","zip","soap","bcmath","pdo_mysql","mysqli","mbstring","curl","simplexml","openssl","Zend OPcache"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "missing extension: $e\n"); exit(1); } }'

RUN set -eux; \
    a2enmod rewrite headers remoteip expires; \
    a2dismod -f mpm_event mpm_worker || true; \
    a2enmod mpm_prefork; \
    a2dissite 000-default

# The published QloApps release tarball is the whole application; nothing is vendored
# by composer at build time (its libraries live in tools/).
RUN set -eux; \
    mkdir -p "$APP_DIR"; \
    curl -fsSL "https://github.com/Qloapps/QloApps/archive/refs/tags/v${QLOAPPS_VERSION}.tar.gz" -o /tmp/qloapps.tar.gz; \
    tar -xzf /tmp/qloapps.tar.gz -C "$APP_DIR" --strip-components=1; \
    rm -f /tmp/qloapps.tar.gz; \
    test -f "$APP_DIR/install/index_cli.php"; \
    test -d "$APP_DIR/themes/hotel-reservation-theme"

# Directories QloApps writes to are moved aside as a pristine seed and replaced with
# symlinks onto the Railway volume. A volume mounted straight over img/ or modules/
# would hide the content the image ships (learnings: "a mounted volume hides files
# baked into that path").
RUN set -eux; \
    mkdir -p "$SEED_DIR"; \
    for d in img modules themes translations mails download upload; do \
        mv "$APP_DIR/$d" "$SEED_DIR/$d"; \
        ln -s "$DATA_DIR/$d" "$APP_DIR/$d"; \
    done; \
    rm -rf "$APP_DIR/log"; ln -s "$DATA_DIR/log" "$APP_DIR/log"; \
    ln -s "$DATA_DIR/config/settings.inc.php" "$APP_DIR/config/settings.inc.php"; \
    ln -s "$DATA_DIR/.htaccess" "$APP_DIR/.htaccess"; \
    printf '%s\n' "$QLOAPPS_VERSION" > "$SEED_DIR/.seed-version"

COPY rootfs/health/ /var/www/health/
COPY rootfs/apache/qloapps.conf.tpl /opt/qloapps/apache/qloapps.conf.tpl
COPY rootfs/php/qloapps.ini.tpl /opt/qloapps/php/qloapps.ini.tpl
COPY rootfs/php/https-location.php /opt/qloapps/php/https-location.php
COPY rootfs/bin/bootstrap.php /opt/qloapps/bin/bootstrap.php
COPY rootfs/bin/entrypoint.sh /usr/local/bin/qloapps-entrypoint

RUN set -eux; \
    chmod +x /usr/local/bin/qloapps-entrypoint; \
    bash -n /usr/local/bin/qloapps-entrypoint; \
    php -l /opt/qloapps/bin/bootstrap.php; \
    php -l /var/www/health/healthz.php; \
    php -l /opt/qloapps/php/https-location.php; \
    command -v setpriv; \
    command -v apache2ctl; \
    command -v apache2-foreground; \
    chown -R www-data:www-data "$APP_DIR" "$SEED_DIR"

WORKDIR /var/www/qloapps

CMD ["/usr/local/bin/qloapps-entrypoint"]
