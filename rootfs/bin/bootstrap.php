<?php
/**
 * QloApps on Railway - boot-time database bootstrap and post-install configuration.
 *
 * Everything here runs from the entrypoint before Apache starts. It is written in
 * PHP rather than shell because the image already carries a mysqlnd that speaks
 * MySQL 9's caching_sha2_password handshake; the Debian mysql/mariadb client does
 * not ship in this image at all.
 *
 * Subcommands:
 *   wait-db      block until the admin connection answers
 *   provision-db create the application database, its scoped role and grants
 *   installed    exit 0 when the schema is present, 1 when it is not
 *   post-config  align shop URL, SSL and mail settings with the environment
 */

function env_str($name, $default = '')
{
    $v = getenv($name);
    if ($v === false || $v === '') {
        return $default;
    }
    return $v;
}

function fail($msg)
{
    fwrite(STDERR, "[bootstrap] ERROR: $msg\n");
    exit(1);
}

function info($msg)
{
    fwrite(STDOUT, "[bootstrap] $msg\n");
}

/**
 * Admin (root) connection details, from the discrete variables when present and
 * otherwise parsed out of Railway's MYSQL_URL.
 */
function admin_dsn_parts()
{
    $host = env_str('MYSQL_ADMIN_HOST');
    $port = env_str('MYSQL_ADMIN_PORT', '3306');
    $user = env_str('MYSQL_ADMIN_USER');
    $pass = env_str('MYSQL_ADMIN_PASSWORD');

    if ($host === '' || $user === '') {
        $url = env_str('MYSQL_URL');
        if ($url === '') {
            fail('neither MYSQL_URL nor MYSQL_ADMIN_HOST/MYSQL_ADMIN_USER is set');
        }
        $p = parse_url($url);
        if ($p === false || !isset($p['host'])) {
            fail('MYSQL_URL could not be parsed');
        }
        $host = $p['host'];
        $port = isset($p['port']) ? (string) $p['port'] : '3306';
        $user = isset($p['user']) ? rawurldecode($p['user']) : 'root';
        $pass = isset($p['pass']) ? rawurldecode($p['pass']) : '';
    }

    return array($host, $port, $user, $pass);
}

function connect($host, $port, $user, $pass, $dbname = null, $timeout = 5)
{
    $dsn = 'mysql:host=' . $host . ';port=' . $port;
    if ($dbname !== null) {
        $dsn .= ';dbname=' . $dbname;
    }
    return new PDO($dsn, $user, $pass, array(
        PDO::ATTR_TIMEOUT => $timeout,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::MYSQL_ATTR_USE_BUFFERED_QUERY => true,
    ));
}

function app_db_config()
{
    return array(
        env_str('QLO_DB_NAME', 'qloapps'),
        env_str('QLO_DB_USER', 'qloapps'),
        env_str('QLO_DB_PASSWORD'),
        env_str('QLO_DB_PREFIX', 'qlo_'),
    );
}

function cmd_wait_db($attempts)
{
    list($host, $port, $user, $pass) = admin_dsn_parts();
    for ($i = 1; $i <= $attempts; $i++) {
        try {
            $pdo = connect($host, $port, $user, $pass);
            $pdo->query('SELECT 1');
            info("database reachable at $host:$port (attempt $i)");
            return;
        } catch (Exception $e) {
            if ($i === $attempts) {
                fail('database not reachable after ' . $attempts . ' attempts: ' . $e->getMessage());
            }
            sleep(5);
        }
    }
}

/**
 * Railway's managed MySQL hands out the superuser. QloApps is module-extensible and
 * modules run arbitrary SQL, so the application gets its own database and a role
 * scoped to it. Idempotent: safe to re-run on every boot.
 */
function cmd_provision_db()
{
    list($host, $port, $user, $pass) = admin_dsn_parts();
    list($dbName, $dbUser, $dbPass, $dbPrefix) = app_db_config();

    if ($dbPass === '') {
        fail('QLO_DB_PASSWORD is empty; set it to a long random string');
    }
    if (!preg_match('/^[A-Za-z0-9_]{1,60}$/', $dbName) || !preg_match('/^[A-Za-z0-9_]{1,30}$/', $dbUser)) {
        fail('QLO_DB_NAME and QLO_DB_USER must match [A-Za-z0-9_]');
    }

    $pdo = connect($host, $port, $user, $pass, null, 15);
    $pdo->exec('CREATE DATABASE IF NOT EXISTS `' . $dbName . '` DEFAULT CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci');

    $q = $pdo->quote($dbPass);
    $pdo->exec("CREATE USER IF NOT EXISTS '" . $dbUser . "'@'%' IDENTIFIED BY " . $q);
    $pdo->exec("ALTER USER '" . $dbUser . "'@'%' IDENTIFIED BY " . $q);
    $pdo->exec(
        'GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, '
        . 'CREATE TEMPORARY TABLES, LOCK TABLES, CREATE VIEW, SHOW VIEW, EXECUTE '
        . "ON `" . $dbName . "`.* TO '" . $dbUser . "'@'%'"
    );
    $pdo->exec('FLUSH PRIVILEGES');

    info("provisioned database `$dbName` and scoped role `$dbUser` (prefix $dbPrefix)");
}

function app_pdo()
{
    list($host, $port, $adminUser, $adminPass) = admin_dsn_parts();
    list($dbName, $dbUser, $dbPass) = app_db_config();
    return connect($host, $port, $dbUser, $dbPass, $dbName, 10);
}

function schema_installed()
{
    list($dbName, $dbUser, $dbPass, $dbPrefix) = app_db_config();
    try {
        $pdo = app_pdo();
        $stmt = $pdo->prepare(
            'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = ?'
        );
        $stmt->execute(array($dbName, $dbPrefix . 'shop_url'));
        return ((int) $stmt->fetchColumn()) > 0;
    } catch (Exception $e) {
        return false;
    }
}

function cmd_installed()
{
    exit(schema_installed() ? 0 : 1);
}

function set_config(PDO $pdo, $prefix, $name, $value)
{
    $stmt = $pdo->prepare('SELECT id_configuration FROM `' . $prefix . 'configuration` WHERE name = ? LIMIT 1');
    $stmt->execute(array($name));
    $id = $stmt->fetchColumn();
    if ($id === false) {
        $ins = $pdo->prepare(
            'INSERT INTO `' . $prefix . 'configuration` (name, value, date_add, date_upd) VALUES (?, ?, NOW(), NOW())'
        );
        $ins->execute(array($name, $value));
        return;
    }
    $upd = $pdo->prepare('UPDATE `' . $prefix . 'configuration` SET value = ?, date_upd = NOW() WHERE name = ?');
    $upd->execute(array($value, $name));
}

/**
 * Re-applied on every boot: a Railway public domain can be regenerated or replaced
 * by a custom domain, and QloApps resolves the shop from the request Host, so a
 * stale ps_shop_url row 404s every page.
 */
function cmd_post_config()
{
    list($dbName, $dbUser, $dbPass, $prefix) = app_db_config();
    $pdo = app_pdo();

    $domain = env_str('QLO_PUBLIC_DOMAIN');
    if ($domain !== '') {
        $pdo->prepare(
            'UPDATE `' . $prefix . 'shop_url` SET domain = ?, domain_ssl = ?, physical_uri = ?, main = 1, active = 1 WHERE id_shop = 1'
        )->execute(array($domain, $domain, '/'));
        set_config($pdo, $prefix, 'PS_SHOP_DOMAIN', $domain);
        set_config($pdo, $prefix, 'PS_SHOP_DOMAIN_SSL', $domain);
        // Railway terminates TLS at the edge and 301s http to https, so the shop is
        // https-only from the browser's point of view.
        set_config($pdo, $prefix, 'PS_SSL_ENABLED', '1');
        set_config($pdo, $prefix, 'PS_SSL_ENABLED_EVERYWHERE', '1');
        info("shop URL set to https://$domain/");
    }

    $shopEmail = env_str('QLO_SHOP_EMAIL');
    if ($shopEmail !== '') {
        set_config($pdo, $prefix, 'PS_SHOP_EMAIL', $shopEmail);
    }

    // Mail settings live in the database, not the environment, so they are seeded
    // once and never re-applied: an operator changing them in the admin must win.
    $marker = env_str('QLO_DATA_DIR', '/data') . '/.mail-seeded';
    $smtpHost = env_str('QLO_SMTP_HOST');
    if ($smtpHost !== '' && !file_exists($marker)) {
        set_config($pdo, $prefix, 'PS_MAIL_METHOD', '2');
        set_config($pdo, $prefix, 'PS_MAIL_SERVER', $smtpHost);
        set_config($pdo, $prefix, 'PS_MAIL_SMTP_PORT', env_str('QLO_SMTP_PORT', '1025'));
        set_config($pdo, $prefix, 'PS_MAIL_SMTP_ENCRYPTION', env_str('QLO_SMTP_ENCRYPTION', 'off'));
        set_config($pdo, $prefix, 'PS_MAIL_USER', env_str('QLO_SMTP_USER', ''));
        set_config($pdo, $prefix, 'PS_MAIL_PASSWD', env_str('QLO_SMTP_PASSWORD', ''));
        set_config($pdo, $prefix, 'PS_MAIL_TYPE', '3');
        @file_put_contents($marker, date('c') . "\n");
        info("SMTP configured against $smtpHost");
    }
}

/**
 * Recovery path only: the schema exists but config/settings.inc.php (which lives on
 * the volume) does not. Without it the application cannot boot at all, so a fresh
 * one is written and the admin password re-hashed against the new _COOKIE_KEY_ —
 * QloApps stores employee passwords as md5(_COOKIE_KEY_ . password).
 */
function cmd_write_settings()
{
    list($host, $port, $adminUser, $adminPass) = admin_dsn_parts();
    list($dbName, $dbUser, $dbPass, $prefix) = app_db_config();

    $appDir = env_str('QLO_APP_DIR', '/var/www/qloapps');
    require_once $appDir . '/tools/defuse/php-encryption/defuse-crypto.phar';
    $newCookieKey = \Defuse\Crypto\Key::createNewRandomKey()->saveToAsciiSafeString();

    $cookieKey = substr(bin2hex(random_bytes(32)), 0, 56);
    $cookieIv = substr(bin2hex(random_bytes(8)), 0, 8);

    $constants = array(
        '_DB_SERVER_' => $host . ':' . $port,
        '_DB_NAME_' => $dbName,
        '_DB_USER_' => $dbUser,
        '_DB_PASSWD_' => $dbPass,
        '_DB_PREFIX_' => $prefix,
        '_MYSQL_ENGINE_' => 'InnoDB',
        '_PS_CACHING_SYSTEM_' => 'CacheMemcache',
        '_PS_CACHE_ENABLED_' => '0',
        '_COOKIE_KEY_' => $cookieKey,
        '_COOKIE_IV_' => $cookieIv,
        '_NEW_COOKIE_KEY_' => $newCookieKey,
        '_PS_CREATION_DATE_' => date('Y-m-d'),
    );

    if (!file_exists($appDir . '/install/install_version.php')) {
        fail('install/install_version.php is gone; cannot determine the schema version');
    }
    require_once $appDir . '/install/install_version.php';
    $constants['_PS_VERSION_'] = _PS_INSTALL_VERSION_;
    $constants['_QLOAPPS_VERSION_'] = _QLO_INSTALL_VERSION_;

    $out = "<?php\n";
    foreach ($constants as $name => $value) {
        if ($name === '_PS_VERSION_') {
            $out .= "if (!defined('" . $name . "'))\n\t";
        }
        $out .= "define('" . $name . "', '" . str_replace("'", "\\'", $value) . "');\n";
    }

    $target = $appDir . '/config/settings.inc.php';
    if (file_put_contents($target, $out) === false) {
        fail('could not write ' . $target);
    }
    info('regenerated config/settings.inc.php with fresh cookie keys');
}

function cmd_reset_admin()
{
    list($dbName, $dbUser, $dbPass, $prefix) = app_db_config();
    $appDir = env_str('QLO_APP_DIR', '/var/www/qloapps');
    $email = env_str('QLO_ADMIN_EMAIL');
    $password = env_str('QLO_ADMIN_PASSWORD');
    if ($email === '' || $password === '') {
        fail('QLO_ADMIN_EMAIL and QLO_ADMIN_PASSWORD must be set to reset the admin');
    }

    $settings = $appDir . '/config/settings.inc.php';
    if (!file_exists($settings)) {
        fail('settings file missing, cannot reset admin');
    }
    require_once $settings;

    $pdo = app_pdo();
    $stmt = $pdo->prepare('UPDATE `' . $prefix . 'employee` SET passwd = ? WHERE email = ?');
    $stmt->execute(array(md5(_COOKIE_KEY_ . $password), $email));
    if ($stmt->rowCount() === 0) {
        info("no employee row for $email; leaving the employee table alone");
    } else {
        info("re-hashed the password for $email against the current cookie key");
    }
}

function cmd_db_server()
{
    list($host, $port) = admin_dsn_parts();
    echo $host . ':' . $port;
}

$argvCmd = isset($argv[1]) ? $argv[1] : '';
switch ($argvCmd) {
    case 'db-server':
        cmd_db_server();
        break;
    case 'write-settings':
        cmd_write_settings();
        break;
    case 'reset-admin':
        cmd_reset_admin();
        break;
    case 'wait-db':
        cmd_wait_db(isset($argv[2]) ? (int) $argv[2] : 60);
        break;
    case 'provision-db':
        cmd_provision_db();
        break;
    case 'installed':
        cmd_installed();
        break;
    case 'post-config':
        cmd_post_config();
        break;
    default:
        fail('unknown subcommand: ' . $argvCmd);
}
