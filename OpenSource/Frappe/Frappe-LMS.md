# Install Docker

```bash
# 0) Prepare Folder
read -p "Enter domain name: " domain
BASE="/var/www/docker/frappe-lms/$domain"
mkdir -p "$BASE"
cd "$BASE"
sudo certbot certonly --nginx -d "$domain" && \
vim /etc/nginx/sites-available/"$domain" && \
sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && \
sudo systemctl reload nginx && \
sudo systemctl restart nginx && \


# 1) grab the script
wget https://frappe.io/easy-install.py

# 2) deploy Frappe Learning (edit email + domain + port) 
HOME="$BASE" python3 easy-install.py deploy \
  --project=learning_prod_setup \
  --email=you@yourdomain.com \
  --image=ghcr.io/frappe/lms \
  --version=stable \
  --app=lms \
  --sitename training.example.com \
  --no-ssl \
  --http-port 8080
```

## Nginx Config

```
upstream frappe-bench-frappe {
	server 127.0.0.1:8080 fail_timeout=0;
}

upstream frappe-bench-socketio-server {
	server 127.0.0.1:9000 fail_timeout=0;
}

# setup maps
# server blocks

server {
	
	server_name lms.example.com;

	proxy_buffer_size 128k;
	proxy_buffers 4 256k;
	proxy_busy_buffers_size 256k;

	add_header X-Frame-Options "SAMEORIGIN";
	add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
	add_header X-Content-Type-Options nosniff;
	add_header X-XSS-Protection "1; mode=block";
	add_header Referrer-Policy "same-origin, strict-origin-when-cross-origin";

	#location /assets {
	#	try_files $uri =404;
	#	add_header Cache-Control "max-age=31536000";
	#}

	location ~ ^/protected/(.*) {
		internal;
		try_files /lms.example.com/$1 =404;
	}

	location /socket.io {
		proxy_http_version 1.1;
		proxy_set_header Upgrade $http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header X-Frappe-Site-Name lms.example.com;
		proxy_set_header Origin $scheme://$http_host;
		proxy_set_header Host $host;

		proxy_pass http://frappe-bench-socketio-server;
	}

	location / {

 		rewrite ^(.+)/$ $1 permanent;
  		rewrite ^(.+)/index\.html$ $1 permanent;
  		rewrite ^(.+)\.html$ $1 permanent;

		location ~* ^/files/.*.(htm|html|svg|xml) {
			add_header Content-disposition "attachment";
			try_files /lms.example.com/public/$uri @webserver;
		}

		try_files /lms.example.com/public/$uri @webserver;
	}

	location @webserver {
		proxy_http_version 1.1;
		proxy_set_header X-Forwarded-For $remote_addr;
		proxy_set_header X-Forwarded-Proto $scheme;
		proxy_set_header X-Frappe-Site-Name lms.example.com;
		proxy_set_header Host $host;
		proxy_set_header X-Use-X-Accel-Redirect True;
		proxy_read_timeout 120;
		proxy_redirect off;

		proxy_pass  http://frappe-bench-frappe;
	}

	# error pages
	error_page 502 /502.html;
	location /502.html {
		root /usr/local/lib/python3.11/dist-packages/bench/config/templates;
		internal;
	}
	# optimizations
	sendfile on;
	keepalive_timeout 15;
	client_max_body_size 2048m;
	client_body_buffer_size 16K;
	client_header_buffer_size 1k;

	# enable gzip compresion
	# based on https://mattstauffer.co/blog/enabling-gzip-on-nginx-servers-including-laravel-forge
	gzip on;
	gzip_http_version 1.1;
	gzip_comp_level 5;
	gzip_min_length 256;
	gzip_proxied any;
	gzip_vary on;
	gzip_types
		application/atom+xml
		application/javascript
		application/json
		application/rss+xml
		application/vnd.ms-fontobject
		application/x-font-ttf
		application/font-woff
		application/x-web-app-manifest+json
		application/xhtml+xml
		application/xml
		font/opentype
		image/svg+xml
		image/x-icon
		text/css
		text/plain
		text/x-component
		;
		# text/html is always compressed by HttpGzipModule

    listen [::]:443 ssl ipv6only=on; # managed by Certbot
    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/lms.example.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/lms.example.com/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
server {
    if ($host = lms.example.com) {
        return 301 https://$host$request_uri;
    } 
	listen 80;
	listen [::]:80;
	server_name lms.example.com;
    return 404; # managed by Certbot
}
```

# Custom Docker Mod
```bash
# Step 1: Saving Domain
read -p "Enter domain name: " domain && \

#Create Workspace & Domain
mkdir -p /var/www/docker/frappe-lms/lms-custom && cd /var/www/docker/frappe-lms/lms-custom && \

# Step 2: Clone LMS Repository
git clone --depth 1 https://github.com/frappe/lms.git && \

# Step 3: Edit the Frontend File
vim lms/frontend/src/utils/index.js
```

Find the `drive` block, add this **immediately after** its closing `},`:

```javascript
          dropbox: {
            regex: /(https?:\/\/(?:www\.)?dropbox\.com\/[^\s]+)/,
            embedUrl: "<%= remote_id %>",
            html: `<iframe style='width: 100%; height: ${
              window.innerWidth < 640 ? "15rem" : "30rem"
            }; border: 1px solid #D3D3D3; border-radius: 12px;' frameborder='0' allowfullscreen='true'></iframe>`,
            id: ([url]) => {
              return url.replace("www.dropbox.com", "dl.dropboxusercontent.com").replace("dropbox.com", "dl.dropboxusercontent.com").replace(/dl=0/, "raw=1");
            },
          },
```

```
          loom: {
            regex: /(https?:\/\/(?:www\.)?loom\.com\/share\/[a-zA-Z0-9]+)/,
            embedUrl: '<%= remote_id %>',
            html: `<iframe style='width: 100%; height: ${
              window.innerWidth < 640 ? '15rem' : '30rem'
            }; border: 0; border-radius: 12px;' frameborder='0' allowfullscreen='true'></iframe>`,
            id: ([url]) => {
              return url.replace('loom.com/share/', 'loom.com/embed/');
            }
          },
```

```bash
# Step 4: Create Dockerfile
cd /var/www/docker/frappe-lms/lms-custom && \

cat > Dockerfile <<'EOF'
FROM ghcr.io/frappe/lms:stable

USER root
COPY lms/frontend/src/utils/index.js /home/frappe/frappe-bench/apps/lms/frontend/src/utils/index.js
RUN chown frappe:frappe /home/frappe/frappe-bench/apps/lms/frontend/src/utils/index.js

# Create dummy config for build
RUN echo '{"socketio_port": 9000}' > /home/frappe/frappe-bench/sites/common_site_config.json && \
    chown frappe:frappe /home/frappe/frappe-bench/sites/common_site_config.json

USER frappe
WORKDIR /home/frappe/frappe-bench
RUN bench build --app lms
EOF

# Step 5: Build Custom Image
docker build -t lms-dropbox:custom . && \

# Step 6: Update Your Deployment
cd /var/www/docker/frappe-lms/"$domain"/ && \
vim learning_prod_setup.env && \

#Change:
#CUSTOM_IMAGE=lms-dropbox
#CUSTOM_TAG=custom

sed -i 's|ghcr\.io/frappe/lms:stable|lms-dropbox:custom|g' learning_prod_setup-compose.yml && \
# Step 7: Restart
cd /var/www/docker/frappe-lms/"$domain" && \
docker compose -f learning_prod_setup-compose.yml --project-name learning_prod_setup down && \
docker compose -f learning_prod_setup-compose.yml --project-name learning_prod_setup up -d && \
docker exec -it learning_prod_setup-backend-1 bash -lc "bench --site \"$domain\" clear-cache"
```
