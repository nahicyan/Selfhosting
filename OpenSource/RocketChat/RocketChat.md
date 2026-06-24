# [Install With Docker](https://docs.rocket.chat/docs/deploy-with-docker-docker-compose)

# ==⛔ MongDB 6+ Requires AVX Support ⛔==
# ==⛔ Ensure Client Max Body Size Is Updated On Nginx ⛔==

```bash
read -p "Enter domain name: " domain && \
mkdir -p /var/www/docker/rocketchat && \
cd /var/www/docker/rocketchat && \
git clone --depth 1 https://github.com/RocketChat/rocketchat-compose.git "$domain" && \
cd "$domain" && \
cp .env.example .env && \
vim .env  && \
vim compose.yml && \
docker compose -f compose.database.yml -f compose.yml up -d 
# docker compose -f compose.database.yml -f compose.monitoring.yml -f compose.yml up -d 

# Nginx Config
sudo certbot certonly --nginx -d "$domain" && \
vim /etc/nginx/sites-available/"$domain" && \
sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && \
sudo systemctl reload nginx
```
### [Rocket.Chat configuration](https://docs.rocket.chat/v1/docs/deploy-with-docker-docker-compose#securing-rocketchat-with-nginx-and-lets-encrypt)
```
RELEASE=latest
DOMAIN=localhost
ROOT_URL=http://localhost
LETSENCRYPT_ENABLED=false
LETSENCRYPT_EMAIL=demo@email.com
TRAEFIK_PROTOCOL=http
GRAFANA_DOMAIN=
GRAFANA_PATH=/grafana
GRAFANA_ADMIN_PASSWORD=your_secure_password
# Port on the host to bind to
HOST_PORT=3002

# With Seperate MongoDB
MONGO_URL=mongodb://<user>:<pass>@host1:27017,host2:27017,host3:27017/<databaseName>?replicaSet=<replicaSet>&ssl=true&authSource=admin

```

## Troubleshooting MongoDB Version
Since the latest Docker Compose Hasn't Updated the MongDB version of rocketchat to go along with version 8
We have to manually update it like so
Add or update in your `.env`:
```
MONGODB_VERSION=8.0.13
````
# Reverse Proxy Access (Nginx)
```
server {
     listen 443 ssl;
	 listen [::]:443 ssl;
     server_name chat.example.org; 
	 client_max_body_size 100G;
     ssl_certificate /etc/letsencrypt/live/chat.example.org/fullchain.pem; 
     ssl_certificate_key /etc/letsencrypt/live/chat.example.org/privkey.pem; 
     ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
     ssl_prefer_server_ciphers on;
     ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';

     root /usr/share/nginx/html;
     index index.html index.htm;

     # Make site accessible from http://localhost/
     server_name localhost;

     location / {
         proxy_pass http://localhost:3000/;
         proxy_http_version 1.1;
         proxy_set_header Upgrade $http_upgrade;
         proxy_set_header Connection "upgrade";
         proxy_set_header Host $http_host;
         proxy_set_header X-Real-IP $remote_addr;
         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
         proxy_set_header X-Forwarded-Proto http;
         proxy_set_header X-Nginx-Proxy true;
         proxy_redirect off;
     }
 }

 server {
     listen 80;
	 listen [::]:80;
     server_name chat.example.org; 

     return 301 https://$host$request_uri;
 }
```
***
## Backup & Migrate (Docker) 
`docker ps && read -p "Do you want to backup or restore? (backup/restore): " action && read -p "Enter domain name: " domain && read -p "Enter MongoDB container name: " container_name && { [[ "$action" == "backup" ]] && docker exec "$container_name" sh -c 'mongodump --archive' > "/RC-Mongo-${domain}-$(date +"%Y-%m-%d_%H-%M").dump"; } || { [[ "$action" == "restore" ]] && latest_backup=$(ls -t /RC-Mongo-${domain}-*.dump | head -n 1) && docker exec -i "$container_name" sh -c 'mongorestore --archive --drop' < "$latest_backup"; }
`

## Update Docker
#### Update Mongodb
1. `vim compose.yml`
2. Update The Version (X.X)
```yml
  mongodb:
    image: docker.io/bitnami/mongodb:${MONGODB_VERSION:-X.X} 
```
2. `docker compose down`
3.  `docker compose up -d`
#### Update Rocketchat
1. `docker pull registry.rocket.chat/rocketchat/rocket.chat:latest`
2. `docker compose stop rocketchat`
3. `docker compose rm rocketchat`
4. `docker compose up -d rocketchat`
# Installation
## [Manual Installation](https://docs.rocket.chat/quick-start/installing-and-updating/other-deployment-methods/manual-installation)
### [Find The Latest Release](https://github.com/RocketChat/Rocket.Chat/releases)
1. Install the **Supported Version** of [MongoDB](https://www.mongodb.com/docs/manual/administration/install-on-linux/) & [Node](https://github.com/nodesource/distributions/blob/master/README.md#debinstall) 
2. `sudo apt install nginx`
3. `sudo npm install -g inherits n`
4. `sudo ln -s /usr/bin/node /usr/local/bin/node`
5. `sudo apt install -y curl build-essential graphicsmagick`
6. `curl -L https://releases.rocket.chat/latest/download -o /tmp/rocket.chat.tgz`
7. `tar xzf /tmp/rocket.chat.tgz -C /tmp`
8. `cd /tmp/bundle/programs/server && npm install`
9. `cd ~/`
10. `sudo mv /tmp/bundle /var/www/Rocket.Chat`
11. `sudo useradd -M rocketchat && sudo usermod -L rocketchat`
12. `sudo chown -R rocketchat:rocketchat /var/www/Rocket.Chat`
13. `cd /lib/systemd/system/`
14. `echo -e "[Unit]\nDescription=The Rocket.Chat server\nAfter=network.target remote-fs.target nss-lookup.target nginx.service mongod.service\n[Service]\nExecStart=/usr/local/bin/node /var/www/Rocket.Chat/main.js\nStandardOutput=syslog\nStandardError=syslog\nSyslogIdentifier=rocketchat\nUser=rocketchat\n[Install]\nWantedBy=multi-user.target\n[Service]\nEnvironment=ROOT_URL=http://localhost:3000\nEnvironment=PORT=3000\nEnvironment=MONGO_URL=mongodb://localhost:27017/rocketchat?replicaSet=rs01\nEnvironment=MONGO_OPLOG_URL=mongodb://localhost:27017/local?replicaSet=rs01" | sudo tee rocketchat.service`
11. `sudo sed -i "s/^#replication:/replication:\n  replSetName: rs01/" /etc/mongod.conf`
12. `sudo systemctl daemon-reload`
13. `sudo systemctl enable mongod && sudo systemctl restart mongod`
14. `sleep 10`
15. `mongo --eval "printjson(rs.initiate())"`
16. `sudo systemctl enable rocketchat && sudo systemctl start rocketchat`

## [Nginx Reverse Proxy](https://docs.rocket.chat/quick-start/environment-configuration/configuring-ssl-reverse-proxy) ==Mandatory==
### Nginx Configuration
```yml
upstream rocketchat {
    server 127.0.0.1:3000;
}
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
	
    client_max_body_size 100G;

    error_log /var/log/nginx/rocketchat.access.log;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://rocketchat;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Nginx-Proxy true;

        proxy_redirect off;
    }
}
```
* * *
## [Rocket-Chat CTL](https://docs.rocket.chat/quick-start/installing-and-updating/rapid-deployment-methods/rocketchatctl)
1. Install Rocket-Chat CTL
`bash -c "$(curl https://install.rocket.chat)"`
`rocketchatctl install`
2. `systemctl daemon-reload`
### For Unsupported Distributions
`/usr/local/bin/rocketchatctl`

* * *
# Backup & Migrate
### Backup 
From Manual Install
``mongodump --archive > RC--`date +"%a-%m%d%y-%H-%M"`-mongo.dump``
## Migrate
* * *
# Config 
## Edit A Channel
Add `channel-settings` after the URL
## Remove Branding
### Login Page (Inspect The Element To Disable It)
#### RocketChat App

1. Last Updates
```css
.rcx-css-1qbnw9s img {
    max-width: 150%!important;
    height: 150%!important;
}

.rcx-css-1kba3lq {
    display:none!important;
  }

.rcx-css-k29f7k {
    display:none!important;
  }
.rcx-css-12gps4f {
    display:none!important;
  }
div[data-qa-id="homepage-add-users-card"] {
    display: none;
}
div[data-qa-id="homepage-create-channels-card"] {
    display: none;
}
div[data-qa-id="homepage-documentation-card"] {
    display: none;
}
div[data-qa-id="homepage-join-rooms-card"] {
    display: none;
}

```
2. Login Size & Align (Custom Script for Logged Out Users)
```javascript
document.querySelectorAll('.rcx-css-13sr1uc').forEach(el => {
  el.style.setProperty('max-height', '4.5rem', 'important');
  el.style.setProperty('margin-inline', '0.5rem', 'important');
});
document.querySelectorAll('.rcx-css-86fkv9').forEach(el => {
  el.style.setProperty('display', 'none', 'important');
});
document.querySelectorAll('p').forEach(element => {
    element.style.setProperty('display', 'none', 'important');
});

```
3. Content Block (Join Daily Meeting)
```html
<div class="rcx-card__header"><h4 id="e0uhs2x3" class="rcx-box rcx-box--full rcx-card__title rcx-css-2eyztw">Join The Daily Meeting</h4></div>
<div id="tamwrw22qp" class="rcx-box rcx-box--full rcx-card__body rcx-css-1brox57">Let's Stay Connected While We Work.</div>
<div class="rcx-card__controls">
    <a href="https://meet.landersinvestment.com/dailymeeting" target="_blank" class="rcx-box rcx-box--full rcx-button--medium rcx-button--primary rcx-button" style="background-color: #ff8000; color: white; margin-top: 20px;">
      <span class="rcx-button--content">Join</span>
    </a>
  </div>
```
V2
```
<div style="max-width: 980px; margin: 0 auto;">
  <!-- Top heading above both cards -->
  <div style="font-weight:700; font-size:1.05rem; margin: 0 0 10px 0;">
    Let's Stay Connected While We Work.
  </div>

  <!-- Two mini-cards in a responsive grid -->
  <div style="
    display:grid;
    grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    gap: 10px;
    align-items: stretch;
  ">
    <!-- Card 1 -->
    <div class="rcx-box" style="
      padding:10px;
      border-radius:8px;
      border:1px solid rgba(255,255,255,0.08);
      background: rgba(255,255,255,0.03);
    ">
      <div style="font-weight:600; font-size:.95rem; margin-bottom:6px;">
        Join The Daily Meeting of Landers Investment
      </div>
      <a
        href="https://meet.landersinvestment.com/dailymeeting"
         target="_blank" class="rcx-box rcx-box--full rcx-button--medium rcx-button--primary rcx-button" style="background-color: #ff8000; color: white; margin-top: 20px;">
        <span class="rcx-button--content">Join</span>
      </a>
    </div>

    <!-- Card 2 -->
    <div class="rcx-box" style="
      padding:10px;
      border-radius:8px;
      border:1px solid rgba(255,255,255,0.08);
      background: rgba(255,255,255,0.03);
    ">
      <div style="font-weight:600; font-size:.95rem; margin-bottom:6px;">
        Join The Daily Meeting of Shiny Homes
      </div>
      <a
        href="https://meet.landersinvestment.com/ShinyHomes-DailyMeeting"
         target="_blank" class="rcx-box rcx-box--full rcx-button--medium rcx-button--primary rcx-button" style="background-color: #D4A017; color: white; margin-top: 20px;">
        <span class="rcx-button--content">Join</span>
      </a>
    </div>
  </div>
</div>

```
#### Livechat (Inspect The Element To Disable It)
1. Add `/var/www/Rocket.Chat/programs/web.browser/app/livechat/5.chunk.f5b79.css`
2. `.form-field--required__PtZd6 .form-field__label__E9kkP {display:block; visibility:visible!important;}.form-field--required__PtZd6 .form-field__label__E9kkP:after {display:none!important;}.form-field__label__E9kkP {visibility: hidden;}.form-field__label__E9kkP:after {content:"Wait A Minute! Who Are You?"; visibility: visible; display:block;}.powered-by__ydftk {display:none;}`
#### Round & Grey Design Livechat
In  `6112.chunk.b6839.css`   Add The Following
  ```css
.message-bubble__puzVZ{border-radius: 10px!important;}.screen__inner__NZe6j{border-radius: 15px!important;}.avatar__image__oHtck{border-radius:50%!important;}.button__rX4Lp{border-radius: 10px!important;}.composer__Hnt\+d{border-radius: 10px!important;}.text-input__b8HUv{border-radius: 10px!important;}/*.message-bubble__puzVZ{background-color:#f2f2f2!important;}*/
```
`background-color: var(--receiver-bubble-background-color,#f7f8fa);`  >  `background-color: var(--receiver-bubble-background-color,#f2f2f2);`
#### Change The Position & Size Of The RocketChat Logo
Layout > Custom Script > Custom Script for Logged Out Users
```
document.querySelectorAll('.rcx-css-13sr1uc').forEach(el => {
  el.style.setProperty('max-height', '4.5rem', 'important');
  el.style.setProperty('margin-inline', '0.5rem', 'important');
});

```

# Troubleshoot
## LiveChat Not showing up.
1. Enable iframe in Settings > General 
2.==Make sure LiveChat Installation Script Includes HTTPS==
Ubuntu
`sudo wget http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
sudo dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb`
## [Webview In Mobile Login (SSO On Top)](https://github.com/RocketChat/Rocket.Chat.ReactNative/issues/5124)
1. Toggle iframe in Settings > Accounts > iframe, Restart The Server
2. Toggle Until iframe is disabled in > Settings > Accounts > iframe | Restart The Server