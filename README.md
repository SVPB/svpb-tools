# SVPB Tools — Next Generation (TNG)

A self-contained web service that automates sheet music distribution for the
[Silicon Valley Pipe Band](https://siliconvalleypipeband.org). When a musician pushes updated ABC notation to
GitHub, TNG converts it to PDF in-process, assembles the band's official binders, and uploads
those to the band's Box folder, then notifies Slack. Band members can also use the built-in binder
builder to generate a personalised PDF containing only the parts they need, with page numbers that
reflect their own binder.

For full architecture details, feature list, and implementation plan, see [PROJECT_PLAN.md](PROJECT_PLAN.md).
For a comparison of hosting options, see [HOSTING_OPTIONS.md](HOSTING_OPTIONS.md).

---

## How it works

1. A musician pushes a change to the `svpb-music` GitHub repository.
2. GitHub sends a webhook to the TNG server.
3. TNG pulls the repository and converts every changed ABC file to PDF in-process
   (via CeolKit → SVGPDFKit). These per-tune PDFs are intermediates; they stay on the server.
4. TNG reads `binders.yaml` from that branch, assembles each official binder it names, and
   uploads **those PDFs only** to Box.
5. A summary is posted to the band's Slack channel.

> **Current status:** step 4's binder assembly and Box upload are not yet implemented —
> `BoxService` is a skeleton, and `BuildService` currently attempts to upload each per-tune PDF
> rather than the assembled binders. Conversion, the tune catalogue, and the binder builder all
> work. See the open issues.

Band members can visit the server's web UI to build a personalised binder: select the tunes
and parts they need, and download a single PDF with page numbers specific to their selection.
A personalised binder lives on the server and on the member's own computer — it is never pushed
to Box.

The pipe major can use the binder constructor page to generate the YAML for an official band
binder, which is then committed to `binders.yaml` in `svpb-music`.

---

## The binder spec (`binders.yaml`)

`binders.yaml` at the root of a branch of the music repository defines the band's official
binders. It replaces the Gen.1 `Makefile`, which encoded the same information as `make` variables
and targets. The branch it is committed to *is* the year, so the file carries no year of its own.

```yaml
# binders.yaml — the official binders for this branch (year).
# Owned by the pipe major and committed to the music repository. TNG reads it
# after every push and rebuilds the binders it names.

binders:
  - name: "2026 Band Binder"          # shown in the UI and the build log
    output: 2026_binder.pdf           # filename in Box, under pipe_music/<branch>/
    sections:
      - title: "Grade 4 Tunes"        # rendered as a divider page ahead of the section
        entries:
          - tune: g4_medley_2026      # tune slug = the .abc filename without its extension
          - tune: g4_msr_march_2026
          - tune: g4_msr_2026
      - title: "Parade Tunes"
        entries:
          - tune: banks_of_the_lossie
          - tune: MarchOfTheRBL
          - tune: Moonstar
            parts: ["Melody", "Seconds"]   # optional; defaults to every part of the tune
      - title: "Massed Bands / WUSPBA"
        entries:
          - tune: amazing_grace
          - tune: scotland_the_brave

  - name: "2026 Speculative"
    output: 2026_spec.pdf
    sections:
      - title: "Grade 4 Speculative"
        entries:
          - tune: victoria_harbour
          - tune: seonaidhs
```

- **Only the binders listed here are uploaded to Box**, each under its `output` filename, into
  the year folder for the branch (`pipe_music/2026/2026_binder.pdf`).
- `tune` is the tune's slug: the `.abc` filename without its extension.
- `parts` is optional. Omit it to include every part of the tune, which is what the official
  binder normally wants.
- Each `title` is rendered as a divider page ahead of that section's tunes, and page footers
  number pages within the binder.
- The pipe major does not have to write this by hand: the binder constructor page
  (`/binder-constructor`) generates it from the tune catalogue for copy-and-commit.

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
| `TNG_STATE_DIR` | Optional. Host directory holding the database and Caddy's certificates. Defaults to `./state` in the checkout; on a server, point it at a mount that outlives the machine — see [Persistent state](#persistent-state) |
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
Caddy reverse proxy — plus a bind-mounted state directory and one named volume for the music
workspace. Any host that can run Docker Compose and is reachable on ports 80 and 443 will work.

Images are built by GitHub Actions and published to
`ghcr.io/svpb/svpb-tools`. The server pulls them; it never compiles Swift. See
[HOSTING_OPTIONS.md](HOSTING_OPTIONS.md) for a comparison of providers.

### Persistent state

Everything TNG cannot regenerate lives under one directory, named by `TNG_STATE_DIR`:

```
$TNG_STATE_DIR/
├── .env            # secrets and configuration; symlinked into the checkout
├── data/           # SQLite database — users, build history, tune catalogue, binder requests
└── caddy/
    ├── data/       # ACME account key and issued TLS certificates
    └── config/     # Caddy's autosaved config
```

`TNG_STATE_DIR` defaults to `./state` inside the checkout, which is what local development wants.
On a server, point it at storage that survives the machine — the whole point being that a droplet's
boot disk does not. The music workspace (the clone of the music repository and the rendered
SVG/PDF output) deliberately stays a plain named Docker volume: it is reproducible from the next
sync and expensive to store.

Note the `.env` in that listing. It is a fifth piece of unreplaceable state, it cannot be committed,
and it is not reconstructable without re-running `box-auth` and re-reading every credential out of
Box, Slack, and GitHub — so it belongs on the same durable storage, symlinked back into the
checkout where `docker compose` expects to find it.

This protects against losing the machine. It does **not** protect against database corruption, a
bad migration, or `docker compose down -v`; backups are a separate concern.

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

**5. Attach a block storage volume.** In the Digital Ocean control panel, create a Volume in the
droplet's region — 1 GiB is the minimum and is ample — name it `tng-state`, and attach it to the
droplet.

Digital Ocean formats and mounts the volume for you at attach time. It mounts it at
`/mnt/<volume-name>` with hyphens replaced by underscores, so a volume named `tng-state` arrives at
**`/mnt/tng_state`**. What it does *not* do is add an `/etc/fstab` entry, so that mount is
live-only and disappears on the next reboot. Check what you actually have before changing anything:

```sh
lsblk -f                      # is there already an ext4 filesystem, and where is it mounted?
cat /etc/fstab                # is there an entry for it?
ls -l /dev/disk/by-id/ | grep -i volume
```

If `lsblk -f` shows **no** filesystem on the volume, format it — and only then, because this
erases whatever is there:

```sh
mkfs.ext4 -F /dev/disk/by-id/scsi-0DO_Volume_tng-state
```

Then persist the mount. Use the `by-id` path, never a bare `/dev/sda`: device letters are not
stable across reboots, and a volume that comes back as `sdb` would leave the mountpoint an empty
directory on the boot disk while the stack writes to it happily.

```sh
mkdir -p /mnt/tng_state
echo '/dev/disk/by-id/scsi-0DO_Volume_tng-state /mnt/tng_state ext4 defaults,nofail,discard 0 2' \
  >> /etc/fstab
umount /mnt/tng_state 2>/dev/null    # drop Digital Ocean's ad-hoc mount, if it made one
mount -a
findmnt /mnt/tng_state
mkdir -p /mnt/tng_state/data /mnt/tng_state/caddy/data /mnt/tng_state/caddy/config
```

The `umount` / `mount -a` round trip is the point of that sequence: it proves the fstab entry
mounts the volume, rather than leaving you trusting that it will at boot. `findmnt` must print a
row showing the device and `ext4`. If it prints nothing, the entry is wrong and `nofail` swallowed
the error — fix it before going any further, because every later step would write to the boot disk.

Volumes cost $0.10/GiB/month, can be resized up (never down), survive the droplet's destruction,
and can be snapshotted independently of it.

**6. Add swap.** 2 GB of RAM is comfortable for normal operation, but rendering a full year of
music in one sync can spike. Swap costs nothing and prevents an OOM kill.

```sh
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

**7. Deploy.**

The `.env` lives on the volume and is symlinked into the checkout, so that destroying and
recreating the droplet loses nothing but the checkout itself.

```sh
git clone https://github.com/SVPB/svpb-tools.git
cd svpb-tools
cp .env.example /mnt/tng_state/.env
chmod 600 /mnt/tng_state/.env
# edit /mnt/tng_state/.env — every value in the Configuration table above,
# and uncomment TNG_STATE_DIR=/mnt/tng_state
ln -s /mnt/tng_state/.env .env
docker compose up -d
```

**8. Verify.** `docker compose ps` should show both containers healthy, and
`curl https://<your-domain>/health` should return JSON. If Caddy cannot get a certificate,
`docker compose logs caddy` says why — almost always DNS not yet propagated or port 80 blocked.

Estimated cost: **$12/month** for the droplet plus **$0.10/month** for a 1 GiB volume. The cloud
firewall is free.

#### Migrating an existing droplet onto a block volume

If the stack is already running with its state in Docker `local` named volumes — that is, on the
droplet's boot disk — move it onto the volume without losing the database. Do step 5 above first to
mount the volume durably, then, from the checkout:

```sh
docker compose down                        # NOT -v: that would delete the volumes you are copying

# The compose project name prefixes the volume names; it defaults to the
# directory name, so these are usually svpb-tools_*. Confirm with `docker volume ls`.
docker run --rm -v svpb-tools_tng-data:/from -v /mnt/tng_state/data:/to \
  alpine sh -c 'cp -a /from/. /to/'
docker run --rm -v svpb-tools_caddy-data:/from -v /mnt/tng_state/caddy/data:/to \
  alpine sh -c 'cp -a /from/. /to/'
docker run --rm -v svpb-tools_caddy-config:/from -v /mnt/tng_state/caddy/config:/to \
  alpine sh -c 'cp -a /from/. /to/'

# cp rather than mv, so there is a verified copy on the volume before the original goes
cp .env /mnt/tng_state/.env
chmod 600 /mnt/tng_state/.env
echo 'TNG_STATE_DIR=/mnt/tng_state' >> /mnt/tng_state/.env
diff <(grep -v TNG_STATE_DIR /mnt/tng_state/.env) .env && echo "identical apart from the new line"
rm .env
ln -s /mnt/tng_state/.env .env

git pull                                   # picks up the bind-mount compose file
docker compose config | grep -A1 'type: bind'
```

Check that output before starting: the three state binds must resolve to `/mnt/tng_state/data`,
`/mnt/tng_state/caddy/data`, and `/mnt/tng_state/caddy/config`. If they resolve to `./state/...`,
`TNG_STATE_DIR` is not reaching Compose through the symlinked `.env` and starting now would create
an empty database on the boot disk. (The fourth bind, the `Caddyfile`, stays in the checkout by
design — it is read-only config tracked in git.)

```sh
docker compose up -d           # up only: `docker compose pull` here would change the application
                               # version at the same time and muddle what to blame if it breaks
```

Verify before cleaning up. `curl -fsS https://<your-domain>/health` is the most direct check: its
`last_build` field comes straight from the database the running process has open, so a build you
recognise proves the copy was opened rather than a new database created. `docker compose logs
caddy` should also be quiet about obtaining certificates — it should load the copied one. Only once
you are satisfied, reclaim the boot-disk copies:

```sh
docker volume rm svpb-tools_tng-data svpb-tools_caddy-data svpb-tools_caddy-config
```

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
that branch, and will upload the assembled binders into the appropriate year folder. For example,
after a push to the `2026` branch, `pipe_music/2026/2026_binder.pdf` appears in Box. The Gen.1
`full_band`, `g3`, and `g4` subdirectory structure is not used; the binders for a year sit
directly in the year folder.

Nothing else is uploaded: per-tune PDFs are build intermediates kept on the server for the binder
builder, and personalised binders are downloaded straight from TNG.

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
