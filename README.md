# SVPB Tools — Next Generation (TNG)

A self-contained web service that automates sheet music distribution for the
[Silicon Valley Pipe Band](https://svpb.org). When a musician pushes updated ABC notation to
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
   (via ABCKit → SVGPDFKit), and uploads the results to Box.
4. A summary is posted to the band's Slack channel.

Band members can visit the server's web UI to build a personalised binder: select the tunes
and parts they need, and download a single PDF with page numbers specific to their selection.
The pipe major can use the binder constructor page to generate the YAML for the canonical
band binder, which is then committed to `svpb-music`.

---

## Prerequisites

- **Docker** and **Docker Compose** installed on the server host.
- A domain name pointed at the server's public IP address (required for automatic TLS).
- A GitHub webhook secret (any strong random string).
- Box OAuth2 credentials (reuse the existing Gen.1 credentials — no new Box admin setup needed).
- A Slack Incoming Webhook URL.

---

## Configuration

All settings are provided via environment variables. Copy `.env.example` to `.env` and fill in
each value before starting the stack.

| Variable | Description |
|---|---|
| `DOMAIN` | Public hostname, e.g. `music.svpb.org` — used by Caddy for TLS |
| `GITHUB_WEBHOOK_SECRET` | Shared secret configured in the GitHub webhook settings |
| `SVPB_MUSIC_REPO_URL` | HTTPS clone URL of the `svpb-music` repository |
| `BOX_CLIENT_ID` | Box OAuth2 application client ID |
| `BOX_CLIENT_SECRET` | Box OAuth2 application client secret |
| `BOX_REFRESH_TOKEN` | Box OAuth2 refresh token |
| `BOX_FOLDER_ID` | ID of the Box folder to upload PDFs into |
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL |
| `ADMIN_PASSWORD` | Password for the `/admin` dashboard |

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
Caddy reverse proxy — plus a named volume for the music workspace and database. Any host that
can run Docker Compose and is reachable on ports 80 and 443 will work.

Two broad approaches are described below. See [HOSTING_OPTIONS.md](HOSTING_OPTIONS.md) for a
detailed comparison of specific cloud providers.

### Option A — Keep the existing EC2 instance

This is the lowest-effort migration path if the band already has an EC2 instance running the
Gen.1 tools. The instance itself stays; only its software configuration changes.

**One-time setup** (replaces all of the Apache / certbot / Perl / make configuration):

```sh
# Install Docker (Amazon Linux 2023)
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user   # log out and back in after this

# Install Docker Compose plugin
sudo dnf install -y docker-compose-plugin

# Clone this repository
git clone https://github.com/SVPB/svpb-tools.git
cd svpb-tools
```

The Elastic IP address and the Route 53 DNS record pointing the domain at that IP can be left
exactly as they are. The only change needed to the EC2 security group is to ensure ports 80
and 443 are open inbound (they likely already are). Port 22 for SSH management can remain open.

Apache, certbot, Perl, make, and GhostScript can be uninstalled once the new stack is
confirmed working — they are no longer needed.

```sh
cp .env.example .env
# edit .env
docker compose up -d
```

Estimated monthly cost: whatever the EC2 instance already costs (a `t3.micro` is ~$8/month
in us-west-2 with on-demand pricing; a Reserved Instance is cheaper still).

### Option B — Deploy to a container-oriented cloud service

If the band is starting fresh, or wants to move away from managing an EC2 instance entirely,
several cloud platforms are designed specifically for running Docker containers with minimal
operational overhead. The deployment flow is broadly the same across all of them:

1. Create an account and a new project/app.
2. Point the platform at this repository (or push the Docker image directly).
3. Set the environment variables in the platform's dashboard.
4. Attach a persistent volume (for the SQLite database and built PDFs).
5. Point your domain's DNS at the address the platform provides.

The platform handles the underlying VM, OS updates, and (on most platforms) TLS automatically.

See [HOSTING_OPTIONS.md](HOSTING_OPTIONS.md) for a side-by-side comparison of
[Fly.io](https://fly.io), [Render](https://render.com), [Railway](https://railway.app),
[Digital Ocean App Platform](https://www.digitalocean.com/products/app-platform), and
[Heroku](https://heroku.com), with estimated costs and a recommendation for this workload.

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

### Slack incoming webhook

TNG posts build notifications to a single Slack channel using an Incoming Webhook URL — a
self-contained URL that authorises posting to one channel without requiring a full OAuth app.

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App → From
   scratch**. Give it a name (e.g. "SVPB Music Bot") and choose the SVPB Slack workspace.
2. In the left sidebar, click **Incoming Webhooks**, then toggle **Activate Incoming Webhooks**
   to On.
3. Click **Add New Webhook to Workspace**, choose the channel where build notifications should
   appear (e.g. `#music-updates`), and click **Allow**.
4. Copy the Webhook URL that appears — it looks like
   `https://hooks.slack.com/services/T.../B.../...`. This is the value of `SLACK_WEBHOOK_URL`
   in your `.env`.

The webhook URL is tied to the channel you chose. If you ever need to change the channel,
generate a new webhook URL and update `SLACK_WEBHOOK_URL`.

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
docker compose run --rm tng swift run TNG box-auth
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

Navigate to the music folder in [box.com](https://box.com). The folder ID is the number at
the end of the URL: `https://app.box.com/folder/`**`123456789`**. This is `BOX_FOLDER_ID`.

---

## Updating

```sh
git pull
docker compose pull
docker compose up -d
```

The named volume is preserved across updates; no data is lost.
