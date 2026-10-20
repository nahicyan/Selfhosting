# [Nextcloud](https://nextcloud.com/)
## [NextCloud-AIO Docker Compose](https://github.com/nextcloud/all-in-one)
```bash
read -p "Enter domain name: " domain && mkdir -p /var/www/docker/nextcloud/"$domain" && cd /var/www/docker/nextcloud/"$domain" && mkdir -p data && vim compose.yaml && sudo certbot certonly --nginx -d "$domain" && vim /etc/nginx/conf.d/"$domain".conf && sudo systemctl restart nginx && docker compose up -d && public_ip=$(curl -s https://api.ipify.org) && echo "Go to: https://$public_ip:8081/"
```
### [Docker Compose (Check For Updates Here)](https://github.com/nextcloud/all-in-one/blob/main/compose.yaml)
## ==Change (example.com)==
```yaml
services:
  nextcloud-aio-mastercontainer:
    image: ghcr.io/nextcloud-releases/all-in-one:latest
    init: true
    restart: always
    container_name: nextcloud-aio-mastercontainer # This line is not allowed to be changed as otherwise AIO will not work correctly
    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config # This line is not allowed to be changed as otherwise the built-in backup solution will not work
      - /var/run/docker.sock:/var/run/docker.sock:ro # May be changed on macOS, Windows or docker rootless. See the applicable documentation. If adjusting, don't forget to also set 'WATCHTOWER_DOCKER_SOCKET_PATH'!
    network_mode: bridge
	ports:
      # - 80:80 # Can be removed when running behind a web server or reverse proxy (like Apache, Nginx, Cloudflare Tunnel and else). See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
      - 8081:8080
      # - 8443:8443 # Can be removed when running behind a web server or reverse proxy (like Apache, Nginx, Cloudflare Tunnel and else). See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
    environment: # Is needed when using any of the options below
      - AIO_DISABLE_BACKUP_SECTION=false # Setting this to true allows to hide the backup section in the AIO interface. See https://github.com/nextcloud/all-in-one#how-to-disable-the-backup-section
      - APACHE_PORT=11000 # Is needed when running behind a web server or reverse proxy (like Apache, Nginx, Cloudflare Tunnel and else). See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
      - APACHE_IP_BINDING=127.0.0.1 # Should be set when running behind a web server or reverse proxy (like Apache, Nginx, Cloudflare Tunnel and else) that is running on the same host. See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
      - BORG_RETENTION_POLICY=--keep-within=7d --keep-weekly=4 --keep-monthly=6 # Allows to adjust borgs retention policy. See https://github.com/nextcloud/all-in-one#how-to-adjust-borgs-retention-policy
      # - COLLABORA_SECCOMP_DISABLED=false # Setting this to true allows to disable Collabora's Seccomp feature. See https://github.com/nextcloud/all-in-one#how-to-disable-collaboras-seccomp-feature
      - NEXTCLOUD_DATADIR=/var/www/docker/nextcloud/cloud.example.com/data # Allows to set the host directory for Nextcloud's datadir. ⚠️⚠️⚠️ Warning: do not set or adjust this value after the initial Nextcloud installation is done! See https://github.com/nextcloud/all-in-one#how-to-change-the-default-location-of-nextclouds-datadir
      # - NEXTCLOUD_MOUNT=/mnt/ # Allows the Nextcloud container to access the chosen directory on the host. See https://github.com/nextcloud/all-in-one#how-to-allow-the-nextcloud-container-to-access-directories-on-the-host
      - NEXTCLOUD_UPLOAD_LIMIT=128G # Can be adjusted if you need more. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-upload-limit-for-nextcloud
      - NEXTCLOUD_MAX_TIME=604800 # Can be adjusted if you need more. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-max-execution-time-for-nextcloud
      - NEXTCLOUD_MEMORY_LIMIT=2048M # Can be adjusted if you need more. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-php-memory-limit-for-nextcloud
      # - NEXTCLOUD_TRUSTED_CACERTS_DIR=/path/to/my/cacerts # CA certificates in this directory will be trusted by the OS of the nexcloud container (Useful e.g. for LDAPS) See See https://github.com/nextcloud/all-in-one#how-to-trust-user-defined-certification-authorities-ca
      - NEXTCLOUD_STARTUP_APPS=deck twofactor_totp tasks calendar contacts notes # Allows to modify the Nextcloud apps that are installed on starting AIO the first time. See https://github.com/nextcloud/all-in-one#how-to-change-the-nextcloud-apps-that-are-installed-on-the-first-startup
      - NEXTCLOUD_ADDITIONAL_APKS=imagemagick # This allows to add additional packages to the Nextcloud container permanently. Default is imagemagick but can be overwritten by modifying this value. See https://github.com/nextcloud/all-in-one#how-to-add-os-packages-permanently-to-the-nextcloud-container
      - NEXTCLOUD_ADDITIONAL_PHP_EXTENSIONS=imagick # This allows to add additional php extensions to the Nextcloud container permanently. Default is imagick but can be overwritten by modifying this value. See https://github.com/nextcloud/all-in-one#how-to-add-php-extensions-permanently-to-the-nextcloud-container
      # - NEXTCLOUD_ENABLE_DRI_DEVICE=true # This allows to enable the /dev/dri device in the Nextcloud container. ⚠️⚠️⚠️ Warning: this only works if the '/dev/dri' device is present on the host! If it should not exist on your host, don't set this to true as otherwise the Nextcloud container will fail to start! See https://github.com/nextcloud/all-in-one#how-to-enable-hardware-transcoding-for-nextcloud
      # - NEXTCLOUD_KEEP_DISABLED_APPS=false # Setting this to true will keep Nextcloud apps that are disabled in the AIO interface and not uninstall them if they should be installed. See https://github.com/nextcloud/all-in-one#how-to-keep-disabled-apps
      # - TALK_PORT=3478 # This allows to adjust the port that the talk container is using. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-talk-port
      - WATCHTOWER_DOCKER_SOCKET_PATH=/var/run/docker.sock # Needs to be specified if the docker socket on the host is not located in the default '/var/run/docker.sock'. Otherwise mastercontainer updates will fail. For macos it needs to be '/var/run/docker.sock'


volumes: # If you want to store the data on a different drive, see https://github.com/nextcloud/all-in-one#how-to-store-the-filesinstallation-on-a-separate-drive
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer # This line is not allowed to be changed as otherwise the built-in backup solution will not work

```
### [Nginx Reverse Proxy (Check For Updates)](https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md#nginx)
```yaml
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;            # comment to disable IPv6

    if ($scheme = "http") {
        return 301 https://$host$request_uri;
    }
    if ($http_x_forwarded_proto = "http") {
        return 301 https://$host$request_uri;
    }

    #listen 443 ssl http2;      # for nginx versions below v1.25.1
    #listen [::]:443 ssl http2; # for nginx versions below v1.25.1 - comment to disable IPv6

     listen 443 ssl;      # for nginx v1.25.1+
     listen [::]:443 ssl; # for nginx v1.25.1+ - keep comment to disable IPv6
     http2 on;            # uncomment to enable HTTP/2 - supported on nginx v1.25.1+

    # listen 443 quic reuseport;       # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+ - please remove "reuseport" if there is already another quic listener on port 443 with enabled reuseport
    # listen [::]:443 quic reuseport;  # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+ - please remove "reuseport" if there is already another quic listener on port 443 with enabled reuseport - keep comment to disable IPv6
    # http3 on;                                 # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+
    # quic_gso on;                              # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+
    # quic_retry on;                            # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+
    # quic_bpf on;                              # improves  HTTP/3 / QUIC - supported on nginx v1.25.0+, if nginx runs as a docker container you need to give it privileged permission to use this option
    # add_header Alt-Svc 'h3=":443"; ma=86400'; # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+

    proxy_buffering off;
    proxy_request_buffering off;

    client_max_body_size 0;
    client_body_buffer_size 512k;
    # http3_stream_buffer_size 512k; # uncomment to enable HTTP/3 / QUIC - supported on nginx v1.25.0+
    proxy_read_timeout 86400s;

    server_name cloud.example.com;

    location / {
        proxy_pass http://127.0.0.1:11000$request_uri; # Adjust to match APACHE_PORT and APACHE_IP_BINDING. See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md#adapting-the-sample-web-server-configurations-below

        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Scheme $scheme;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $host;
        proxy_set_header Early-Data $ssl_early_data;

        # Websocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }

    # If running nginx on a subdomain (eg. nextcloud.example.com) of a domain that already has an wildcard ssl certificate from certbot on this machine, 
    # the cloud.example.com in the below lines should be replaced with just the domain (eg. example.com), not the subdomain. 
    # In this case the subdomain should already be secured without additional actions
    ssl_certificate /etc/letsencrypt/live/cloud.example.com/fullchain.pem;   # managed by certbot on host machine
    ssl_certificate_key /etc/letsencrypt/live/cloud.example.com/privkey.pem; # managed by certbot on host machine

    #ssl_dhparam /etc/dhparam; # curl -L https://ssl-config.mozilla.org/ffdhe2048.txt -o /etc/dhparam

    ssl_early_data on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve x25519:x448:secp521r1:secp384r1:secp256r1;

    ssl_prefer_server_ciphers on;
    ssl_conf_command Options PrioritizeChaCha;
    ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256;
}


```
* * *
## [Docker Compose](https://github.com/nextcloud/docker) (Custom NextCloud:FPM)
`read -p "Enter domain name: " domain && mkdir -p /var/www/docker/nextcloud/"$domain" && cd /var/www/docker/nextcloud/"$domain" && mkdir -p html custom_apps config data themes && vim docker-compose.yml && vim nginx.conf && sudo certbot certonly --nginx -d "$domain" && vim /etc/nginx/sites-available/"$domain" && sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && sudo systemctl reload nginx && docker compose up -d
`
### Docker Compose
```yaml
version: '2'

volumes:
  nextcloud:
  db:

services:
  db:
    image: mariadb:10.6
    restart: always
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=
      - MYSQL_PASSWORD=
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud

  app:
    image: nextcloud:fpm
    restart: always
    links:
      - db
    volumes:
      - ./html:/var/www/html
      - ./custom_apps:/var/www/html/custom_apps
      - ./config:/var/www/html/config
      - ./data:/var/www/html/data
      - ./themes:/var/www/html/themes
    environment:
      - MYSQL_PASSWORD=
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_HOST=db
      - TRUSTED_PROXIES=cloud.example.com
      - OVERWRITECLIURL=https://cloud.example.com
      - OVERWRITEPROTOCOL=https
      - NEXTCLOUD_TRUSTED_DOMAINS=cloud.example.com
      - OVERWRITEHOST=cloud.example.com


  web:
    image: nginx
    restart: always
    ports:
      - 8081:80
    links:
      - app
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    volumes_from:
      - app
```
***
## [Niginx Configuration File](https://github.com/nextcloud/docker/blob/master/.examples/docker-compose/insecure/mariadb/fpm/web/nginx.conf)
```yml
worker_processes auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;


events {
    worker_connections  1024;
}


http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    # Prevent nginx HTTP Server Detection
    server_tokens   off;

    keepalive_timeout  65;

    #gzip  on;

    upstream php-handler {
        server app:9000;
    }

    server {
        listen 80;

        # HSTS settings
        # WARNING: Only add the preload option once you read about
        # the consequences in https://hstspreload.org/. This option
        # will add the domain to a hardcoded list that is shipped
        # in all major browsers and getting removed from this list
        # could take several months.
        #add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;

        # set max upload size
        client_max_body_size 512M;
        fastcgi_buffers 64 4K;

        # Enable gzip but do not remove ETag headers
        gzip on;
        gzip_vary on;
        gzip_comp_level 4;
        gzip_min_length 256;
        gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
        gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

        # Pagespeed is not supported by Nextcloud, so if your server is built
        # with the `ngx_pagespeed` module, uncomment this line to disable it.
        #pagespeed off;

        # HTTP response headers borrowed from Nextcloud `.htaccess`
        add_header Referrer-Policy                      "no-referrer"       always;
        add_header X-Content-Type-Options               "nosniff"           always;
        add_header X-Frame-Options                      "SAMEORIGIN"        always;
        add_header X-Permitted-Cross-Domain-Policies    "none"              always;
        add_header X-Robots-Tag                         "noindex, nofollow" always;
        add_header X-XSS-Protection                     "1; mode=block"     always;

        # Remove X-Powered-By, which is an information leak
        fastcgi_hide_header X-Powered-By;

        # Path to the root of your installation
        root /var/www/html;

        # Specify how to handle directories -- specifying `/index.php$request_uri`
        # here as the fallback means that Nginx always exhibits the desired behaviour
        # when a client requests a path that corresponds to a directory that exists
        # on the server. In particular, if that directory contains an index.php file,
        # that file is correctly served; if it doesn't, then the request is passed to
        # the front-end controller. This consistent behaviour means that we don't need
        # to specify custom rules for certain paths (e.g. images and other assets,
        # `/updater`, `/ocm-provider`, `/ocs-provider`), and thus
        # `try_files $uri $uri/ /index.php$request_uri`
        # always provides the desired behaviour.
        index index.php index.html /index.php$request_uri;

        # Rule borrowed from `.htaccess` to handle Microsoft DAV clients
        location = / {
            if ( $http_user_agent ~ ^DavClnt ) {
                return 302 /remote.php/webdav/$is_args$args;
            }
        }

        location = /robots.txt {
            allow all;
            log_not_found off;
            access_log off;
        }

        # Make a regex exception for `/.well-known` so that clients can still
        # access it despite the existence of the regex rule
        # `location ~ /(\.|autotest|...)` which would otherwise handle requests
        # for `/.well-known`.
        location ^~ /.well-known {
            # The rules in this block are an adaptation of the rules
            # in `.htaccess` that concern `/.well-known`.

            location = /.well-known/carddav { return 301 /remote.php/dav/; }
            location = /.well-known/caldav  { return 301 /remote.php/dav/; }

            location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
            location /.well-known/pki-validation    { try_files $uri $uri/ =404; }

            # Let Nextcloud's API for `/.well-known` URIs handle all other
            # requests by passing them to the front-end controller.
            return 301 /index.php$request_uri;
        }

        # Rules borrowed from `.htaccess` to hide certain paths from clients
        location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
        location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

        # Ensure this block, which passes PHP files to the PHP process, is above the blocks
        # which handle static assets (as seen below). If this block is not declared first,
        # then Nginx will encounter an infinite rewriting loop when it prepends `/index.php`
        # to the URI, resulting in a HTTP 500 error response.
        location ~ \.php(?:$|/) {
            # Required for legacy support
            rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;

            fastcgi_split_path_info ^(.+?\.php)(/.*)$;
            set $path_info $fastcgi_path_info;

            try_files $fastcgi_script_name =404;

            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $path_info;
            #fastcgi_param HTTPS on;

            fastcgi_param modHeadersAvailable true;         # Avoid sending the security headers twice
            fastcgi_param front_controller_active true;     # Enable pretty urls
            fastcgi_pass php-handler;

            fastcgi_intercept_errors on;
            fastcgi_request_buffering off;
        }

        location ~ \.(?:css|js|svg|gif)$ {
            try_files $uri /index.php$request_uri;
            expires 6M;         # Cache-Control policy borrowed from `.htaccess`
            access_log off;     # Optional: Don't log access to assets
        }

        location ~ \.woff2?$ {
            try_files $uri /index.php$request_uri;
            expires 7d;         # Cache-Control policy borrowed from `.htaccess`
            access_log off;     # Optional: Don't log access to assets
        }

        # Rule borrowed from `.htaccess`
        location /remote {
            return 301 /remote.php$request_uri;
        }

        location / {
            try_files $uri $uri/ /index.php$request_uri;
        }
    }
}

```

```yml
server {
    listen 80;
    listen [::]:80;
    server_name example.com;

    # Enforce HTTPS
    return 301 https://$server_name$request_uri;
}
server {
    listen 443      ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    #client_max_body_size 4096M;
    #client_body_timeout 300s;
    #fastcgi_buffers 64 4K;


    location / {
        proxy_pass http://localhost:8081/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        fastcgi_intercept_errors off;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload";
        client_max_body_size 0;

        access_log /var/log/nginx/nextcloud.access.log;
        error_log /var/log/nginx/nextcloud.error.log;
    }


    location /.well-known/carddav {
      return 301 $scheme://$host/remote.php/dav;
    }

    location /.well-known/caldav {
      return 301 $scheme://$host/remote.php/dav;
    }

    location = /.well-known/webfinger {
        return 301 /index.php$uri;
    }

    location = /.well-known/nodeinfo {
        return 301 /index.php$uri;
    }
}
```
## Backup & Migrate
### Backup Database
1. `docker container ls`
2. `read -p "Enter domain name: " domain && read -p "Enter MySQL container name: " mysql_container && read -sp "Enter MySQL root password: " mysql_root_password && echo && docker exec "$mysql_container" /usr/bin/mysqldump -u root --password="$mysql_root_password" nextcloud > "/${domain}-NC-$(date +"%a-%m%d%y-%H-%M").sql"`
### Backup Content
3. `read -p "Enter domain name for backup: " domain && sudo tar -cpvzf "/${domain}_NC_$(date +"%Y-%m-%d_%H-%M").tar.gz" -C /var/www/docker/nextcloud/ "${domain}/data" "${domain}/config" `
***
### Migrate Content
1. `cd / && read -p "Enter domain name to extract backup: " domain && sudo mkdir -p /var/www/docker/nextcloud && latest_backup=$(ls -t /${domain}_NC_*.tar.gz | head -n 1) && sudo tar -xzvf "$latest_backup" -C /var/www/docker/nextcloud`
### Migrate Database
2. `cd / && read -p "Enter domain name: " domain && read -p "Enter MySQL container name: " mysql_container && read -sp "Enter MySQL root password: " mysql_root_password && echo && latest_backup=$(ls -t /${domain}-NC*.sql | head -n 1) && cat "$latest_backup" | docker exec -i "$mysql_container" sh -c 'MYSQL_ROOT_PASSWORD='"'$mysql_root_password'"' /usr/bin/mysql -u root --password="$MYSQL_ROOT_PASSWORD" nextcloud'`

* * *
## [Bare Metal Install Nextcloud (Nginx)](https://docs.nextcloud.com/server/latest/admin_manual/installation/source_installation.html)

### [Installing PHP 8.0 & Modules](https://www.howtoforge.com/how-to-install-php-8-on-debian-11/)

1. `sudo apt update && sudo apt upgrade`
2.   `apt-get install unzip ca-certificates apt-transport-https software-properties-common -y`
3.  `echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list`
4.  `wget -qO - https://packages.sury.org/php/apt.gpg | apt-key add -`
5.  `apt-get update -y`
6.  `apt-get install php8.0 php8.0-{bz2,cli,common,ctype,curl,dev,dom,exif,fpm,gd,intl,imagick,mysql,mbstring,posix,xml,zip} php-{json,pear} -y`

### PHP Configuration

1.  Change in **/etc/php/X.X/fpm/php.ini** & **/etc/php/X.X/cli/php.ini**

```yml
date.timezone = Asia/Dhaka
upload_max_filesize = 128G
max_file_uploads = 100000
post_max_size = 128G
```

2.  Uncomment the following lines in the `www.conf` file located in  `/etc/php/X.X/fpm/pool.d/`

```
env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
```

4.  Restart PHP
    `systemctl restart php8.0-fpm`
    `systemctl enable php8.0-fpm`

* * *

## Install & Configure MariaDB

### Install MariaDB

1.  `apt install mariadb-server -y`
2.  `systemctl start mariadb`
3.  `systemctl enable mariadb`
4.  `mysql_secure_installation`

### Create Database & Configure

1.  `mysql -u root`
2.  Change the config to your liking
    `create database cloudstorage;`
    `create user Nu@localhost identified by 'PASSWORD';`
    `grant all privileges on cloudstorage.* to Nu@localhost identified by 'PASSWORD';`
5.  `flush privileges;`
6.  `exit`

* * *

## [Download Nextcloud](https://nextcloud.com/install/#instructions-server)

1.  `cd /var/www/`
2.  `wget -q https://download.nextcloud.com/server/releases/latest.zip`
3.  `unzip -qq latest.zip`
4.  `mkdir /var/www/Cloud`
5.  `mv /var/www/nextcloud/ /var/www/Cloud`
6.  `rm -r latest.zip`
7.  `chown -R www-data:www-data /var/www/Cloud`

* * *

# [Nginx Configuration](https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html)
## Subdomain

### Uncomment & Change The

- server unix:
- server_name
- root /path
- SSL Certificates
- Upload Size & Timeout

```yml
upstream php-handler {
    server 127.0.0.1:9000;
    #server unix:/var/run/php/php7.4-fpm.sock;
}

# Set the `immutable` cache control options only for assets with a cache busting `v` argument
map $arg_v $asset_immutable {
    "" "";
    default "immutable";
}


server {
    listen 80;
    listen [::]:80;
    server_name cloud.example.com;

    # Enforce HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443      ssl http2;
    listen [::]:443 ssl http2;
    server_name cloud.example.com;

    # Path to the root of your installation
    root /var/www/nextcloud;

    # Use Mozilla's guidelines for SSL/TLS settings
    # https://mozilla.github.io/server-side-tls/ssl-config-generator/
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # HSTS settings
    # WARNING: Only add the preload option once you read about
    # the consequences in https://hstspreload.org/. This option
    # will add the domain to a hardcoded list that is shipped
    # in all major browsers and getting removed from this list
    # could take several months.
    #add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;

    # set max upload size and increase upload timeout:
    client_max_body_size 512M;
    client_body_timeout 300s;
    fastcgi_buffers 64 4K;

    # Enable gzip but do not remove ETag headers
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

    # Pagespeed is not supported by Nextcloud, so if your server is built
    # with the `ngx_pagespeed` module, uncomment this line to disable it.
    #pagespeed off;

    # HTTP response headers borrowed from Nextcloud `.htaccess`
    add_header Referrer-Policy                      "no-referrer"   always;
    add_header X-Content-Type-Options               "nosniff"       always;
    add_header X-Download-Options                   "noopen"        always;
    add_header X-Frame-Options                      "SAMEORIGIN"    always;
    add_header X-Permitted-Cross-Domain-Policies    "none"          always;
    add_header X-Robots-Tag                         "none"          always;
    add_header X-XSS-Protection                     "1; mode=block" always;

    # Remove X-Powered-By, which is an information leak
    fastcgi_hide_header X-Powered-By;

    # Specify how to handle directories -- specifying `/index.php$request_uri`
    # here as the fallback means that Nginx always exhibits the desired behaviour
    # when a client requests a path that corresponds to a directory that exists
    # on the server. In particular, if that directory contains an index.php file,
    # that file is correctly served; if it doesn't, then the request is passed to
    # the front-end controller. This consistent behaviour means that we don't need
    # to specify custom rules for certain paths (e.g. images and other assets,
    # `/updater`, `/ocm-provider`, `/ocs-provider`), and thus
    # `try_files $uri $uri/ /index.php$request_uri`
    # always provides the desired behaviour.
    index index.php index.html /index.php$request_uri;

    # Rule borrowed from `.htaccess` to handle Microsoft DAV clients
    location = / {
        if ( $http_user_agent ~ ^DavClnt ) {
            return 302 /remote.php/webdav/$is_args$args;
        }
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # Make a regex exception for `/.well-known` so that clients can still
    # access it despite the existence of the regex rule
    # `location ~ /(\.|autotest|...)` which would otherwise handle requests
    # for `/.well-known`.
    location ^~ /.well-known {
        # The rules in this block are an adaptation of the rules
        # in `.htaccess` that concern `/.well-known`.

        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }

        location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation    { try_files $uri $uri/ =404; }

        # Let Nextcloud's API for `/.well-known` URIs handle all other
        # requests by passing them to the front-end controller.
        return 301 /index.php$request_uri;
    }

    # Rules borrowed from `.htaccess` to hide certain paths from clients
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

    # Ensure this block, which passes PHP files to the PHP process, is above the blocks
    # which handle static assets (as seen below). If this block is not declared first,
    # then Nginx will encounter an infinite rewriting loop when it prepends `/index.php`
    # to the URI, resulting in a HTTP 500 error response.
    location ~ \.php(?:$|/) {
        # Required for legacy support
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        try_files $fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;

        fastcgi_param modHeadersAvailable true;         # Avoid sending the security headers twice
        fastcgi_param front_controller_active true;     # Enable pretty urls
        fastcgi_pass php-handler;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;

        fastcgi_max_temp_file_size 0;
    }

    location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, $asset_immutable";
        access_log off;     # Optional: Don't log access to assets

        location ~ \.wasm$ {
            default_type application/wasm;
        }
    }

    location ~ \.woff2?$ {
        try_files $uri /index.php$request_uri;
        expires 7d;         # Cache-Control policy borrowed from `.htaccess`
        access_log off;     # Optional: Don't log access to assets
    }

    # Rule borrowed from `.htaccess`
    location /remote {
        return 301 /remote.php$request_uri;
    }

    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }
}
```
### Subdirectory
#### Uncomment & Change The

- server unix:
- server_name
- root /path
- SSL Certificates
- Upload Size & Timeout

```yml
upstream php-handler {
    server 127.0.0.1:9000;
    #server unix:/var/run/php/php7.4-fpm.sock;
}

# Set the `immutable` cache control options only for assets with a cache busting `v` argument
map $arg_v $asset_immutable {
    "" "";
    default "immutable";
}

server {
    listen 80;
    listen [::]:80;
    server_name cloud.example.com;

    # Prevent nginx HTTP Server Detection
    server_tokens off;

    # Enforce HTTPS just for `/nextcloud`
    location /nextcloud {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443      ssl http2;
    listen [::]:443 ssl http2;
    server_name cloud.example.com;

    # Path to the root of the domain
    root /var/www;

    # Use Mozilla's guidelines for SSL/TLS settings
    # https://mozilla.github.io/server-side-tls/ssl-config-generator/
    ssl_certificate     /etc/ssl/nginx/cloud.example.com.crt;
    ssl_certificate_key /etc/ssl/nginx/cloud.example.com.key;

    # Prevent nginx HTTP Server Detection
    server_tokens off;

    # HSTS settings
    # WARNING: Only add the preload option once you read about
    # the consequences in https://hstspreload.org/. This option
    # will add the domain to a hardcoded list that is shipped
    # in all major browsers and getting removed from this list
    # could take several months.
    #add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location ^~ /.well-known {
        # The rules in this block are an adaptation of the rules
        # in the Nextcloud `.htaccess` that concern `/.well-known`.

        location = /.well-known/carddav { return 301 /nextcloud/remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /nextcloud/remote.php/dav/; }

        location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation    { try_files $uri $uri/ =404; }

        # Let Nextcloud's API for `/.well-known` URIs handle all other
        # requests by passing them to the front-end controller.
        return 301 /nextcloud/index.php$request_uri;
    }

    location ^~ /nextcloud {
        # set max upload size and increase upload timeout:
        client_max_body_size 512M;
        client_body_timeout 300s;
        fastcgi_buffers 64 4K;

        # Enable gzip but do not remove ETag headers
        gzip on;
        gzip_vary on;
        gzip_comp_level 4;
        gzip_min_length 256;
        gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
        gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

        # Pagespeed is not supported by Nextcloud, so if your server is built
        # with the `ngx_pagespeed` module, uncomment this line to disable it.
        #pagespeed off;

        # The settings allows you to optimize the HTTP2 bandwitdth.
        # See https://blog.cloudflare.com/delivering-http-2-upload-speed-improvements/
        # for tunning hints
        client_body_buffer_size 512k;

        # HTTP response headers borrowed from Nextcloud `.htaccess`
        add_header Referrer-Policy                      "no-referrer"   always;
        add_header X-Content-Type-Options               "nosniff"       always;
        add_header X-Download-Options                   "noopen"        always;
        add_header X-Frame-Options                      "SAMEORIGIN"    always;
        add_header X-Permitted-Cross-Domain-Policies    "none"          always;
        add_header X-Robots-Tag                         "none"          always;
        add_header X-XSS-Protection                     "1; mode=block" always;

        # Remove X-Powered-By, which is an information leak
        fastcgi_hide_header X-Powered-By;

        # Specify how to handle directories -- specifying `/nextcloud/index.php$request_uri`
        # here as the fallback means that Nginx always exhibits the desired behaviour
        # when a client requests a path that corresponds to a directory that exists
        # on the server. In particular, if that directory contains an index.php file,
        # that file is correctly served; if it doesn't, then the request is passed to
        # the front-end controller. This consistent behaviour means that we don't need
        # to specify custom rules for certain paths (e.g. images and other assets,
        # `/updater`, `/ocm-provider`, `/ocs-provider`), and thus
        # `try_files $uri $uri/ /nextcloud/index.php$request_uri`
        # always provides the desired behaviour.
        index index.php index.html /nextcloud/index.php$request_uri;

        # Rule borrowed from `.htaccess` to handle Microsoft DAV clients
        location = /nextcloud {
            if ( $http_user_agent ~ ^DavClnt ) {
                return 302 /nextcloud/remote.php/webdav/$is_args$args;
            }
        }

        # Rules borrowed from `.htaccess` to hide certain paths from clients
        location ~ ^/nextcloud/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)    { return 404; }
        location ~ ^/nextcloud/(?:\.|autotest|occ|issue|indie|db_|console)                  { return 404; }

        # Ensure this block, which passes PHP files to the PHP process, is above the blocks
        # which handle static assets (as seen below). If this block is not declared first,
        # then Nginx will encounter an infinite rewriting loop when it prepends
        # `/nextcloud/index.php` to the URI, resulting in a HTTP 500 error response.
        location ~ \.php(?:$|/) {
            # Required for legacy support
            rewrite ^/nextcloud/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /nextcloud/index.php$request_uri;

            fastcgi_split_path_info ^(.+?\.php)(/.*)$;
            set $path_info $fastcgi_path_info;

            try_files $fastcgi_script_name =404;

            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $path_info;
            fastcgi_param HTTPS on;

            fastcgi_param modHeadersAvailable true;         # Avoid sending the security headers twice
            fastcgi_param front_controller_active true;     # Enable pretty urls
            fastcgi_pass php-handler;

            fastcgi_intercept_errors on;
            fastcgi_request_buffering off;

            fastcgi_max_temp_file_size 0;
        }

        location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
            try_files $uri /nextcloud/index.php$request_uri;
            add_header Cache-Control "public, max-age=15778463, $asset_immutable";
            access_log off;     # Optional: Don't log access to assets

            location ~ \.wasm$ {
                default_type application/wasm;
            }
        }

        location ~ \.woff2?$ {
            try_files $uri /nextcloud/index.php$request_uri;
            expires 7d;         # Cache-Control policy borrowed from `.htaccess`
            access_log off;     # Optional: Don't log access to assets
        }

        # Rule borrowed from `.htaccess`
        location /nextcloud/remote {
            return 301 /nextcloud/remote.php$request_uri;
        }

        location /nextcloud {
            try_files $uri $uri/ /nextcloud/index.php$request_uri;
        }
    }
}
```
* * *

## Generate SSL

### `sudo certbot certonly --nginx -d cloud.example.com`

### Refer to Let's Encrypt SSL / Certbot note for the SSL Nginx Configuration
* * *
# [Migrate](https://docs.nextcloud.com/server/19/admin_manual/maintenance/migrating.html)
## Backup
### What to backup
1. The config folder
2. The data folder
3. The theme folder
4. The database
### Process
1. Backup Folders
`tar -cvpzf /nextcloud.tar.gz /var/www/Cloud/data /var/www/Cloud/config /var/www/Cloud/themes`
2. Backup MariaDB
`mysqldump --single-transaction cloudstorage > nextcloud.sql`
## Restore
`cd /`
`tar -xvf nextcloud.tar.gz`
`mysql cloudstorage < nextcloud.sql`
* * *
# Guides & Tweaks
## Email
| Protocol | Security | Port |
|----------|----------|------|
| SMTPS    | SSL      | 465  |

## Calendar Share
`http://nextcloud.com/apps/calendar/p/token1-token2-token3`

* * *
# Super Productivity
Share WebDev From File Manager With App Password & NOT From Calendar
* * *
Issue
Add Those At The End Of Nginx Config 

```
    location = /.well-known/carddav { return 301 /remote.php/dav/; }
    location = /.well-known/caldav  { return 301 /remote.php/dav/; }

    location /.well-known/webfinger { return 301 /index.php/.well-known/webfinger; }
    location /.well-known/nodeinfo { return 301 /index.php/.well-known/nodeinfo; }

    location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
    location /.well-known/pki-validation { try_files $uri $uri/ =404; }
```[Asterisk + FreePBX](:/2f34bf26a72e4f568dd2122ed1474967)