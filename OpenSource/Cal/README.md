# [Docker Install](https://github.com/calcom/docker)
```bash
nextAuthSecret=$(openssl rand -base64 32) && calEncryption=$(dd if=/dev/urandom bs=1K count=1 2>/dev/null | md5sum | cut -d' ' -f1) && echo "NextAuth-Secret= $nextAuthSecret" && echo "Cal-Encryption= $calEncryption" && read -p "Enter domain name: " domain && mkdir -p /var/www/docker/cal && cd /var/www/docker/cal && git clone https://github.com/calcom/docker.git "$domain" && cd "$domain" && cp .env.example .env && read -p "Enter Email Address: " email && read -p "Enter Email Server Host: " mailserver && sudo sed -i "s|^NEXT_PUBLIC_LICENSE_CONSENT=.*|NEXT_PUBLIC_LICENSE_CONSENT=true|; s|^NEXT_PUBLIC_WEBAPP_URL=.*|NEXT_PUBLIC_WEBAPP_URL=https://$domain|; s|^NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=$nextAuthSecret|; s|^CALENDSO_ENCRYPTION_KEY=.*|CALENDSO_ENCRYPTION_KEY=$calEncryption|; s|^POSTGRES_USER=.*|POSTGRES_USER=calendsoso|; s|^EMAIL_FROM=.*|EMAIL_FROM=$email|; s|^EMAIL_SERVER_HOST=.*|EMAIL_SERVER_HOST=$mailserver|; s|^EMAIL_SERVER_USER=.*|EMAIL_SERVER_USER=$email|; s|^CALCOM_TELEMETRY_DISABLED=.*|CALCOM_TELEMETRY_DISABLED=1|" /var/www/docker/cal/"$domain"/.env || true && vim .env && read -p "Enter Port Number: " port && sed -i 's|- database-data:/var/lib/postgresql/data/|- ./database-data:/var/lib/postgresql/data/|' /var/www/docker/cal/"$domain"/docker-compose.yaml && sed -i "s|- 3000:3000|- $port:3000|" /var/www/docker/cal/"$domain"/docker-compose.yaml && sed -i '/# Optional use of Prisma Studio.*/,/# END SECTION: Optional use of Prisma Studio./d' /var/www/docker/cal/"$domain"/docker-compose.yaml && vim docker-compose.yaml && sudo certbot certonly --nginx -d "$domain" && echo -e "server {\n    if (\$host = $domain) {\n        return 301 https://\$host\$request_uri;\n    }\n            listen 80;\n            listen [::]:80;\n            server_name $domain;\n            return 404;\n}\n\nserver {\n        listen [::]:443 ssl;\n        listen 443 ssl;\n        server_name $domain ;\n\n    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;\n    include /etc/letsencrypt/options-ssl-nginx.conf;\n    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;\n\n    location / {\n        proxy_pass http://localhost:$port;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade \$http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n        proxy_set_header X-Forwarded-Host \$host;\n        proxy_set_header X-Forwarded-Port \$server_port;\n    }\n}" | sudo tee /etc/nginx/sites-available/"$domain" > /dev/null && sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && sudo systemctl reload nginx && docker compose up -d
```
== For Multi Instances Remove  The Following in `docker-compose.yaml`==
```yaml
volumes:
  database-data:

networks:
  stack:
    name: stack
    external: false

    container_name: database

    networks:
      - stack

      dockerfile: Dockerfile

      network: stack

    networks:
      - stack

    depends_on:
      - database
```
* * *
## Extra Enviroment Varriables 
```
EMAIL_FROM_NAME=
NEXT_PUBLIC_APP_NAME="acme.com"
NEXT_PUBLIC_SUPPORT_MAIL_ADDRESS="support@acme.com"
NEXT_PUBLIC_COMPANY_NAME="ACME inc."

```
# Install On Ubuntu
## [Using Postgres](https://matrix-org.github.io/synapse/latest/postgres.html#using-postgres)
1.  `apt update`
2.  `apt install sudo postgresql -y`
3.  `systemctl start postgresql`
4.  `passwd postgres`
5.  `su - postgres` 
### Postgres Commands
6.  `psql`
### Postgres User & Database Creation
8.  `CREATE DATABASE caldb;`
9.  `CREATE USER admin WITH PASSWORD 'strong-password';`
10.  `GRANT ALL PRIVILEGES ON DATABASE caldb TO admin;`
11.  `exit`
## Install Node JS (Version 16.X) & Install Cal
1. Install [Node](https://github.com/nodesource/distributions/blob/master/README.md#debinstall) version 16.X.
2. `npm install --global yarn`
2. `apt install git -y`
3. `git clone https://github.com/calcom/cal.com.git`
4. `mv cal.com/ /opt/`
5. `cd /opt/cal.com`
6. `yarn`
7. `vim .env`
## Customize the Environment File
```yml
NEXT_PUBLIC_WEBAPP_URL='http://localhost:3001'
NEXT_PUBLIC_WEBSITE_URL='http://localhost:3000'
NEXT_PUBLIC_CONSOLE_URL='http://localhost:3004'
NEXT_PUBLIC_EMBED_LIB_URL='http://localhost:3000/embed/embed.js'
NEXTAUTH_URL='http://localhost:3000'

NEXTAUTH_SECRET=''
# You can use: `openssl rand -base64 32` to generate one
CALENDSO_ENCRYPTION_KEY=''
# You can use: `openssl rand -base64 24` to generate one
DATABASE_URL='postgresql://<user>:<pass>@<db-host>:<db-port>/<db-name>'
```
8. `export NODE_OPTIONS="--max-old-space-size=8192"`
9. `yarn workspace @calcom/prisma db-deploy`
10. `yarn build`
## Create Service
1. `vim /etc/systemd/system/cal.service`
```yml
[Unit]
Description=Self Hosted Cal.com
After=network.target
[Service]
Type=simple
User=root
ExecStart=yarn start
WorkingDirectory=/opt/cal.com/apps/web
Restart=on-failure
[Install]
WantedBy=multi-user.target

```
## Nginx Config
```yaml
server {
    if ($host = example.com) {
        return 301 https://$host$request_uri;
    }
            listen 80;
            listen [::]:80;
            server_name example.com;
            return 404;
}

server {
        listen [::]:443 ssl;
        listen 443 ssl;
        server_name example.com ;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
    }
}
```
`rm -r packages/prisma/.env`
`npx prisma generate`
`npx prisma migrate deploy`
`npx prisma studio`
* * *
# Branding
Find The Docker Directory
`/var/lib/docker/overlay2/*/merged/calcom/apps/web/public/ `