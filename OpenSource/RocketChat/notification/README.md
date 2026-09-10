Problem:
RocketChat Only Sends Push Notification to Android(FCM) and IOS(APNs)


Goal-One:
Use Self-Hosted Rocketchat Instance to also send Notification to GrapheneOS using UnifiedPush / ntfy

Goal-Two: In Self-Hosted Rocketchat Instance during certain events(i.e. DM from a certain user) send webhook call/API Call/Or other ways to trigger another self-hosted HomeAssistant instance to perform actions like turn on a light

Approach: Self-hosted RocketChat Instance is Running on public cloud docker instance using compose.database.yml -f compose.nats.yml -f compose.yml. For notification use a custom(OpenSource/RocketChat/notification/docker-compose-rc-notification.yml) yml which will run alongside compose.database.yml -f compose.nats.yml -f compose.yml

---

## Why this can't just be "turn on push notifications"

Rocket.Chat's mobile push pipeline (`apps/meteor/server/lib/notifications/push*`) only ever
delivers through Google's FCM or Apple's APNs (see `pushNotification.ts`, `push/fcm.ts`,
`push/apn.ts`). Receiving an FCM message on Android *requires Google Play Services on the
device* — that's the actual blocker, not a Rocket.Chat setting. A GrapheneOS phone without
(sandboxed) Play Services structurally cannot receive FCM pushes, no matter how push is
configured server-side. Spoofing/rewriting the FCM protocol or forking the mobile app would
work but is fragile and breaks on every Rocket.Chat/app upgrade.

## The robust path: reuse Rocket.Chat's own "should I notify" logic, swap the transport

Reading `apps/meteor/server/hooks/messages/sendNotificationsOnMessage.ts`, Rocket.Chat already
computes, per message, exactly who should be notified (DM, @mention, thread reply, room
preferences) *before* it ever touches FCM/APNs. Rather than re-implement that decision logic in
a separate service, this solution hooks into Rocket.Chat's **Apps-Engine** — the officially
supported extensibility framework (`packages/apps-engine`) — which:

- is a stable public API that survives Rocket.Chat upgrades (no core patching/forking, no
  Docker image rebuild — it's a private app uploaded through the Marketplace),
- exposes an `IPostMessageSent` hook with outbound `IHttp` access,
- exposes an Admin-UI settings panel, so config lives in Rocket.Chat, not in source.

The app (`rocketchat-app/`) hooks every sent message, does a lightweight DM/@mention check
against a configured list of Rocket.Chat usernames, and publishes to a self-hosted **ntfy**
server. On the GrapheneOS side, the open-source **ntfy Android app** (F-Droid/Obtainium/GitHub —
no Google Play needed) keeps a persistent "Instant Delivery" connection to your ntfy server, so
the whole chain is Google/FCM-free. This is the "UnifiedPush / ntfy" approach named in Goal-One:
ntfy is itself a UnifiedPush distributor, and publishing directly to a topic is the same
mechanism, just without needing every app you use to add native UnifiedPush support first
(Rocket.Chat hasn't).

The same app also covers **Goal-Two**: if a DM arrives from a configured "trusted" username, it
calls the Home Assistant REST API (`/api/services/<domain>/<service>`) directly — no separate
component needed, since Apps-Engine's `IHttp` accessor can call any external URL.

```
Rocket.Chat message saved
        │
        ▼
IPostMessageSent hook (rocketchat-app/GraphenePushApp.ts)
        │
        ├─ DM or @mention of a configured user? ─► POST ntfy (self-hosted) ─► ntfy Android app ─► GrapheneOS notification
        │
        └─ DM from the configured "trusted" user? ─► POST Home Assistant /api/services/... ─► e.g. turn on a light
```

## Layout

```
notification/
├── docker-compose-rc-notification.yml   # ntfy, joins the existing compose project
├── ntfy-rocketchat-nginx.conf           # host nginx vhost: TLS termination + reverse proxy for ntfy
└── rocketchat-app/                      # Private Rocket.Chat App (Apps-Engine), TypeScript
    ├── app.json
    ├── GraphenePushApp.ts               # IPostMessageSent hook: ntfy + Home Assistant; /graphene-push
    ├── lib/
    │   ├── identity.ts                  # username↔id map learned from events, persisted
    │   ├── mentions.ts                  # @username / @all / @here text matching
    │   ├── ntfy.ts                      # ntfy JSON publish helper
    │   ├── homeAssistant.ts             # HA REST service-call helper
    │   └── settings.ts                  # App Settings shown in Marketplace → your app
    ├── icon.png
    ├── package.json
    ├── package-lock.json
    ├── tsconfig.json
    └── Dockerfile                       # packages the App into dist/graphene-push_<version>.zip for upload
```

Nothing under `Rocket.Chat-8.7.0/` or `rocketchat-compose-2.0.0/` is modified — both are kept as
unmodified upstream references. `docker-compose-rc-notification.yml` is an additive compose file
per the Approach above. TLS/reverse-proxying for ntfy is handled entirely by your own host nginx
(`ntfy-rocketchat-nginx.conf`) — there is no containerized reverse proxy (Traefik or otherwise) in
this setup, matching how Rocket.Chat itself is already fronted on this host.

## Setup

### 1. Start ntfy alongside the existing stack

Run from inside `rocketchat-compose-2.0.0/` so relative paths/volumes resolve as expected, adding
the notification compose file to whatever `-f` list you already use:

```bash
cd rocketchat-compose-2.0.0
docker compose \
  -f compose.monitoring.yml \
  -f compose.database.yml \
  -f compose.yml \
  -f ../docker-compose-rc-notification.yml \
  up -d
```

`ntfy` binds only to `127.0.0.1:8090` on the host (see `NTFY_BIND_IP`/`NTFY_HOST_PORT` below) —
it isn't reachable from the internet until your host nginx is wired up in step 3.

### 2. Add to your `.env`

```env
# ntfy
NTFY_DOMAIN=ntfy.your-domain.com
NTFY_VERSION=latest
# Host nginx (step 3) proxies to this; leave as loopback-only.
NTFY_BIND_IP=127.0.0.1
NTFY_HOST_PORT=8090
```

### 3. Put ntfy behind TLS with your host nginx

`ntfy-rocketchat-nginx.conf` is a ready-to-use vhost: it terminates TLS and reverse-proxies to
`127.0.0.1:8090`, with the buffering/timeout/upgrade settings ntfy's Instant Delivery and
attachment uploads actually need (plain default nginx settings will silently break streaming
delivery). To use it:

1. Point `ntfy.your-domain.com` DNS at this host.
2. Replace the `ntfy.your-domain.com` placeholder in the file with your real subdomain.
3. Get a certificate, e.g. `sudo certbot certonly --nginx -d ntfy.your-domain.com`.
4. Copy/symlink the file into wherever your existing Rocket.Chat vhost lives (e.g.
   `/etc/nginx/sites-available/` + `sites-enabled/`, or `conf.d/`).
5. `sudo nginx -t && sudo systemctl reload nginx`.

### 4. Create the two ntfy accounts

`NTFY_AUTH_DEFAULT_ACCESS=deny-all` (the default here) means nobody can read or write *any* topic
until explicitly granted. A notification has two sides, so you need **two accounts — both are
required**, and skipping B is the most common reason notifications never arrive:

| | Account | What it does | Where it's used |
|---|---|---|---|
| **A** | one per person, e.g. `nathan` | **reads** the topic | your phone's ntfy app (step 5) |
| **B** | one shared, `rocketchat` | **writes** to the topic | the Rocket.Chat App, as `Ntfy_Auth_Token` (step 7) |

Without A, your phone can't subscribe. Without B, the App publishes anonymously and ntfy silently
rejects it with a 403 — the message never reaches your phone even though Rocket.Chat did its part.

All commands run against the ntfy container. Its exact name depends on your Compose project name,
so resolve it rather than guessing:

```bash
NTFY_CONTAINER="$(docker ps -qf name=ntfy)"
```

#### Step A — the reader account (one per person)

```bash
# creates a login (prompts for a password), then grants it its own topic
docker exec -it "$NTFY_CONTAINER" ntfy user add --role=user nathan
docker exec -it "$NTFY_CONTAINER" ntfy access nathan 'nathan-rc-alerts' read-write
```

`nathan-rc-alerts` is just an example topic name — anything works, as long as the same name is used
in the App's `Notify_Targets` setting (step 7) and in that person's ntfy app (step 5). Repeat both
commands per household member, one topic each.

#### Step B — the publisher account (one, shared by the App)

A token belongs to a user, so the user has to exist before `ntfy token add` will work:

```bash
docker exec -it "$NTFY_CONTAINER" ntfy user add rocketchat
docker exec -it "$NTFY_CONTAINER" ntfy access rocketchat 'nathan-rc-alerts' write-only
# repeat the "access" line for every other topic you created in step A

docker exec -it "$NTFY_CONTAINER" ntfy token add rocketchat
```

That last command prints a `tk_...` value — **copy it now** and put it in the App's
`Ntfy_Auth_Token` setting (step 7), rather than relying on looking it up later.

`write-only` is deliberate: the App only ever needs to send, so this account can't read anyone's
notifications, and revoking it later doesn't disturb anyone's phone subscription.

### 5. GrapheneOS: install ntfy, no Google services involved

Install the ntfy Android app from F-Droid, IzzyOnDroid, Obtainium, or the GitHub releases page.
Add your server (`https://ntfy.your-domain.com`), log in with the user from step 4, subscribe to
your topic, and enable **Instant delivery** in the app's settings. Instant delivery keeps a
persistent connection to your own server instead of relying on Firebase — this is what makes the
whole chain Google/FCM-free.

### 6. Build and upload the Rocket.Chat App

The App goes in by uploading a `.zip` through Rocket.Chat's own web UI while you're logged in as
yourself — no Rocket.Chat credentials are stored anywhere, and nothing is pushed to a registry.

**Dev machine — build the zip:**

```bash
cd rocketchat-app
sudo docker build --output dist .
```

This runs `rc-apps package` inside a throwaway Node container and writes
`dist/graphene-push_<version>.zip` (version taken from `app.json`) — no `npm`/`npx` needed on your
machine. `--output` needs BuildKit, the default builder since Docker 23. If packaging fails, the
build stops and shows the `rc-apps` error; `rc-apps` itself exits 0 even on failure, so the
Dockerfile checks its output instead of trusting the exit code.

Without Docker, `npm ci && npx rc-apps package` inside `rocketchat-app/` produces the same zip —
but then check the output yourself: only a run that prints `finished!` and `App packaged up at:`
actually succeeded.

**Rocket.Chat — upload it:**

1. Open the Marketplace's **Private Apps** page (store icon in the top navbar — step 7 has the
   exact clicks).
2. Click **Upload private app** in the page header (visible to admins).
3. **Browse Files** → pick the zip → **Install**.
4. The **Required Permissions** dialog lists `networking` (how the App reaches ntfy and Home
   Assistant) → **Agree**.

**Updating later:** bump `version` in `app.json` (optional — it's just how you tell builds apart on
the App's page), rebuild, and upload the new zip the same way. Rocket.Chat asks *"This app is
already installed — Do you want to update it?"* → **Yes** → **Agree**. An update keeps the App's
settings and the usernames it has learned, so nothing needs re-entering.

If Rocket.Chat instead says *"App cannot be updated … exempt from the app limit policy"*, the
workspace has no valid license (**Administration → Subscription** shows your plan): Rocket.Chat
blocks in-place updates of private apps on unlicensed Community workspaces, from the UI and the API
alike. The only way through is uninstalling and uploading again, which deletes the App's settings
and learned usernames — copy the settings out first.

### 7. Configure the App

Marketplace moved out of Administration in current Rocket.Chat versions — it's its own top-level
section now, not nested under Admin. Click the **store icon** in the top navbar (tooltip:
"Marketplace"), then anything from that dropdown (e.g. **Installed**) just to land on the
Marketplace page. GraphenePush is a *private* app, so it will **not** show under "Installed" —
from the Marketplace page's own sidebar, click **Private Apps** instead, that's the one that
lists it. Click into **GraphenePush**, then its **Settings** tab:

- `Ntfy_Base_Url`: `https://ntfy.your-domain.com`
- `Ntfy_Auth_Token`: the `tk_...` token from step 4B. Required whenever ntfy runs with
  `auth-default-access=deny-all` (the default here) — without it the App publishes anonymously and
  ntfy rejects every notification with a 403
- `Notify_Targets`: one `username:ntfy_topic` pair per line, e.g. `nathan:nathan-rc-alerts`
  (case-insensitive). A Rocket.Chat user id works here too, if you'd rather pin it exactly —
  see "How usernames are resolved" below
- `Root_Url`: same value as your Rocket.Chat `ROOT_URL`, used to deep-link the notification back
  into the right DM/channel
- `Notify_On_Direct_Message` / `Notify_On_Mention` / `Include_Message_Preview`: tune to taste

For Goal-Two, also set `Ha_Base_Url`, `Ha_Long_Lived_Token`, `Ha_Trigger_Username` (the Rocket.Chat
username *or user id* whose DMs should trigger Home Assistant), and the target `Ha_Service_Domain` /
`Ha_Service_Name` / `Ha_Entity_Id` (e.g. `light` / `turn_on` / `light.living_room`). Leave
`Ha_Base_Url` empty to leave Goal-Two disabled.

#### How usernames are resolved

Apps run in an isolated Deno runtime and reach Rocket.Chat's data over "bridges". On some
deployments every *user-lookup* bridge call comes back empty for users that provably exist —
`getByUsername()`, `getById()`, `getMembers()` and `getDirectByUsernames()` all return nothing,
with no error raised. An app that resolves DM recipients through any of those silently notifies
nobody, which is exactly what happened while building this.

What is always correct is the `IUser` delivered *with* an event. So the App never looks a user up;
it learns identities as they arrive and remembers them in its own storage:

| Source | Fires when |
|---|---|
| `IPostUserStatusChanged` | anyone goes online / away / busy / offline |
| `IPostUserLoggedIn` | anyone logs in |
| `IPostMessageSent` | anyone sends a message, in any room |
| `IPostUserCreated` / `IPostUserUpdated` | an account is created or renamed |
| `/graphene-push` | that person runs the command |

In practice a status change or login lands within minutes of installing the App, so usernames
start working on their own. Two things follow from the design:

- **To make it immediate**, have the person run `/graphene-push` in any channel — the command
  replies with the username and id it recorded, so it doubles as a "does the App see me?" check.
- **Until someone has been seen once**, a DM to them can't be matched. The App logs a warning
  naming the unknown user when that happens, rather than failing silently.

Configuring a target by **user id** skips all of this and matches immediately against
`room.userIds`, with no learning required. To find one: **Admin → Users**, click the user; the id
is shown in the panel (and in the URL).
