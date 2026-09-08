ServerName QLO_SERVER_NAME
ServerTokens Prod
ServerSignature Off
TraceEnable Off

# Railway's edge reaches containers from 100.64.0.0/10 and appends its own public
# address (152.233.0.0/17) to X-Forwarded-For. mod_remoteip walks the header
# right-to-left, so all three ranges have to be trusted for REMOTE_ADDR to end up
# on the real client.
RemoteIPHeader X-Forwarded-For
RemoteIPTrustedProxy 100.64.0.0/10
RemoteIPTrustedProxy 152.233.0.0/17
RemoteIPTrustedProxy fd00::/8

# QloApps reads HTTP_X_FORWARDED_PROTO itself, but bundled libraries and modules
# only look at $_SERVER['HTTPS']. Conditional, so the plain-HTTP health prober is
# still seen as insecure and never triggers an app-level redirect.
SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on

<VirtualHost *:QLO_LISTEN_PORT>
    ServerName QLO_SERVER_NAME
    DocumentRoot /var/www/qloapps

    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 combined
    LogLevel warn

    <Directory /var/www/qloapps>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    # Health probe served outside the application tree, so a maintenance page, an
    # app-level HTTPS redirect or a friendly-URL rewrite cannot fail the deployment.
    Alias /healthz /var/www/health/healthz.php
    <Directory /var/www/health>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>

    # QloApps ships its own per-directory .htaccess for every sensitive tree; these
    # two have none.
    <DirectoryMatch "^/var/www/qloapps/(install|tests)(/|$)">
        Require all denied
    </DirectoryMatch>

</VirtualHost>
