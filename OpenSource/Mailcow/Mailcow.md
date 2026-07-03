# ==⛔ Think Twice Before Adding Any IPv6 AAAA Records ⛔==
# Disable IPV6 Until Reboot
```
# Disable IPv6 on all interfaces for this boot only
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
# Optional: also disable on the loopback device
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

# Verify (0 = enabled, 1 = disabled)
sysctl net.ipv6.conf.all.disable_ipv6
ip -6 addr show

```
# [Installation](https://docs.mailcow.email/)
```bash
# Removing Exim4
sudo systemctl stop exim4 && \
sudo systemctl disable --now exim4 && \
sudo apt-get update && \
sudo apt-get purge -y 'exim4*' && \
sudo apt-get autoremove -y && \
# Prompt user for domain name
read -p "Enter domain name(No Subdomain): " domain && \
# Update package lists
sudo apt update && \
# Upgrade installed packages
sudo apt upgrade && \
# Install required packages
sudo apt install git vim ufw jq && \
# Get server's public IP address
ip=$(curl -s https://api.ipify.org) && \
# Change to /etc directory
cd /etc/ && \
# Set hostname to "mail"
echo -e "mail" | sudo tee hostname && \
# Add mail server entries to hosts file
sudo sh -c "echo '\n127.0.0.1 mail.$domain mail localhost localhost.localdomain\n$ip mail.$domain mail' >> /etc/hosts" && \
# Allow mail and web service ports through firewall
sudo ufw allow proto tcp from any to any port 25,465,587,143,993,110,995,4190,80,443 comment 'Mail and Web Services' && \
# Reload firewall rules
sudo ufw reload && \
# Restart UFW service
sudo systemctl restart ufw && \
# Install fail2ban for intrusion prevention
sudo apt install fail2ban -y && \
# Create mailcow directory
sudo mkdir -p /opt/mailcow/"$domain" && \
# Change to mailcow directory
cd /opt/mailcow/"$domain" && \
# Clone mailcow repository
sudo git clone https://github.com/mailcow/mailcow-dockerized && \
# Change to mailcow-dockerized directory
cd mailcow-dockerized && \
# Generate mailcow configuration
sudo ./generate_config.sh && \
# Edit mailcow configuration file
sudo vim mailcow.conf && \
# Edit docker-compose configuration
vim docker-compose.yml && \
# Edit nginx site configuration
sudo vim /etc/nginx/sites-available/mail.$domain && \
# Obtain SSL certificate for mail subdomain
sudo certbot certonly --nginx -d mail.$domain && \
# Reload nginx configuration
sudo systemctl reload nginx && \
# Enable nginx site by creating symlink
sudo ln -s /etc/nginx/sites-available/mail.$domain /etc/nginx/sites-enabled/ && \
# Restart nginx service
sudo systemctl restart nginx && \
# Start mailcow containers in detached mode
docker compose up -d && \
# Prompt user for reboot confirmation
read -p "Would you like to reboot now? (y/n): " reboot_choice && \
# Reboot system if user confirms
[[ "$reboot_choice" == [Yy] ]] && sudo systemctl reboot
```

# ==⛔ MAKE SURE NO IPv6 AAAA RECORDS ON REGISTRAR ⛔==

# ==⛔ CONSIDER DISABLING IPv6 FROM DOCKER ⛔==

### 1. Modify docker-compose.yml

Change enable_ipv6: true to enable_ipv6: false and comment out the IPv6 subnet:

```
networks:
  mailcow-network:
    [...]
    enable_ipv6: true # <<< set to false
    ipam:
      driver: default
      config:
        - subnet: ${IPV4_NETWORK:-172.22.1}.0/24
        - subnet: ${IPV6_NETWORK:-fd4d:6169:6c63:6f77::/64} # <<< comment out with #
    [...]

#### Docker Compose Config
 Bind HTTPS to 127.0.0.1 on port 8443 and HTTP to 127.0.0.1 on port 8080
```
## Mailcow Config
 ```
# When Nginx is in the same machine
HTTP_BIND=127.0.0.1
HTTP_PORT=8080
HTTPS_BIND=127.0.0.1
HTTPS_PORT=8443

# Redirect HTTP connections to HTTPs -y/n
HTTP_REDIRECT=n # MUST BE N HERE
```
```
# When Nginx is in a different machine???
HTTP_BIND=0.0.0.0
HTTP_PORT=8080
HTTPS_BIND=0.0.0.0
HTTPS_PORT=8443
```
* * *
## Nginx
```yml
server {
  listen 80;
  listen [::]:80;
  server_name mail.example.com autodiscover.* autoconfig.*;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl http2;
  #listen [::]:443 ssl http2; # Make Sure This is Uncommented For IPv6
  server_name mail.example.com autodiscover.* autoconfig.*;

  ssl_certificate /etc/letsencrypt/live/mail.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/mail.example.com/privkey.pem;
  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:50m;
  ssl_session_tickets off;

  # See https://ssl-config.mozilla.org/#server=nginx for the latest ssl settings recommendations
  # An example config is given below
  ssl_protocols TLSv1.2;
  ssl_ciphers HIGH:!aNULL:!MD5:!SHA1:!kRSA;
  ssl_prefer_server_ciphers off;

  location /Microsoft-Server-ActiveSync {
    proxy_pass http://127.0.0.1:8080/Microsoft-Server-ActiveSync;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_connect_timeout 75;
    proxy_send_timeout 3650;
    proxy_read_timeout 3650;
    proxy_buffers 64 512k; # Needed since the 2022-04 Update for SOGo
    client_body_buffer_size 512k;
    client_max_body_size 0;
  }

  location / {
    proxy_pass http://127.0.0.1:8080/;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 0;
  # The following Proxy Buffers has to be set if you want to use SOGo after the 2022-04 (April 2022) Update
  # Otherwise a Login will fail like this: https://github.com/mailcow/mailcow-dockerized/issues/4537
    proxy_buffer_size 128k;
    proxy_buffers 64 512k;
    proxy_busy_buffers_size 512k;
  }
}
```
***
## Backup 
## First Backup > Then Update > Then Backup Again > 
### [Mail Directory](https://docs.mailcow.email/backup_restore/b_n_r-backup_restore-maildir/)
`read -p "Enter domain name(NO MAIL SUBDOMAIN): " domain && cd /opt/mailcow/"$domain"/mailcow-dockerized  && docker run --rm -i -v $(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/var/vmail" }}{{ .Name }}{{ end }}{{ end }}' $(docker compose ps -q dovecot-mailcow)):/vmail -v ${PWD}:/backup debian:bullseye-slim tar cvfz /backup/backup_vmail.tar.gz /vmail`
### Backup All 
Go to The Docker Folder And Run
`THREADS=4 ./helper-scripts/backup_and_restore.sh backup all`

### Restore All
`THREADS=4 ./helper-scripts/backup_and_restore.sh restore`
## Manual Configuration
| Protocol | Security    | Hostname           | Port |
|----------|-------------|--------------------|------|
| IMAP     | STARTTLS    | mailcow hostname   | 143  |
| IMAPS    | SSL         | mailcow hostname   | 993  |
| POP3     | STARTTLS    | mailcow hostname   | 110  |
| POP3S    | SSL         | mailcow hostname   | 995  |
| SMTP     | STARTTLS    | mailcow hostname   | 587  |
| SMTPS    | SSL         | mailcow hostname   | 465  |

* * *
## SOGO Custom Logo & Favicon
1. SCP The LOGO
`scp *.svg root@example.com:/sogo-full.svg`
`scp *.svg root@example.com:/custom-favicon.ico`
3. Move & Rename
`cd / && mv sogo-full.svg custom-favicon.ico /opt/mailcow/*/mailcow-dockerized/data/conf/sogo/`
4. Restart
`systemctl reboot`

## Transfer Email Between MailServers (IMAP Sync)
```bash
sudo apt install -y git make cpanminus build-essential libssl-dev libio-socket-ssl-perl libnet-ssleay-perl libauthen-ntlm-perl libterm-readkey-perl libfile-copy-recursive-perl libcgi-pm-perl libpar-packer-perl libmodule-scandeps-perl libencode-imaputf7-perl libfile-tail-perl libwww-perl libproc-processtable-perl libregexp-common-perl libtest-deep-perl libcrypt-openssl-rsa-perl libdata-uniqid-perl libdist-checkconflicts-perl libio-socket-inet6-perl libio-tee-perl libjson-perl libjson-webtoken-perl libmail-imapclient-perl libparse-recdescent-perl libsys-meminfo-perl libtest-fatal-perl libtest-mock-guard-perl libtest-mockobject-perl libtest-pod-perl libtest-requires-perl libunicode-string-perl && git clone https://github.com/imapsync/imapsync.git && cd imapsync && make testp && sudo make install && imapsync --version

```

```bash
imapsync \
   --host1 mail.server_from.com --port1 993 --user1 user1@server_from.com --password1 'password_from' \
   --host2 mail.server_to.com --port2 993 --user2 user1@server_to.com --password2 'password_to' \
   --ssl1 --ssl2 --syncinternaldates --useheader "Message-ID" --skipsize --addheader

```

# Enable user to change password in SOGo
Change SOGoPasswordChangeEnabled = YES in /opt/mailcow-dockerized/data/conf/sogo/sogo.conf. Must Reboot After.

###
# Custom Certificate ?
1. First, let's check the current mailcow certificate status:

```
cd /opt/mailcow/example.com/mailcow-dockerized
docker compose exec -it postfix-mailcow openssl s_client -connect localhost:587 -starttls smtp | openssl x509 -noout -dates
```


# Create a script to copy the certificates and set proper permissions
```
cat > /opt/mailcow/example.com/mailcow-dockerized/update-certs.sh << 'EOF'
#!/bin/bash
DOMAIN="mail.example.com"  # Replace with your actual domain
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
MAILCOW_DIR="/opt/mailcow/example.com/mailcow-dockerized"
````

# Copy certificates to mailcow SSL directory
```
cp $CERT_DIR/fullchain.pem $MAILCOW_DIR/data/assets/ssl/cert.pem
cp $CERT_DIR/privkey.pem $MAILCOW_DIR/data/assets/ssl/key.pem
````

# Set proper permissions
chown -R 82:82 $MAILCOW_DIR/data/assets/ssl/cert.pem $MAILCOW_DIR/data/assets/ssl/key.pem

# Restart mailcow services to apply new certificates
cd $MAILCOW_DIR
docker compose restart
EOF

# Make the script executable
chmod +x /opt/mailcow/example.com/mailcow-dockerized/update-certs.sh

# Run the script
sudo /opt/mailcow/example.com/mailcow-dockerized/update-certs.sh

