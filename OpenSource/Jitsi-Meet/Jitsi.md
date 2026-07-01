# [Jitsi](https://jitsi.org/)

# Installation

## Install With Docker
```bash 
# Prompt user for domain name input
read -p "Enter Domain Name: " domain && \

# Prompt user for company/entity name input
read -p "Enter Entity name: " company && \

# Prompt user for website link input
read -p "Enter Site Domain Only: " site && \

# Prompt user for timezone input
read -p "Enter Timezone: " timezone && \

# Install unzip package for archive extraction
apt install unzip && mkdir -p /var/www/docker/jitsi && \

# Navigate to the jitsi docker directory
cd /var/www/docker/jitsi && \

# Create a directory named after the domain
mkdir -p "$domain" && \

# Enter the domain-specific directory
cd "$domain" && \

# Prompt user to paste the download link from Jitsi releases page
read -p "Paste The Tar Link https://github.com/jitsi/docker-jitsi-meet/releases/latest/ : " link && \

# Download the Jitsi Docker release archive
wget $link && \

# Extract the downloaded tarball
tar -zxf stable-*.tar.gz && \

# Enable dotglob to include hidden files in glob patterns
shopt -s dotglob && \

# Move all extracted files (including hidden) to current directory
mv docker-jitsi-meet-stable-*/* . && \

# Copy the example environment file to create the actual .env file
cp env.example .env && \

# Configure .env file: change ports, set timezone, public URL, enable whiteboard, etherpad, recording, and audio/video defaults
sudo sed -i \
  -e "s|^HTTP_PORT=8000|HTTP_PORT=8008|" \
  -e "s|^HTTPS_PORT=8443|HTTPS_PORT=8444|" \
  -e "s|^TZ=UTC|TZ=$timezone|" \
  -e "s|#PUBLIC_URL=https://meet.example.com:\${HTTPS_PORT}|PUBLIC_URL=https://$domain|" \
  -e "/^HTTPS_PORT=8444/a JVB_COLIBRI_PORT=8084" \
  -e "/^JVB_COLIBRI_PORT=8084/a START_AUDIO_MUTED=9999" \
  -e "/^START_AUDIO_MUTED=9999/a START_VIDEO_MUTED=9999" \
  -e "/^START_VIDEO_MUTED=9999/a START_WITH_AUDIO_MUTED=false" \
  -e "/^START_WITH_AUDIO_MUTED=false/a START_WITH_VIDEO_MUTED=false" \
  -e "/^START_WITH_VIDEO_MUTED=false/a ENABLE_RECORDING=1" \
  -e "/^ENABLE_RECORDING=1/a IGNORE_CERTIFICATE_ERRORS=true" \
  -e "/^IGNORE_CERTIFICATE_ERRORS=true/a CHROMIUM_FLAGS=--use-fake-ui-for-media-stream,--start-maximized,--kiosk,--enabled,--autoplay-policy=no-user-gesture-required,--ignore-certificate-errors,--no-sandbox,--disable-dev-shm-usage,--disable-gpu" \
  -e "s|^#WHITEBOARD_COLLAB_SERVER_URL_BASE=http://whiteboard.meet.jitsi|WHITEBOARD_COLLAB_SERVER_URL_BASE=http://whiteboard.meet.jitsi|" \
  -e "s|^#ETHERPAD_URL_BASE=http://etherpad.meet.jitsi:9001|ETHERPAD_URL_BASE=http://etherpad.meet.jitsi:9001|" \
  -e "/^CHROMIUM_FLAGS=/a DESKTOP_SHARING_FRAMERATE_AUTO=false" \
  -e "/^DESKTOP_SHARING_FRAMERATE_AUTO=false/a DESKTOP_SHARING_FRAMERATE_MIN=5" \
  -e "/^DESKTOP_SHARING_FRAMERATE_MIN=5/a DESKTOP_SHARING_FRAMERATE_MAX=30" \
  -e "/^DESKTOP_SHARING_FRAMERATE_MAX=30/a VIDEOQUALITY_PREFERRED_CODEC=VP9" \
  -e "/^VIDEOQUALITY_PREFERRED_CODEC=VP9/a VIDEOQUALITY_BITRATE_VP9_SS_HIGH=5000000" \
  -e "/^VIDEOQUALITY_BITRATE_VP9_SS_HIGH=5000000/a VIDEOQUALITY_BITRATE_VP8_SS_HIGH=5000000" \
  -e "/^VIDEOQUALITY_BITRATE_VP8_SS_HIGH=5000000/a VIDEOQUALITY_BITRATE_H264_SS_HIGH=5000000" \
  -e "/^VIDEOQUALITY_BITRATE_H264_SS_HIGH=5000000/a VIDEOQUALITY_BITRATE_AV1_SS_HIGH=5000000" \
  .env

# Open .env file for manual editing/review
vim .env && \

# Open docker-compose.yml for manual editing/review
vim docker-compose.yml && \

# Generate random passwords for Jitsi components
./gen-passwords.sh && \

# Create required configuration directories for all Jitsi services
mkdir -p ~/.jitsi-meet-cfg/{web/images,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri} && \

# Create custom Jitsi config with video/audio quality settings
cat > ~/.jitsi-meet-cfg/web/custom-config.js <<'EOF'
(function () {
  if (typeof config === 'undefined') return;

  // Camera settings (these don't affect screenshare)
  config.resolution = 1080;
  config.constraints = config.constraints || {};
  config.constraints.video = config.constraints.video || {};
  config.constraints.video.height = { ideal: 1080, max: 1440, min: 480 };

  config.enableNoisyMicDetection = true;

  // Screenshare frame rate (belt-and-suspenders with .env)
  config.desktopSharingFrameRate = { min: 5, max: 30 };

  // Codec preference — VP9 first for SVC screenshare
  config.videoQuality = config.videoQuality || {};
  config.videoQuality.codecPreferenceOrder = ['VP9', 'VP8', 'H264'];

  // VP9 bitrate tiers with 5 Mbps screenshare cap
  config.videoQuality.vp9 = config.videoQuality.vp9 || {};
  config.videoQuality.vp9.low = 100000;
  config.videoQuality.vp9.standard = 300000;
  config.videoQuality.vp9.high = 1200000;
  config.videoQuality.vp9.fullHd = 2500000;
  config.videoQuality.vp9.ssHigh = 5000000;

  // VP8 fallback bitrates
  config.videoQuality.vp8 = config.videoQuality.vp8 || {};
  config.videoQuality.vp8.low = 200000;
  config.videoQuality.vp8.standard = 500000;
  config.videoQuality.vp8.high = 1500000;
  config.videoQuality.vp8.fullHd = 3000000;
  config.videoQuality.vp8.ssHigh = 5000000;
})();
EOF

# Create custom interface config with company branding
cat > ~/.jitsi-meet-cfg/web/custom-interface_config.js <<EOF
(function () {
  if (typeof interfaceConfig === 'undefined') return;
  interfaceConfig.APP_NAME = '${company}';
  interfaceConfig.DEFAULT_REMOTE_DISPLAY_NAME = '${company} Guest';
  interfaceConfig.BRAND_WATERMARK_LINK = 'https://${site}';
  interfaceConfig.JITSI_WATERMARK_LINK = 'https://${site}';
})();
EOF


# Open custom interface config for manual editing/review
vim ~/.jitsi-meet-cfg/web/custom-interface_config.js && \

# Pull all required Docker images for Jitsi
docker compose pull && \

# Prompt user to copy custom content before proceeding
echo "Copy your custom Content and press 'R' to continue." && \

# Wait for user confirmation before continuing
while read -r -p "Press 'R' to proceed: " input && [[ "$input" != "R" && "$input" != "r" ]]; do echo "Invalid input. Press 'R'."; done && \

# Start all Jitsi containers including etherpad, jibri, and whiteboard services
docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml up -d && \

# Obtain SSL certificate from Let's Encrypt for the domain
sudo certbot certonly --nginx -d "$domain" && \

# Open nginx site configuration for manual editing
vim /etc/nginx/sites-available/"$domain" && \

# Enable the nginx site by creating symlink and reload nginx
sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && sudo systemctl reload nginx
```
All Docker Links
```
			# Custom Mounts
			- ${CONFIG}/web/images/favicon.svg:/usr/share/jitsi-meet/images/favicon.svg:ro
			- ${CONFIG}/web/images/watermark.svg:/usr/share/jitsi-meet/images/watermark.svg:ro
			- ${CONFIG}/web/images/welcome-background.png:/usr/share/jitsi-meet/images/welcome-background.png:ro
			- ${CONFIG}/web/css/all.css:/usr/share/jitsi-meet/css/all.css:ro
			# Consider Generating Newer Libs (must match the image version)
			- ${CONFIG}/web/title.html:/usr/share/jitsi-meet/title.html:ro
			- ${CONFIG}/web/lang/main.json:/usr/share/jitsi-meet/lang/main.json:ro
			- ${CONFIG}/web/libs/app.bundle.min.js:/usr/share/jitsi-meet/libs/app.bundle.min.js:ro
			- ${CONFIG}/web/libs/app.bundle.min.js.map:/usr/share/jitsi-meet/libs/app.bundle.min.js.map:ro

```

### Create User
`prosodyctl --config /config/prosody.cfg.lua register Username meet.jitsi Password`
### Remove User
`prosodyctl --config /config/prosody.cfg.lua unregister Username meet.jitsi`
3. Nginx Config 
```yml
server {
    listen 80;
    server_name meet.example.com;
    access_log off;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name meet.example.com;
    access_log off;

    ssl_certificate /etc/letsencrypt/live/meet.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meet.example.com/privkey.pem;

    location / {
        add_header Cache-Control no-cache;

        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $http_host;
        proxy_pass http://127.0.0.1:8008/;
    }
    
    location /xmpp-websocket {
    proxy_pass https://localhost:8444;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    }

    location /colibri-ws {
    proxy_pass https://localhost:8444;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    }
    
}
```
***
## Start 
`docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml up -d`
## Stop
`docker compose -f docker-compose.yml -f etherpad.yml -f jibri.yml -f whiteboard.yml down`
***
## Customization
1. Install the **Supported Version** of [Node](https://github.com/nodesource/distributions/blob/master/README.md#debinstall) 
2. `sudo apt-get install -y git make build-essential && mkdir -p /var/www/docker/jitsi && cd /var/www/docker/jitsi && git clone https://github.com/jitsi/jitsi-meet && cd jitsi-meet && echo "Copy your custom Code and press 'R' to continue." && while read -r -p "Press 'R' to proceed: " input && [[ "$input" != "R" && "$input" != "r" ]]; do echo "Invalid input. Press 'R'."; done && npm install && make
`


1. Addition For Current `interface_config.js`
```js
    AUDIO_LEVEL_PRIMARY_COLOR: 'rgba(255,255,255,0.4)',
    AUDIO_LEVEL_SECONDARY_COLOR: 'rgba(255,255,255,0.2)',

    AUTO_PIN_LATEST_SCREEN_SHARE: 'remote-only',

    CLOSE_PAGE_GUEST_HINT: false, // A html text to be shown to guests on the close page, false disables it

    DEFAULT_BACKGROUND: '#040404',
    DEFAULT_WELCOME_PAGE_LOGO_URL: 'images/watermark.svg',

    DISABLE_DOMINANT_SPEAKER_INDICATOR: false,


    DISABLE_JOIN_LEAVE_NOTIFICATIONS: false,

    DISABLE_PRESENCE_STATUS: false,

    /**
     * Whether the ringing sound in the call/ring overlay is disabled. If
     * {@code undefined}, defaults to {@code false}.
     *
     * @type {boolean}
     */
    DISABLE_RINGING: false,

    /**
     * Whether the speech to text transcription subtitles panel is disabled.
     * If {@code undefined}, defaults to {@code false}.
     *
     * @type {boolean}
     */
    DISABLE_TRANSCRIPTION_SUBTITLES: false,

    DISABLE_VIDEO_BACKGROUND: false,

    DISPLAY_WELCOME_FOOTER: true,
    DISPLAY_WELCOME_PAGE_ADDITIONAL_CARD: false,
    DISPLAY_WELCOME_PAGE_CONTENT: false,
    DISPLAY_WELCOME_PAGE_TOOLBAR_ADDITIONAL_CONTENT: false,

    ENABLE_DIAL_OUT: true,

    FILM_STRIP_MAX_HEIGHT: 120,

    GENERATE_ROOMNAMES_ON_WELCOME_PAGE: true,

    HIDE_INVITE_MORE_HEADER: false,

    LANG_DETECTION: true, // Allow i18n to detect the system language
    LOCAL_THUMBNAIL_RATIO: 16 / 9, // 16:9

    /**
     * Maximum coefficient of the ratio of the large video to the visible area
     * after the large video is scaled to fit the window.
     *
     * @type {number}
     */
    MAXIMUM_ZOOMING_COEFFICIENT: 1.3,

    /**
     * Whether the mobile app Jitsi Meet is to be promoted to participants
     * attempting to join a conference in a mobile Web browser. If
     * {@code undefined}, defaults to {@code true}.
     *
     * @type {boolean}
     */
    MOBILE_APP_PROMO: true,
    OPTIMAL_BROWSERS: [ 'chrome', 'chromium', 'firefox', 'electron', 'safari', 'webkit' ],

    POLICY_LOGO: null,
    PROVIDER_NAME: 'Jitsi',

    /**
     * If true, will display recent list
     *
     * @type {boolean}
     */
    RECENT_LIST_ENABLED: true,
    REMOTE_THUMBNAIL_RATIO: 1, // 1:1

    SETTINGS_SECTIONS: [ 'devices', 'language', 'moderator', 'profile', 'calendar', 'sounds', 'more' ],

    SHOW_BRAND_WATERMARK: false,

    SHOW_CHROME_EXTENSION_BANNER: false,

    SHOW_JITSI_WATERMARK: true,
    SHOW_POWERED_BY: false,
    SHOW_PROMOTIONAL_CLOSE_PAGE: false,

    UNSUPPORTED_BROWSERS: [],

    VERTICAL_FILMSTRIP: true,

    VIDEO_LAYOUT_FIT: 'both',

    VIDEO_QUALITY_LABEL_DISABLED: false,

    makeJsonParserHappy: 'even if last key had a trailing comma'
```

2. Change Enviroment Parameters
```yml
# Exposed HTTP port
HTTP_PORT=8008

# Exposed HTTPS port
HTTPS_PORT=8444

# JVB colibri rest API port
JVB_COLIBRI_PORT=8084


# System time zone
TZ=UTC

# Public URL for the web service (required)
PUBLIC_URL=https://meet.example.com
#----------------------AUTH-----------------------------#
# Enable Recording
ENABLE_RECORDING=1
# Enable Authentication
ENABLE_AUTH=1
# Enable Auto Login
ENABLE_AUTO_LOGIN=1
# Enable Guests (Keep It 1 Unless It's a Private Server)
ENABLE_GUESTS=1
# Use The commands Below
AUTH_TYPE=internal
#----------------------AUTH-----------------------------#
```

### 1. Images
Docker Link Location `/root/.jitsi-meet-cfg/web/images`
Bare Metal Location `/var/www/docker/jitsi/jitsi-meet`
Files `favicon.svg` `watermark.svg` `welcome-background.png`
Docker Link
```
			- ${CONFIG}/web/images/favicon.svg:/usr/share/jitsi-meet/images/favicon.svg
            - ${CONFIG}/web/images/watermark.svg:/usr/share/jitsi-meet/images/watermark.svg
            - ${CONFIG}/web/images/welcome-background.png:/usr/share/jitsi-meet/images/welcome-background.png
```
### 2. Translations & Titles
#### Bare Metal 
1. [Follow This](#customization) Complete The Following Step Before Pressing 'R'
2. Make The Necessary Changes In `/var/www/docker/jitsi/jitsi-meet/lang/main.json`
```
"welcomepage": {
    "appDescription": "Your Description",
    "headerTitle": "Your Title",
    "headerSubtitle": "Your Subtitle",
    "title": "Your Title"
	  "jitsiOnMobile": "Your App – download these apps and start a meeting from anywhere",
}
```
3. Press & Generate / For Docker - **Search & Replace**
`/var/www/docker/jitsi/jitsi-meet/libs/app.bundle.min.js`
`/var/www/docker/jitsi/jitsi-meet/libs/app.bundle.min.js.map`
For Docker - **Search & Replace**
4. Generate & Edit `~/.jitsi-meet-cfg/web/custom-interface_config.js`
```
var interfaceConfig = {
    // Replace 'Your Company Name' with your desired name
    APP_NAME: 'Your Company Name',

    // Change default display name to 'Fellow User'
    DEFAULT_REMOTE_DISPLAY_NAME: 'Fellow User',

    // Optionally, add a link to your company website
    BRAND_WATERMARK_LINK: '',

    // Update the URL to your desired logo (default is 'images/watermark.svg')
    DEFAULT_LOGO_URL: 'images/watermark.svg',
    DEFAULT_WELCOME_PAGE_LOGO_URL: 'images/watermark.svg',
    JITSI_WATERMARK_LINK: 'https://yoursite.com',
    SHOW_BRAND_WATERMARK: true,
};
```
5. Edit, Search & Replace 
```
"welcomepage": {
    "appDescription": "Your Description",
    "headerTitle": "Your Title",
    "headerSubtitle": "Your Subtitle",
    "title": "Your Title"
}
```
Bare Metal Location `/var/www/docker/jitsi/jitsi-meet/title.html`
### 3. CSS 
1. [Follow This](#customization) Complete The Following Step Before Pressing 'R'
2. Edit SCSS File Located In Bare Metal  `/var/www/docker/jitsi/jitsi-meet/css`
3. Edit In the following Scheme

# Troubleshoot 
## VideoMute: False Not Working
#### Does Docker see your override file?
`docker compose exec web ls -l /config/custom-config.js`

#### Is it merged into what Nginx serves as /config.js?
`docker compose exec web grep -nE "startWith(Audio|Video)Muted|startSilent|startAudioMuted|startVideoMuted" /config/config.js`

Then Tweak
`~/.jitsi-meet-cfg/web/custom-config.js`
`~/.jitsi-meet-cfg/web/config.js `
Until You Get Desired Output

## [Running behind NAT or on a LAN environment](https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker/#running-behind-nat-or-on-a-lan-environment)
## Split horizon

If you are running in a split horizon environemt (LAN internal clients connect to a local IP and other clients connect to a public IP) you can specify multiple advertised IPs by separating them with commas:

``JVB_ADVERTISE_IPS=192.168.1.1,1.2.3.4``

## Advertising Ports

If your external port differs from the internal JVB_PORT, you can specify the advertised port along with the advertised IP:

``JVB_ADVERTISE_IPS=192.168.1.1#12345,fe80::1#12345``

## ICE Error
UDP port 10000 blocked - Firewall isn't allowing inbound UDP traffic | Make Sure The VM/container has UDP 10000 forwarded from the host

## Where Recordings Are Saved

By default, recordings go to `~/.jitsi-meet-cfg/jibri/recordings/`. You can change this with:

```bash
JIBRI_RECORDING_DIR=/your/custom/path
```

