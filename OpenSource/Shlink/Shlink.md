```bash
read -p "Enter Redirection(Backend) domain name: " domain && \
mkdir -p /var/www/docker/shlink && \
cd /var/www/docker/shlink && \
mkdir -p "$domain" && \
cd "$domain" && \
vim docker-compose.yaml && \
docker compose up -d

# With Nginx Combo
read -p "Enter Frontend UI domain name: " uidomain && \
sudo certbot certonly --nginx -d "$domain" && \
sudo certbot certonly --nginx -d "$uidomain" && \
vim /etc/nginx/conf.d/"$domain" && \
vim /etc/nginx/conf.d/"$uidomain" && \
sudo systemctl reload nginx
```

```yml
services:
  shlink:
    image: shlinkio/shlink:stable
    restart: always
    container_name: shlink-backend
    environment:
      - TZ=America/Denver
      - DEFAULT_DOMAIN=go.example.com
      - IS_HTTPS_ENABLED=true
      - GEOLITE_LICENSE_KEY=
      - DB_DRIVER=maria
      - DB_USER=shlink
      - DB_NAME=shlink
      - DB_PASSWORD=password 
      - DB_HOST=database
      # Enable CORS for admin subdomain
      - CORS_ALLOW_ORIGIN=https://frontend-UI.example.com
      # Alternative: Allow multiple origins or wildcard
      # - CORS_ALLOW_ORIGIN=*
    depends_on:
      - database
    ports:
      - 8282:8080
    networks:
      - shlink-network
      
  database:
    image: mariadb:10.8
    restart: always
    container_name: shlink-database
    environment:
      - MARIADB_ROOT_PASSWORD=password 
      - MARIADB_DATABASE=shlink
      - MARIADB_USER=shlink
      - MARIADB_PASSWORD=password
    volumes:
      - ./data:/var/lib/mysql
    networks:
      - shlink-network
      
  shlink-web-client:
    image: shlinkio/shlink-web-client
    restart: always
    container_name: shlink-web-client
    depends_on:
      - shlink
    ports:
      - 8280:8080
    environment:
      # Point to the main domain where the API is accessible
      - SHLINK_SERVER_URL=https://go.example.com
      - SHLINK_SERVER_API_KEY=Generate_First
      - SHLINK_SERVER_NAME=Landivo
    networks:
      - shlink-network

networks:
  shlink-network:
    driver: bridge

```

# Nginx (Frontend | WebUI Domain)
```
server {
    listen 80;
    server_name frontend-UI.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name frontend-UI.example.com;

    # SSL certs (e.g. from Certbot)
    ssl_certificate     /etc/letsencrypt/live/frontend-UI.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/frontend-UI.example.com/privkey.pem;

    location / {
        auth_basic           "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass         http://127.0.0.1:8280/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket support (for real-time updates)
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";

        client_max_body_size 10M;
    }
}
```
# Nginx (Backend | ShortURL Domain)
```
server {
    listen 80;
    server_name go.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name go.example.com;

    # SSL certs (e.g. from Certbot)
    ssl_certificate     /etc/letsencrypt/live/go.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/go.example.com/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:8282/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket support (for real-time updates)
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";

        client_max_body_size 10M;
    }
}
```

## Generate API
```
docker exec shlink-backend shlink api-key:generate
```

# Migration	
## Backup
`docker exec shlink-database sh -c 'exec mysqldump -u root -p"$MARIADB_ROOT_PASSWORD" shlink' > shlink_backup.sql`


## Restore
`docker exec -i shlink-database sh -c 'exec mysql -u root -p"$MARIADB_ROOT_PASSWORD" shlink' < shlink_backup.sql
`

