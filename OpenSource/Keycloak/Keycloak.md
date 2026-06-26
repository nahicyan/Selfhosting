## [Docker Compose Install](https://github.com/Tauromachian/keycloak-production-docker-compose/tree/master)
```bash
read -p "Enter domain name: " domain && mkdir -p /var/www/docker/keycloak && cd /var/www/docker/keycloak && git clone https://github.com/nahicyan/keycloak-production-docker-compose "$domain" && cd "$domain" && chmod +x script/*.sh && vim docker-compose.external-cert.yml && cp .env.example .env && vim .env && sudo certbot certonly --nginx -d "$domain" && vim /etc/nginx/sites-available/"$domain" && sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && sudo systemctl reload nginx && docker compose -f docker-compose.external-cert.yml up -d
```

## Nginx
```
server {
    listen 443 ssl http2;
    listen [::]:443 ssl;

    server_name auth.shinyhomes.net;
    access_log off;

    ssl_certificate /etc/letsencrypt/live/auth.shinyhomes.net/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/auth.shinyhomes.net/privkey.pem;

    root /usr/share/nginx;
    location / {
        add_header Cache-Control no-cache;

        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $http_host;
        proxy_pass http://127.0.0.1:8090/;
    }
}

```
