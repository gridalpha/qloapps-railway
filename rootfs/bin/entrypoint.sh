#!/bin/bash
# QloApps on Railway - container entrypoint.
#
# Prepares the volume, renders the Apache and PHP configuration from the
# environment, provisions the database role, installs QloApps on the first boot and
# only then hands the port to Apache.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

APP_DIR="${APP_DIR:-/var/www/qloapps}"
SEED_DIR="${SEED_DIR:-/opt/qloapps-seed}"
DATA_DIR="${DATA_DIR:-/data}"
RUN_USER="${APACHE_RUN_USER:-www-data}"
RUN_GROUP="${APACHE_RUN_GROUP:-www-data}"

# The image bakes symlinks from the application tree into DATA_DIR, so the volume
# has to be mounted exactly there.
if [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ] && [ "$RAILWAY_VOLUME_MOUNT_PATH" != "$DATA_DIR" ]; then
    die "volume is mounted at $RAILWAY_VOLUME_MOUNT_PATH; this image requires $DATA_DIR"
fi

PORT="${PORT:-8080}"
case "$PORT" in
    ''|*[!0-9]*) die "PORT must be numeric, got '$PORT'" ;;
esac

PUBLIC_DOMAIN="${QLO_PUBLIC_DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-}}"
SERVER_NAME="${PUBLIC_DOMAIN:-localhost}"

ADMIN_DIR="${QLO_ADMIN_DIR:-admin}"
if ! printf '%s' "$ADMIN_DIR" | grep -Eq '^[A-Za-z0-9_-]{2,40}$'; then
    die "QLO_ADMIN_DIR must match [A-Za-z0-9_-]{2,40}, got '$ADMIN_DIR'"
fi

ADMIN_EMAIL="${QLO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${QLO_ADMIN_PASSWORD:-}"
ADMIN_FIRSTNAME="${QLO_ADMIN_FIRSTNAME:-Hotel}"
ADMIN_LASTNAME="${QLO_ADMIN_LASTNAME:-Manager}"
SHOP_NAME="${QLO_SHOP_NAME:-QloApps Hotel}"
SHOP_COUNTRY="${QLO_SHOP_COUNTRY:-us}"
SHOP_LANGUAGE="${QLO_SHOP_LANGUAGE:-en}"
SHOP_TIMEZONE="${QLO_SHOP_TIMEZONE:-UTC}"
INSTALL_FIXTURES="${QLO_INSTALL_FIXTURES:-1}"

# A ${{service.RAILWAY_PRIVATE_DOMAIN}} reference renders empty until that service
# owns a deployment, so repair the value on its shape rather than trusting it.
SMTP_HOST="${QLO_SMTP_HOST:-}"
case "$SMTP_HOST" in
    ''|:*) SMTP_HOST="" ;;
esac

export QLO_APP_DIR="$APP_DIR"
export QLO_DATA_DIR="$DATA_DIR"
export QLO_PUBLIC_DOMAIN="$PUBLIC_DOMAIN"
export QLO_ADMIN_EMAIL="$ADMIN_EMAIL"
export QLO_SMTP_HOST="$SMTP_HOST"
export QLO_SHOP_EMAIL="${QLO_SHOP_EMAIL:-$ADMIN_EMAIL}"

# ---------------------------------------------------------------- volume layout
log "preparing $DATA_DIR"
mkdir -p "$DATA_DIR" "$DATA_DIR/config" "$DATA_DIR/log"

SEED_VERSION="$(cat "$SEED_DIR/.seed-version" 2>/dev/null || echo unknown)"
STAMP_FILE="$DATA_DIR/.seed-version"
PREVIOUS_VERSION="$(cat "$STAMP_FILE" 2>/dev/null || echo none)"

# img, upload and download hold operator content mixed with the files the image
# ships, so they are only ever filled in, never overwritten. modules, themes,
# translations and mails are upstream code: refresh them whenever the image version
# changes, or an upgrade would ship new database schema against old module code.
for d in img upload download; do
    mkdir -p "$DATA_DIR/$d"
    cp -rn "$SEED_DIR/$d/." "$DATA_DIR/$d/" 2>/dev/null || true
done
for d in modules themes translations mails; do
    mkdir -p "$DATA_DIR/$d"
    if [ "$PREVIOUS_VERSION" != "$SEED_VERSION" ]; then
        log "refreshing $d from the image ($PREVIOUS_VERSION -> $SEED_VERSION)"
        cp -r "$SEED_DIR/$d/." "$DATA_DIR/$d/"
    else
        cp -rn "$SEED_DIR/$d/." "$DATA_DIR/$d/" 2>/dev/null || true
    fi
done

for d in img upload download modules themes translations mails; do
    [ -e "$DATA_DIR/$d/index.php" ] || log "warning: $DATA_DIR/$d looks unseeded"
done
printf '%s\n' "$SEED_VERSION" > "$STAMP_FILE"

if [ "$ADMIN_DIR" != "admin" ] && [ -d "$APP_DIR/admin" ]; then
    log "renaming the admin directory to $ADMIN_DIR"
    mv "$APP_DIR/admin" "$APP_DIR/$ADMIN_DIR"
fi

chown -R "$RUN_USER:$RUN_GROUP" "$DATA_DIR"
chown -R "$RUN_USER:$RUN_GROUP" "$APP_DIR"

# ------------------------------------------------------------------ php + apache
render() {
    local src="$1" dst="$2" pair key value
    shift 2
    cp "$src" "$dst"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        case "$value" in
            *'|'*) die "value for $key must not contain a pipe" ;;
        esac
        sed -i "s|$key|$value|g" "$dst"
    done
    if grep -Eq 'QLO_[A-Z_]+' "$dst"; then
        grep -En 'QLO_[A-Z_]+' "$dst" >&2
        die "unsubstituted placeholder left in $dst"
    fi
}

render /opt/qloapps/php/qloapps.ini.tpl /usr/local/etc/php/conf.d/zz-qloapps.ini \
    "QLO_PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-512M}" \
    "QLO_PHP_UPLOAD_MAX_FILESIZE=${PHP_UPLOAD_MAX_FILESIZE:-64M}" \
    "QLO_PHP_POST_MAX_SIZE=${PHP_POST_MAX_SIZE:-64M}" \
    "QLO_PHP_MAX_EXECUTION_TIME=${PHP_MAX_EXECUTION_TIME:-300}" \
    "QLO_PHP_TIMEZONE=${SHOP_TIMEZONE}"

render /opt/qloapps/apache/qloapps.conf.tpl /etc/apache2/sites-available/qloapps.conf \
    "QLO_LISTEN_PORT=${PORT}" \
    "QLO_SERVER_NAME=${SERVER_NAME}"

printf 'Listen %s\n' "$PORT" > /etc/apache2/ports.conf
a2ensite qloapps >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true

# Recent php:*-apache builds leave mpm_event enabled beside the mpm_prefork that
# mod_php needs, and only on Railway - the build-time fix is silently undone, so it
# is repeated here on every boot.
a2dismod -f mpm_event mpm_worker >/dev/null 2>&1 || true
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
a2enmod mpm_prefork >/dev/null 2>&1 || true

# Apache's prefork defaults (MaxRequestWorkers 150) are sized for a host, not for a
# Railway container quota, and every worker carries a whole mod_php. Size the pool
# from the cgroup so a plan change re-tunes it.
MEM_BYTES="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
case "$MEM_BYTES" in
    ''|max|*[!0-9]*) MEM_BYTES=1073741824 ;;
esac
MAX_WORKERS="${APACHE_MAX_WORKERS:-$(( MEM_BYTES / 1048576 / 48 ))}"
[ "$MAX_WORKERS" -lt 4 ] && MAX_WORKERS=4
[ "$MAX_WORKERS" -gt 48 ] && MAX_WORKERS=48
log "sizing apache prefork for $(( MEM_BYTES / 1048576 )) MB: MaxRequestWorkers=$MAX_WORKERS"
cat > /etc/apache2/conf-available/qloapps-mpm.conf <<EOF
<IfModule mpm_prefork_module>
    StartServers 2
    MinSpareServers 2
    MaxSpareServers 5
    MaxRequestWorkers ${MAX_WORKERS}
    MaxConnectionsPerChild 500
</IfModule>
EOF
a2enconf qloapps-mpm >/dev/null

apache2ctl -t

# ------------------------------------------------------------------- database
log "waiting for the database"
php /opt/qloapps/bin/bootstrap.php wait-db 60
php /opt/qloapps/bin/bootstrap.php provision-db
DB_SERVER="$(php /opt/qloapps/bin/bootstrap.php db-server)"
[ -n "$DB_SERVER" ] || die "could not resolve the database host"

run_as_app() {
    HOME=/var/www setpriv --reuid="$RUN_USER" --regid="$RUN_GROUP" --init-groups "$@"
}

if php /opt/qloapps/bin/bootstrap.php installed; then
    log "existing QloApps schema found"
    if [ ! -f "$DATA_DIR/config/settings.inc.php" ]; then
        log "settings file is missing beside an installed schema - regenerating"
        run_as_app php /opt/qloapps/bin/bootstrap.php write-settings
        if [ -n "$ADMIN_PASSWORD" ]; then
            run_as_app php /opt/qloapps/bin/bootstrap.php reset-admin
        fi
    fi
else
    [ -n "$ADMIN_PASSWORD" ] || die "QLO_ADMIN_PASSWORD must be set for the first install"
    if [ "${#ADMIN_PASSWORD}" -lt 8 ]; then
        die "QLO_ADMIN_PASSWORD must be at least 8 characters"
    fi

    STEPS="database,theme,modules"
    if [ "$INSTALL_FIXTURES" = "1" ]; then
        STEPS="database,fixtures,theme,modules"
    fi

    log "installing QloApps ${QLOAPPS_VERSION:-} (steps: $STEPS)"
    # addons_modules is deliberately not in the step list: it reaches out to the
    # QloApps marketplace, which a first boot must not depend on.
    run_as_app php "$APP_DIR/install/index_cli.php" \
        --step="$STEPS" \
        --language="$SHOP_LANGUAGE" \
        --all_languages=0 \
        --timezone="$SHOP_TIMEZONE" \
        --base_uri=/ \
        --domain="${PUBLIC_DOMAIN:-localhost}" \
        --db_server="$DB_SERVER" \
        --db_name="${QLO_DB_NAME:-qloapps}" \
        --db_user="${QLO_DB_USER:-qloapps}" \
        --db_password="${QLO_DB_PASSWORD:-}" \
        --db_create=0 \
        --db_clear=1 \
        --prefix="${QLO_DB_PREFIX:-qlo_}" \
        --engine=InnoDB \
        --name="$SHOP_NAME" \
        --activity=0 \
        --country="$SHOP_COUNTRY" \
        --firstname="$ADMIN_FIRSTNAME" \
        --lastname="$ADMIN_LASTNAME" \
        --email="$ADMIN_EMAIL" \
        --password="$ADMIN_PASSWORD" \
        --newsletter=0

    php /opt/qloapps/bin/bootstrap.php installed \
        || die "the installer finished but no schema is present - see the errors above"
    log "QloApps installed"
fi

php /opt/qloapps/bin/bootstrap.php post-config

# The web installer is a remote-code path; it is never needed again once the schema
# exists, and the image layer restores it on the next container if it ever is.
rm -rf "$APP_DIR/install"

chown -R "$RUN_USER:$RUN_GROUP" "$DATA_DIR" "$APP_DIR"

log "starting Apache on port $PORT (server name $SERVER_NAME)"
exec apache2-foreground
