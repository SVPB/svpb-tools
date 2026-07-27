# SVPB Tools — Next Generation (TNG)

A self-contained web service that automates sheet music distribution for the
[Silicon Valley Pipe Band](https://siliconvalleypipeband.org). When a musician pushes updated ABC notation to
GitHub, TNG converts it to PDF in-process and uploads the results to the band's Box folder, then
notifies Slack. Band members can also use the built-in binder builder to generate a personalised
PDF containing only the parts they need, with page numbers that reflect their own binder.

For full architecture details, feature list, and implementation plan, see [PROJECT_PLAN.md](PROJECT_PLAN.md).
For a comparison of hosting options, see [HOSTING_OPTIONS.md](HOSTING_OPTIONS.md).

---

## How it works

1. A musician pushes a change to the `svpb-music` GitHub repository.
2. GitHub sends a webhook to the TNG server.
3. TNG pulls the repository, converts every changed ABC file to PDF in-process
   (via CeolKit → SVGPDFKit), and uploads the results to Box.
4. A summary is posted to the band's Slack channel.

> **Current status:** step 3's Box upload is not yet implemented — `BoxService` is a skeleton and
> every upload attempt is logged as a failure in the build log. Conversion, the tune catalogue,
> and the binder builder all work. See the open issues.

Band members can visit the server's web UI to build a personalised binder: select the tunes
and parts they need, and download a single PDF with page numbers specific to their selection.
The pipe major can use the binder constructor page to generate the YAML for the canonical
band binder, which is then committed to `svpb-music`.

---

## Prerequisites

- **Docker** and **Docker Compose** installed on the server host. Nothing else — the server pulls
  a prebuilt image from the GitHub Container Registry and never compiles anything.
- To build from source: a **Swift 6.3 or newer** toolchain (required by the CeolKit dependency),
  or Docker with roughly 4 GB of RAM available. Neither is needed for the normal deployment path.
- A domain name pointed at the server's public IP address (required for automatic TLS).
- A GitHub webhook secret (any strong random string).
- Box OAuth2 credentials (reuse the existing Gen.1 credentials — no new Box admin setup needed).
- Your own Slack user ID (to seed the initial admin account on first startup).
- A Slack app with bot and Events API capabilities (see [Slack setup](#slack-setup) below).

---

## Configuration

All settings are provided via environment variables. Copy `.env.example` to `.env` and fill in
each value before starting the stack.

| Variable | Description |
|---|---|
| `DOMAIN` | Public hostname, e.g. `musictools.siliconvalleypipeband.com` — used by Caddy for TLS |
| `TNG_IMAGE_TAG` | Optional. Which published image to run: `develop`, a release version, or unset for `latest` |
| `GITHUB_WEBHOOK_SECRET` | Shared secret configured in the GitHub webhook settings |
| `SVPB_MUSIC_REPO_URL` | HTTPS clone URL of the `svpb-music` repository |
| `BOX_CLIENT_ID` | Box OAuth2 application client ID |
| `BOX_CLIENT_SECRET` | Box OAuth2 application client secret |
| `BOX_REFRESH_TOKEN` | Box OAuth2 refresh token |
| `BOX_FOLDER_ID` | ID of the top-level `pipe_music` Box folder; TNG creates year subfolders inside it automatically |
| `SLACK_BOT_TOKEN` | Bot token (`xoxb-…`) for sending login links and build notifications |
| `SLACK_SIGNING_SECRET` | Signing secret for verifying inbound Events API payloads |
| `SLACK_WEBHOOK_URL` | Incoming Webhook URL for posting build notifications |
| `INITIAL_ADMIN_SLACK_USER_ID` | Slack user ID granted admin access on first startup |

---

## Running the server

```sh
cp .env.example .env
# edit .env with your values
docker compose up -d
```

Caddy will obtain a TLS certificate automatically on first startup, provided the domain name
is already pointing at the server and ports 80 and 443 are reachable from the internet.

To view logs:

```sh
docker compose logs -f
```

To stop:

```sh
docker compose down
```

---

## Deployment

TNG is distributed as a `docker-compose.yml` that starts two containers — the TNG server and a
Caddy reverse proxy — plus named volumes for the database and the music workspace. Any host that
can run Docker Compose and is reachable on ports 80 and 443 will work.

Images are built by GitHub Actions and published to
`ghcr.io/svpb/svpb-tools`. The server pulls them; it never compiles Swift. See
[HOSTING_OPTIONS.md](HOSTING_OPTIONS.md) for a comparison of providers.

### Digital Ocean Droplet

**1. Create the droplet.** Ubuntu 24.04 LTS, Basic / Regular SSD, 2 GB RAM / 1 vCPU. Authenticate
with an SSH key rather than a password. Give it a hostname you will recognise later.

**2. Point DNS at it.** Create an `A` record for your hostname pointing at the droplet's public IP
address. Do this *before* starting the stack — Caddy requests a certificate on first launch and
that request fails if the name does not yet resolve. Verify with `dig +short <your-domain>`.

**3. Open the firewall.** Create a Digital Ocean cloud firewall allowing inbound TCP on 22, 80,
and 443, and attach it to the droplet.

**4. Install Docker.**

```sh
ssh root@<droplet-ip>
apt-get update && apt-get install -y ca-certificates curl git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**5. Add swap.** 2 GB of RAM is comfortable for normal operation, but rendering a full year of
music in one sync can spike. Swap costs nothing and prevents an OOM kill.

```sh
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

**6. Deploy.**

```sh
git clone https://github.com/SVPB/svpb-tools.git
cd svpb-tools
cp .env.example .env
# edit .env — every value in the Configuration table above
docker compose up -d
```

**7. Verify.** `docker compose ps` should show both containers healthy, and
`curl https://<your-domain>/health` should return JSON. If Caddy cannot get a certificate,
`docker compose logs caddy` says why — almost always DNS not yet propagated or port 80 blocked.

Estimated cost: **$12/month** for the droplet. The cloud firewall is free.

---

## Integration setup

### GitHub webhook

In the `svpb-music` repository settings on GitHub, add a webhook:

- **Payload URL**: `https://<your-domain>/webhook/github`
- **Content type**: `application/json`
- **Secret**: the value of `GITHUB_WEBHOOK_SECRET` in your `.env` — any strong random string,
  for example `openssl rand -hex 32`
- **Events**: select *Just the push event*

---

### Slack setup

TNG uses a single Slack app for three purposes: posting build notifications (Incoming Webhook),
receiving direct messages to issue login links (Bot + Events API), and reading the sender's
identity. All three are configured in the same app.

**Create the app:**

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App → From
   scratch**. Name it "SVPB Music Bot" and choose the SVPB workspace.

**Bot token and scopes:**

2. In the left sidebar, click **OAuth & Permissions**. Under **Bot Token Scopes**, add:
   - `chat:write` — to send login links and build notifications
   - `im:read` — to receive direct messages
   - `users:read` — to look up the sender's display name
3. Click **Install to Workspace** and authorise. Copy the **Bot User OAuth Token**
   (`xoxb-…`) — this is `SLACK_BOT_TOKEN`.

**Signing secret:**

4. In the left sidebar, click **Basic Information**. Under **App Credentials**, copy the
   **Signing Secret** — this is `SLACK_SIGNING_SECRET`.

**Incoming Webhook (build notifications):**

5. In the left sidebar, click **Incoming Webhooks** and toggle it **On**. Click
   **Add New Webhook to Workspace**, choose the channel for build notifications
   (e.g. `#music-updates`), and click **Allow**. Copy the Webhook URL — this is
   `SLACK_WEBHOOK_URL`.

**Events API (login bot):**

6. In the left sidebar, click **Event Subscriptions** and toggle **Enable Events** to On.
7. In **Request URL**, enter `https://<your-domain>/slack/events`. Slack will immediately
   send a `url_verification` challenge — TNG responds automatically, and Slack will show
   a green **Verified** badge.
8. Under **Subscribe to bot events**, add `message.im` (direct messages to the bot).
9. Click **Save Changes**, then reinstall the app if prompted.

**Initial admin:**

10. Find your own Slack user ID: open your Slack profile, click **⋯ More**, then
    **Copy member ID**. Set `INITIAL_ADMIN_SLACK_USER_ID` to that value. On first startup
    TNG creates your admin account automatically — no password required.

---

### Box OAuth2

TNG uploads PDFs to Box using OAuth2, the same authentication method used by the Gen.1 toolchain.
If you are migrating from Gen.1, the same Box app credentials can be reused — skip to step 5 to
obtain a fresh refresh token using the existing Client ID and Client Secret.

**Creating a Box app (fresh setup only):**

1. Go to the [Box Developer Console](https://app.box.com/developers/console) and click
   **Create New App**.
2. Choose **Custom App**, then **User Authentication (OAuth 2.0)**.
3. Give the app a name (e.g. "SVPB Music Server") and click **Create App**.
4. In the app's **Configuration** tab:
   - Note the **Client ID** and **Client Secret** — these are `BOX_CLIENT_ID` and
     `BOX_CLIENT_SECRET`.
   - Under **OAuth 2.0 Redirect URI**, add `http://localhost:8080/box-callback` (used only
     during the one-time token setup below; it does not need to be publicly reachable).
   - Under **Application Scopes**, ensure **Read and write all files and folders** is checked.
   - Click **Save Changes**.

**Obtaining the initial tokens:**

Box OAuth2 requires completing an authorization flow once to obtain an access token and a
refresh token. TNG includes a helper command for this:

```sh
docker compose run --rm tng box-auth
```

This prints an authorization URL. Open it in a browser, log in as the Box user who owns the
music folder, and click **Grant Access**. Box redirects to `localhost:8080/box-callback` with
an authorization code; the helper exchanges this for tokens and prints the refresh token to
the terminal. Copy it into `BOX_REFRESH_TOKEN` in your `.env`.

> **Important:** Box access tokens expire after one hour. TNG automatically exchanges the
> refresh token for a new access token as needed and writes the new refresh token back to its
> database. You do not need to intervene for routine operation. However, if the server is
> offline for more than 60 days, the refresh token will expire and you will need to repeat the
> authorization step above.

**Finding the Box folder ID:**

Navigate to the **`pipe_music`** folder in [box.com](https://box.com) — this is the top-level
folder that contains the year folders (e.g. `2025`, `2026`). The folder ID is the number at
the end of the URL: `https://app.box.com/folder/`**`123456789`**. Set this as `BOX_FOLDER_ID`.

TNG will automatically create a subfolder for each git branch (year) the first time it builds
that branch, and will upload PDFs into the appropriate year folder. For example, after a push
to the `2026` branch, PDFs appear at `pipe_music/2026/` in Box. The Gen.1 `full_band`, `g3`,
and `g4` subdirectory structure is not used; all PDFs for a year sit directly in the year
folder.

---

## Updating

Pushing to `develop` or `main` publishes a new image automatically. To move the server onto it:

```sh
git pull                # picks up compose/Caddyfile changes
docker compose pull     # fetches the new image from GHCR
docker compose up -d    # recreates the containers
```

The named volumes are preserved across updates; no data is lost.

To build the image on the server instead of pulling it — needs ~4 GB of RAM and 10–20 minutes:

```sh
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```
