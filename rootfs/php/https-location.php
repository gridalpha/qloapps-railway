<?php
/**
 * Prepended to every web request (auto_prepend_file).
 *
 * QloApps emits some redirects as a bare relative path — the admin entry point
 * answers `Location: index.php?controller=AdminLogin&token=…` — and Apache turns
 * those into absolute URLs using the scheme of the connection it actually served,
 * which behind Railway's edge is always plain HTTP. The browser would then make one
 * cleartext request carrying the admin's one-time token before the edge redirected
 * it to HTTPS. mod_headers cannot fix this: it runs before Apache absolutifies the
 * header, so it only ever sees the relative value.
 */
if (PHP_SAPI !== 'cli' && function_exists('header_register_callback')) {
    header_register_callback(function () {
        if (empty($_SERVER['HTTPS']) || strtolower($_SERVER['HTTPS']) !== 'on') {
            return;
        }
        $host = isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '';
        if ($host === '' || strpos($host, '/') !== false) {
            return;
        }

        foreach (headers_list() as $header) {
            if (stripos($header, 'location:') !== 0) {
                continue;
            }
            $value = trim(substr($header, strlen('location:')));
            if ($value === '' || stripos($value, 'https://') === 0) {
                return;
            }

            if (stripos($value, 'http://') === 0) {
                $absolute = 'https://' . substr($value, strlen('http://'));
            } elseif ($value[0] === '/') {
                $absolute = 'https://' . $host . $value;
            } else {
                $path = strtok(isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/', '?');
                $base = (substr($path, -1) === '/') ? $path : rtrim(dirname($path), '/') . '/';
                $absolute = 'https://' . $host . $base . $value;
            }

            header('Location: ' . $absolute, true);
            return;
        }
    });
}
