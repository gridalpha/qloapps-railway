; upload_max_filesize and post_max_size are PHP_INI_PERDIR, so they cannot be set
; from application code and have to live in a php.ini.
memory_limit = QLO_PHP_MEMORY_LIMIT
upload_max_filesize = QLO_PHP_UPLOAD_MAX_FILESIZE
post_max_size = QLO_PHP_POST_MAX_SIZE
max_execution_time = QLO_PHP_MAX_EXECUTION_TIME
max_input_vars = 5000
date.timezone = QLO_PHP_TIMEZONE
expose_php = Off
auto_prepend_file = /opt/qloapps/php/https-location.php

opcache.enable = 1
opcache.memory_consumption = 192
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
