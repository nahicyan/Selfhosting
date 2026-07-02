## Single Command With MAS
```bash
# Install prerequisites and add Matrix.org repository
sudo apt install -y lsb-release wget apt-transport-https && \
# Download Matrix.org GPG key
sudo wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg && \
# Add Matrix.org repository to apt sources
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/matrix-org.list && \
# Update package list
sudo apt update && \
# Install Matrix Synapse, PostgreSQL
sudo apt install matrix-synapse-py3 postgresql -y && \
# Prompt for domain names
read -p "Enter Domain Name: " domain && \
#read -p "Enter MAS Server Domain Name: " turndomain && \
read -p "Enter Mas Domain Name: " masdomain && \
#read -p "Enter RTC Domain Name: " turndomain && \
read -p "Enter RTC Domain Name: " rtcdomain && \
# Prompt for PostgreSQL password
read -sp "Enter PostgreSQL password for 'matrix' user: " postgres_password && \
# Promt for Mas Password
read -sp "Enter PostgreSQL password for 'mas' user: " mas_password && \
echo && \
# Generate random secrets for CLI, authentication, and registration
client_secret=$(openssl rand -base64 48) && \
matrix_secret=$(openssl rand -base64 48) && \
reg_secret=$(openssl rand -base64 48) && \
# Get public IP address
ip=$(curl -s https://api.ipify.org) && \
# Configure Matrix Synapse to bind only to IPv4 localhost
sudo sed -i "s/bind_addresses: \['::1', '127.0.0.1']/bind_addresses: ['127.0.0.1']/" /etc/matrix-synapse/homeserver.yaml && \
# Comment out default SQLite database configuration
sudo sed -i '/database:/,/    database: \/var\/lib\/matrix-synapse\/homeserver.db/ s/^/#/' /etc/matrix-synapse/homeserver.yaml && \
# Append custom configuration to homeserver.yaml (including PostgreSQL config with password, TURN config, upload size, etc.)
sudo bash -c "cat >> /etc/matrix-synapse/homeserver.yaml << EOL

#Custom-Config-Upload#
max_upload_size: 131072M
#Custom-Config-Registration#
#enable_registration: true
registration_shared_secret: \"$reg_secret\"
#Custom-Config-Postgres#
database:
  name: psycopg2
  args:
    user: matrix
    password: $postgres_password
    database: synapse
    host: localhost
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3
#Coturn-Turnserver-Config#
#turn_uris: [ \"turns:\$turndomain?transport=udp\", \"#turns:\$turndomain?transport=tcp\" ]
#turn_shared_secret: \"\$auth_secret\"
#turn_user_lifetime: 86400000
#turn_allow_guests: True
#Server-Name#
server_name: \"$domain\"
#Custom-Config-End#
EOL" && \
# Append MAS Matrix RTC configuration to homeserver.yaml
sudo bash -c "cat >> /etc/matrix-synapse/homeserver.yaml << EOL2
# === MAS Matrix RTC Experimental Features & Rate Control ===
experimental_features:
  # --- Federation & Sync Enhancements ---
  # MSC3266: Room summary API (knocking over federation)
  msc3266_enabled: true
  # MSC4222: sync v2 state_after support
  msc4222_enabled: true
  # MSC4140: delayed‐events for reliable call signalling
  msc4140_enabled: true
  # --- Sliding Sync & New Client Features ---
  # MSC4186: Sliding Sync for Element X
  sliding_sync: true
  # MSC4108: QR‐login rendezvous API
  msc4108_enabled: true
  # MSC4190: Appservice device management
  msc4190_enabled: true
  # MSC3202: bridge/device masquerading
  msc3202_device_masquerading: true
  # OIDC Delegation for Matrix Auth Service (MSC3861)
  msc3861:
    enabled: true
    issuer: \"https://$masdomain\"
    client_id: \"0000000000000000000SYNAPSE\"
    client_auth_method: client_secret_basic
    client_secret: \"$client_secret\"
    admin_token: \"$matrix_secret\"
    # Point directly at your local MAS instance:
    #introspection_endpoint: \"http://localhost:8086/oauth2/introspect\"
# Maximum allowed delay for sent events (per MSC4140)
max_event_delay_duration: 24h
# Rate‐control for key-sharing & heartbeats
rc_message:
  per_second: 0.5
  burst_count: 30
# Rate‐control for handling delayed events
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
EOL2" && \
# Obtain SSL certificates for both domains using Certbot
sudo certbot certonly --nginx -d "$domain" -d "$masdomain" -d "$rtcdomain" && \
# Create directory structure for MAS
sudo mkdir -p /var/www/docker/MAS/"$masdomain" && \
# Change to the MAS directory
cd /var/www/docker/MAS/"$masdomain" && \
# Generate initial MAS configuration file
docker run --rm ghcr.io/matrix-org/matrix-authentication-service:latest config generate > config.yaml && \
# Apply all modifications
# After generating config.yaml, run this command:
awk -v masdomain="$masdomain" -v domain="$domain" -v mas_password="$mas_password" -v matrix_secret="$matrix_secret" -v client_secret="$client_secret" 'BEGIN{in_matrix_block=0} /^  public_base:/{print "  public_base: https://" masdomain; next} /^  issuer:/{print "  issuer: https://" masdomain; next} /^  uri: postgresql:\/\/$/{print "  uri: postgresql://mas:" mas_password "@db:5432/mas"; next} /^matrix:$/{in_matrix_block=1; print $0; next} in_matrix_block==1{if(/^  homeserver:/){print "  homeserver: " domain; next} if(/^  secret:/){print "  secret: " matrix_secret; next} if(/^  endpoint:/){print "  endpoint: https://" domain; next} if(/^[^ ]/){in_matrix_block=0}} {print $0} END{print "clients:"; print "  - client_id: 0000000000000000000SYNAPSE"; print "    client_auth_method: client_secret_basic"; print "    client_secret: \"" client_secret "\""}' config.yaml > config.yaml.tmp && mv config.yaml.tmp config.yaml && \
sudo bash -c "cat > docker-compose.yml << EOL
services:
  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_USER=mas
      - POSTGRES_PASSWORD=$mas_password
      - POSTGRES_DB=mas
    volumes:
      - mas_db_data:/var/lib/postgresql/data
    restart: unless-stopped
  
  matrix-auth-service:
    image: ghcr.io/element-hq/matrix-authentication-service:latest
    container_name: matrix-auth-service
    environment:
      - MAS_CONFIG=/app/config/config.yaml
    ports:
      - \"8086:8080\"
      - \"8081:8081\"
    volumes:
      - ./config.yaml:/app/config/config.yaml:ro
    depends_on:
      - db
    restart: unless-stopped

volumes:
  mas_db_data:
EOL" && \
# Edit the generated config.yaml (manual step)
sudo vim config.yaml && \
# Create docker-compose.yml file (manual step)
sudo vim docker-compose.yml && \
# Validate the MAS configuration
docker run -v /var/www/docker/MAS/"$masdomain":/config ghcr.io/element-hq/matrix-authentication-service --config /config/config.yaml config check && \
# Obtain SSL certificate for MAS domain
sudo certbot certonly --nginx -d "$masdomain" && \
# Create nginx configuration for MAS domain (manual step)
sudo vim /etc/nginx/conf.d/"$masdomain".conf && \
# Reload nginx to apply new configuration
sudo systemctl reload nginx && \
# Start MAS container in detached mode
sudo docker compose up -d && \
# Create nginx configuration for the domain
sudo vim /etc/nginx/conf.d/"$domain".conf && \
# Enable the nginx site // Disabled For Newer Verison Of NGinx
# sudo ln -s /etc/nginx/conf.d/"$domain".conf /etc/nginx/sites-enabled/ && \
# Restart nginx
sudo systemctl restart nginx && \
# Start PostgreSQL service
sudo systemctl start postgresql && \
# Set password for postgres user
sudo passwd postgres && \
# Switch to postgres user
su - postgres && \
# Pause for user to complete PostgreSQL setup
read -p "Press enter to continue" && \
# Restart all services
sudo systemctl restart nginx matrix-synapse 
```

### Creating A User
Either open up registration through a config change , so users can register themselves, or go via the command line:
`docker compose exec matrix-auth-service mas-cli manage register-user`
🔒 Lock and deactivate a user
`docker compose exec matrix-auth-service mas-cli manage lock-user --deactivate username`

# Install Matrix Latest Version
```
sudo apt install -y lsb-release wget apt-transport-https
sudo wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" |
    sudo tee /etc/apt/sources.list.d/matrix-org.list
sudo apt update
sudo apt install matrix-synapse-py3
```


### Add [Custom Configurations](ttps://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html) & Secrets to [/etc/matrix-synapse/homeserver.yaml](https://element-hq.github.io/synapse/latest/usage/configuration/homeserver_sample_config.html)
```yml
# === Existing Custom Configurations ===
#Custom-Config-Upload#
max_upload_size: 131072M
#Custom-Config-Registration#
#enable_registration: true
registration_shared_secret: "ThisIsASharedSecret-ChangeMe"
#Custom-Config-Postgres#
database:
  name: psycopg2
  args:
    user: matrix
    password: ThisIsAPassWord-ChangeMe
    database: synapse
    host: localhost
    cp_min: 5
    cp_max: 10
    keepalives_idle: 10
    keepalives_interval: 10
    keepalives_count: 3
#Coturn-Turnserver-Config#
turn_uris: [ "turns:turn.example.com?transport=udp", "turns:turn.example.com?transport=tcp" ]
turn_shared_secret: "ThisIsASharedSecret-ChangeMe"
turn_user_lifetime: 86400000
turn_allow_guests: True
#Server-Name#
server_name: "example.com"
#Custom-Config-End#

# === MAS Matrix RTC Experimental Features & Rate Control ===

experimental_features:
  # --- Federation & Sync Enhancements ---
  # MSC3266: Room summary API (knocking over federation)
  msc3266_enabled: true
  # MSC4222: sync v2 state_after support
  msc4222_enabled: true
  # MSC4140: delayed‐events for reliable call signalling
  msc4140_enabled: true

  # --- Sliding Sync & New Client Features ---
  # MSC4186: Sliding Sync for Element X
  sliding_sync: true
  # MSC4108: QR‐login rendezvous API
  msc4108_enabled: true
  # MSC4190: Appservice device management
  msc4190_enabled: true
  # MSC3202: bridge/device masquerading
  msc3202_device_masquerading: true

  # OIDC Delegation for Matrix Auth Service (MSC3861)
  msc3861:
    enabled: true
    issuer: "https://masdomain"
    client_id: "0000000000000000000SYNAPSE"
    client_auth_method: client_secret_basic
    client_secret: "client_secret"
    admin_token: "matrix_secret"
    # Point directly at your local MAS instance:
    #introspection_endpoint: "http://localhost:8086/oauth2/introspect"

# Maximum allowed delay for sent events (per MSC4140)
max_event_delay_duration: 24h

# Rate‐control for key-sharing & heartbeats
rc_message:
  per_second: 0.5
  burst_count: 30

# Rate‐control for handling delayed events
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20


```

## Nginx Config For HomeServer
```
server {
    listen 80;
    listen [::]:80;

    server_name example.com;
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    # For the federation port
    listen 8448 ssl http2 default_server;
    listen [::]:8448 ssl http2 default_server;

        server_name example.com;
        #root /var/www/domain;
        #index index.html;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location ~ ^(/_matrix/client/v1/rendezvous|/_matrix/client/v3/login_with_qr|/_synapse/client|/_synapse/admin|/_matrix) {
        proxy_pass http://localhost:8008;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        client_max_body_size 32770M;
    }
    
    location /.well-known/matrix/client {
    	default_type application/json;
    	add_header Access-Control-Allow-Origin *;

    return 200 '{
      "m.server": {
        "base_url": "https://example.com"
      },
      "m.homeserver": {
        "base_url": "https://example.com"
      },
      "org.matrix.msc2965.authentication": {
        "issuer": "https://mas.example.com/",
        "account": "https://mas.example.com"
      },
      "org.matrix.msc4143.rtc_foci":[
      {
      "type": "livekit",
      "livekit_service_url": "https://rtc.example.com/livekit/jwt"
       }
      ]
    }';
}

    location /.well-known/matrix/server {
        return 200 '{"m.server": "example.com:443"}';
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
    }
   location /.well-known/element/element.json {
    default_type application/json;
    return 200 '{"call": {"widget_url": "https://call.element.io"}}';
    }
}

```

# Matrix Authentication Service (MAS)
```
read -p "Enter MAS domain name: " domain && sudo mkdir -p /var/www/docker/MAS/"$domain" && cd /var/www/docker/MAS/"$domain" && docker run --rm ghcr.io/matrix-org/matrix-authentication-service:latest config generate > config.yaml && sudo vim config.yaml && sudo vim docker-compose.yml && docker run -v /var/www/docker/MAS/"$domain":/config ghcr.io/element-hq/matrix-authentication-service --config /config/config.yaml config check && sudo certbot certonly --nginx -d "$domain" && sudo vim /etc/nginx/conf.d/"$domain".conf && sudo systemctl reload nginx && sudo docker compose up -d
```
### Install MAS using Docker
```
services:
  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_USER=mas_user
      - POSTGRES_PASSWORD=mas_password
      - POSTGRES_DB=mas
    volumes:
      - mas_db_data:/var/lib/postgresql/data
    restart: unless-stopped

  matrix-auth-service:
    image: ghcr.io/element-hq/matrix-authentication-service:latest
    container_name: matrix-auth-service
    environment:
      - MAS_CONFIG=/app/config/config.yaml
    ports:
      - "8086:8080"
      - "8081:8081"
    volumes:
      - ./config.yaml:/app/config/config.yaml:ro
    depends_on:
      - db
    restart: unless-stopped

volumes:
  mas_db_data:

```

## MAS Nginx Config
```
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name mas.example.com;

    ssl_certificate /etc/letsencrypt/live/mas.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mas.example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://localhost:8086;  # MAS listens on this port
    }
}
```

### Config.yaml
```yaml
http:
  listeners:
  - name: web
    resources:
    - name: discovery
    - name: human
    - name: oauth
    - name: compat
    - name: graphql
    - name: assets
    binds:
    - address: '[::]:8080'
    proxy_protocol: false
  - name: internal
    resources:
    - name: health
    binds:
    - host: localhost
      port: 8081
    proxy_protocol: false
  trusted_proxies:
  - 192.168.0.0/16
  - 172.16.0.0/12
  - 10.0.0.0/10
  - 127.0.0.1/8
  - fd00::/8
  - ::1/128
  public_base: https://$masdomain
  issuer: https://$masdomain
database:
  uri: postgresql://mas:$mas_password@db:5432/mas
  max_connections: 10
  min_connections: 0
  connect_timeout: 30
  idle_timeout: 600
  max_lifetime: 1800
email:
  from: '"Authentication Service" <root@localhost>'
  reply_to: '"Authentication Service" <root@localhost>'
  transport: blackhole
secrets:
  encryption: 81fca5bc2bddd31e8da0417aa465b10ce66fcbc2040f1a119eb62b7fece8d18a
  keys:
  - kid: vQ630lSzD1
    key: |
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA10I/5eEOmFLDSK13ncuspS9b62k9gwVYRz7zrqlMovUsrWu6
      EgQXtnEwCHT7AXxnY9fjaVl7fPU+7/dXr59FsriE7bcNjjkKvyRsjyWWp1LcMML4
      /vG1LEFxF9vzALhA+Mcto/DDLUnFKkMllvHLxshUTVK7eY074VXO3qolHi5HBfyQ
      08r2gVSVKc2SPBKbsquA7CfAbWM9uwvuT6aKsXsd+ROiwiDt5rpCZ8731WQXX1Kw
      AjjxcvxXDdpEeqhN5SlpSLN2hcu6iafUvKqhxA56uEFuMrSnzBSaha5H9HDR8b8F
      124EJB6mb1/oOfD1qdKQ5D1ZqhmcroFfGNTfQQIDAQABAoIBAGi/ST7AxIxlAbhV
      CTcVDH8ZS56DiLZAHJQW0xe0NKG7srD1EgeATFWwQJJs8lPnyJvySyxRqeDFqom1
      D8tbMtxkI/NVN1h084DN5bHGtcfYb2OfDPFqhyHw+mqE0nwQLTWiHth+6UsZccM+
      B4WrReEGTNePocDldDUTv2Xk38kOEXCX0R6LQtynDW7fTPqT/wcjpf/+qWt71cXm
      IK5wMkgLMkxtaEfpSeNsEPNtoBydrTdAtvEpPdC4k+tHnwpsj9amr9dNO0hHjQBG
      flbV5mN4qq5YSJH7V8riaM4Lz7/xxTU+mDNc6b4d196d+Vycisl8HcQmesKjX3es
      qEWxII0CgYEA5/n7NnhCJ8JSW0q/k3yz4oqN2qqwPoj8Z6WDaED0VbWkWqJwiey9
      +EzMOE1GP35pyxaERIxDDlEdIDHjI1O153AsLdSQ1dSaX/jfI+VQrbDCz00DlRH5
      omkc6vIJHu0+E8GcSkeL+yvvnxFBa6b6WJ34M4KLJ/i2Y/HDBRqZ5CcCgYEA7Y0P
      DtVatAxBqlvsEJG3/ZCLzruCXXR1VvDv+8H+7z+P0Ivig+6KKJPF8qr5M/Fei3fa
      6rH2oku3Ht/rIlLiOyXTzJaOUV6waIbJMxkoWcVTV6+DsdsgS7p2xOr0IHsf+1cY
      DX9ajoUnu2a1qF/k5uXLzyapOGMD/ACEdXGculcCgYEAz3mmdD40tQi4zgvZslir
      LqfLXdKh1RyB21WOZRULMwlFmQaF7uX9tnFBie2bMbineEuIOyLT6p8jlKLpyrPZ
      Eskhyk++xnDjLYkSUjGL6f0ZD32LAa3U/qxSf9O/0phPmC3m0gyRpzDRnQw63cS3
      TcDjt3Y/bZ2ly1f0m8EB+KsCgYBo/wsjzEu9/xjbGqwZmr7PNZ+F7b0uX3Ypym7Y
      QSPUTazcSagCFmI8kyxQGR/yxIG8dWpuh+ByVbMH04MTdb0G1a5q5DTdZFPmr4So
      sDr0itJOlIZKC4eX0UADw7HJ1YIKTrGT7bFyAwrPuxMZ6+C56eIOmpD7GlC9huEF
      JAVZGwKBgGK+6ZFDa9mYHJ8o+RSNNkd0xM/Lp1AIMQOtsDOOV03m/HE0a6IR/WRM
      V1kqlyJziBmHEwmIxFzJO6rVi8wwTNH8fQvsW5C7sQ0P+rG27rzkyRS5IGYJ/uHO
      V5tw3s4RhLtTEUC/d23SThHIDWv3uAd3zwLFFSWIFgisrPQP0g/G
      -----END RSA PRIVATE KEY-----
  - kid: aB5YoM39oX
    key: |
      -----BEGIN EC PRIVATE KEY-----
      MHcCAQEEIKxLhIXmVZxVvfc4E0FK2hGEUAWJkI4A7bwH48L7MMOboAoGCCqGSM49
      AwEHoUQDQgAEMK1ZBiPesk0ZV9L5qYSZVaDYno3b3CszCmuAZHMnyHDD+jllJ6q7
      BJ9EyGQQOf2aYdVGAgyBXrPJQdDHqRU2qA==
      -----END EC PRIVATE KEY-----
  - kid: G1rfakzRwX
    key: |
      -----BEGIN EC PRIVATE KEY-----
      MIGkAgEBBDCteStkXAWF/at+P56z2erP20Os+NbeqiU/7v1KYuWAXyp126WKxwUO
      FSMCdGHk8zygBwYFK4EEACKhZANiAATYbEy2Y3GL/2KL07GM76B1TNLPTBag0L5q
      QBm2YzWoMAw+BSxCN+UpnZRDsiXTtQZfG5dGsmzqmYaz/AhsbbJv4yYkq5Fuj5TF
      OR57T50qNrAi+VRW0H/sIvA5z3aOxjo=
      -----END EC PRIVATE KEY-----
  - kid: RwHpjmOvAj
    key: |
      -----BEGIN EC PRIVATE KEY-----
      MHQCAQEEIBo+QytbAGM8Iy9a90l1uH9npdz8gavWqIQdfrnQVLUboAcGBSuBBAAK
      oUQDQgAEQKVq7ba2bb41OyVy3djnkdY6QZIzUUuIKU782vrw/ktAzGLxKBNTfSQ9
      BwzZ2LtIFEXkPn7Y6mS3LbF6PzvB/Q==
      -----END EC PRIVATE KEY-----
passwords:
  enabled: true
  schemes:
  - version: 1
    algorithm: argon2id
  minimum_complexity: 3
matrix:
  homeserver: $domain
  secret: $matrix_secret
  endpoint: https://$domain
clients:
  - client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "$client_secret"

```



openssl rand -hex 96

https://willlewis.co.uk/blog/posts/deploy-element-call-backend-with-synapse-and-docker-compose/?utm_source=chatgpt.com

https://willlewis.co.uk/blog/posts/stronger-matrix-auth-mas-synapse-docker-compose/