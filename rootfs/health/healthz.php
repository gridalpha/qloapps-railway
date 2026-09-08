<?php
/**
 * Anonymous liveness + dependency probe, served by an Apache Alias outside the
 * QloApps tree so no application rewrite, redirect or maintenance page can reach it.
 * It opens the shop's own configured database connection and reads a real row.
 */
header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

$settings = '/var/www/qloapps/config/settings.inc.php';

if (!file_exists($settings)) {
    http_response_code(503);
    echo "not installed\n";
    exit;
}

require_once $settings;

try {
    $dsn = 'mysql:dbname=' . _DB_NAME_ . ';';
    if (preg_match('/^(.*):([0-9]+)$/', _DB_SERVER_, $m)) {
        $dsn .= 'host=' . $m[1] . ';port=' . $m[2];
    } else {
        $dsn .= 'host=' . _DB_SERVER_;
    }
    $pdo = new PDO($dsn, _DB_USER_, _DB_PASSWD_, array(
        PDO::ATTR_TIMEOUT => 4,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ));
    $shops = (int) $pdo->query('SELECT COUNT(*) FROM `' . _DB_PREFIX_ . 'shop_url`')->fetchColumn();
    if ($shops < 1) {
        http_response_code(503);
        echo "no shop configured\n";
        exit;
    }
} catch (Exception $e) {
    http_response_code(503);
    echo "database unavailable\n";
    exit;
}

echo "ok\n";
