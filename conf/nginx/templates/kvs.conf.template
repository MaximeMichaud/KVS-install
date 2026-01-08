# Main KVS site
server {
    listen                  443 ssl;
    http2                   on;
    server_name             ${MAIN_SERVER_NAME};
    set                     $base ${KVS_ROOT};
    root                    $base;

    # SSL
    ssl_certificate         /etc/nginx/ssl/${DOMAIN}/cert.pem;
    ssl_certificate_key     /etc/nginx/ssl/${DOMAIN}/key.pem;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=*, usb=()";

    # index.php
    index                   index.php;

    # KVS URL rewrites (from KVS archive _INSTALL/nginx_config.txt)
    include /etc/nginx/includes/kvs-rewrites.conf;

    # Fallback to index.php
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # Logging
    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log warn;

    # Assets, media
    location ~* \.(?:css(\.map)?|js(\.map)?|jpe?g|png|gif|ico|cur|heic|webp|tiff?|mp3|m4a|aac|ogg|midi?|wav|mp4|mov|webm|mpe?g|avi|ogv|flv|wmv)$ {
        expires 180d;
        access_log off;
    }

    # SVG, fonts
    location ~* \.(?:svgz?|ttf|ttc|otf|eot|woff2?)$ {
        add_header Access-Control-Allow-Origin "*";
        expires 180d;
        access_log off;
    }

    # Handle PHP
    location ~ \.php$ {
        ${RESOLVER_LINE}
        fastcgi_pass ${PHP_FPM_UPSTREAM};
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;

        # Timeouts
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 4 64k;
    }

    # KVS internal locations
    location ~* /blocks/.*\.php$ { internal; }
    location ~* /langs/.*\.php$ { internal; }
    location ~* /template/.*\.php$ { internal; }
    location ~* /tmp/.*\.php$ { internal; }

    # Protect videos from direct access
    location ^~ /contents/videos/ {
        internal;
        aio threads=default;
        mp4;
        mp4_buffer_size     1M;
        mp4_max_buffer_size 3M;
    }

    # phpMyAdmin
    location /phpmyadmin/ {
        alias /usr/share/phpmyadmin/;
        index index.php;

        # Static files
        location ~* ^/phpmyadmin/(.+\.(css|js|ico|gif|png|jpg|jpeg|svg|woff|woff2|ttf|eot))$ {
            alias /usr/share/phpmyadmin/$1;
            expires 180d;
            access_log off;
        }

        # PHP files
        location ~ ^/phpmyadmin/(.+\.php)$ {
            alias /usr/share/phpmyadmin/$1;
            ${RESOLVER_LINE}
            fastcgi_pass ${PHP_FPM_UPSTREAM};
            fastcgi_param SCRIPT_FILENAME $request_filename;
            include fastcgi_params;
        }
    }

    # Deny access to sensitive files
    location ~ /\. {
        deny all;
    }

    location ~ ^/(admin/include|tmp)/ {
        deny all;
    }
}

# WWW redirect
${WWW_REDIRECT_BLOCK}

# HTTP redirect + ACME challenge
server {
    listen      80;
    server_name ${DOMAIN} www.${DOMAIN};

    # ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/_letsencrypt;
    }

    location / {
        return 301 https://${REDIRECT_HOST}$request_uri;
    }
}
