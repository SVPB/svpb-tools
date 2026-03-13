# Hosting Options for SVPB TNG

This document compares the realistic hosting options for the TNG server. The goal is to help
whoever maintains SVPB Tools choose and, if necessary, change the deployment target without
needing to understand cloud infrastructure in depth.

---

## What TNG needs from a host

Before comparing platforms, it helps to be explicit about requirements:

- **Always-on process.** TNG is a long-running Vapor HTTP server that must respond to GitHub
  webhooks at any time. Platforms that sleep idle processes are not suitable.
- **Persistent storage.** The SQLite database and the built PDF files must survive container
  restarts and deployments. A named Docker volume or attached disk is required.
- **Inbound HTTPS on a custom domain.** GitHub webhooks and band members both reach the server
  over the public internet. TLS is mandatory; a custom domain is expected.
- **Outbound HTTP.** The server calls the Box REST API and a Slack Incoming Webhook URL.
- **Low traffic, single instance.** SVPB is a small band. There is no need for autoscaling,
  multiple regions, or high availability.
- **Low maintenance.** The operator should not need to manage operating system patches, reverse
  proxy configuration, or TLS certificate renewal.

---

## Option 1 — Existing EC2 instance (reuse Gen.1 infrastructure)

**What changes:** The EC2 instance keeps its Elastic IP, its Route 53 DNS record, and its
security group. Everything else — Apache, certbot, Perl, make, GhostScript — is replaced by
Docker Compose running the TNG stack. Caddy handles TLS automatically; no certbot configuration
or cron job is needed.

**What stays the same:** The domain name, the IP address, the AWS account, the Box OAuth2
credentials, the Slack webhook URL, and the GitHub webhook URL (assuming the domain is
unchanged).

**Setup effort:** Install Docker and Docker Compose, clone the repo, populate `.env`, run
`docker compose up -d`. One session of maybe 30 minutes.

**Ongoing maintenance:** `git pull && docker compose pull && docker compose up -d` to update.
AWS still requires the operator to keep an eye on EC2 console, billing alerts, and occasional
AMI/kernel security notices — though these are infrequent and non-urgent for a small instance.

**Estimated cost:** A `t3.micro` (2 vCPU burst, 1 GB RAM) runs at roughly **$8–9/month**
on-demand in us-west-2. A 1-year Reserved Instance brings this to around **$5/month**. The
TNG server is not CPU-intensive (conversions are fast and infrequent), so a `t3.micro` is
entirely adequate.

**Verdict:** The path of least resistance. Recommended if the band already has the EC2 instance
and wants to minimise disruption.

---

## Option 2 — Digital Ocean Droplet

A DigitalOcean Droplet is a VPS — functionally identical to an EC2 instance but with a simpler
console, more predictable pricing, and no sprawling AWS account to manage.

**Setup:** Create a Droplet (Ubuntu 24.04 LTS), install Docker and Docker Compose, clone the
repo, populate `.env`, assign a Floating IP, update DNS, run `docker compose up -d`. The
process is essentially the same as the EC2 path but without the AWS-specific concepts
(security groups, IAM, VPCs, Elastic IPs).

**Persistent storage:** The Droplet's local disk is persistent across reboots. The named Docker
volume lives on that disk, so no additional storage product is needed.

**Estimated cost:** The smallest Droplet (1 vCPU, 1 GB RAM, 25 GB SSD) costs **$6/month**.
A Floating IP is free when attached to a running Droplet.

**Ongoing maintenance:** Essentially the same as EC2 — periodic OS updates, same
`docker compose pull && up -d` update flow. Digital Ocean's interface is noticeably simpler
than the AWS console, which reduces cognitive overhead for infrequent operators.

**Verdict:** The simplest VPS option. Slightly cheaper than EC2 on-demand, considerably
simpler console. A good choice for a fresh deployment that doesn't need to reuse existing AWS
infrastructure.

---

## Option 3 — Fly.io

Fly.io is a Docker-native platform that deploys applications as Firecracker microVMs across a
global network of data centers. Applications are defined by a `Dockerfile` and a `fly.toml`
configuration file; deployment is via the `flyctl` CLI.

**Persistent storage:** Fly Volumes provide persistent block storage at **$0.15/GB/month**.
A 5 GB volume (plenty for the SQLite database and a year's worth of PDFs) costs ~$0.75/month.
Volume snapshots are now billed separately at $0.08/GB/month, with the first 10 GB free.

**TLS:** Fly handles TLS automatically for any custom domain pointed at its anycast addresses.
No Caddy is needed in the compose stack; the Vapor app can be deployed alone and Fly terminates
TLS at the edge.

**Always-on:** Fly Machines can be configured to never scale to zero, making them suitable for
webhook receivers. A shared-CPU-1x machine (256 MB RAM) runs at roughly **$2–4/month**.

**Estimated cost:** ~**$4–6/month** (small VM + 5 GB volume).

**Free tier:** Removed for new accounts in 2024. A short free trial (2 VM hours or 7 days) is
available, but a credit card is required from the start.

**Setup effort:** Moderate. Requires installing `flyctl`, learning Fly's `fly.toml` format,
and understanding how Fly volumes are attached to machines. The `docker-compose.yml` does not
translate directly — a separate deployment config is needed. This is more initial work than the
VPS options, but results in a fully managed platform with no OS to maintain.

**Ongoing maintenance:** `fly deploy` to update. No OS patches, no server to SSH into.

**Verdict:** The most polished container-native experience, and the cheapest option if the VPS
path is not available. The learning curve is real but modest. The lack of direct Docker Compose
support means the `docker-compose.yml` serves as documentation only for Fly deployments.

---

## Option 4 — Render

Render is a managed cloud platform targeting developers who want Heroku's simplicity without
Heroku's price. Web services deploy directly from a `Dockerfile` or a Git repository.

**Persistent storage:** Render supports persistent SSD disks that can be attached to any paid
web service. Disk pricing is approximately **$0.25/GB/month**.

**TLS:** Automatic on any custom domain.

**Always-on:** Paid web services are always-on. Free services sleep after 15 minutes of
inactivity (not suitable for webhook receivers).

**Estimated cost:** The Starter web service (512 MB RAM, 0.5 CPU) costs **$7/month**. A 5 GB
disk adds ~$1.25/month. Total: roughly **$8–9/month**.

**Pricing model:** Flat monthly tiers — straightforward to predict. No per-second billing
surprises.

**Setup effort:** Low. Connect a GitHub repository, set environment variables in the dashboard,
attach a disk, and deploy. No CLI required. The `Dockerfile` in the repository is used directly.

**Ongoing maintenance:** Render handles OS patches and the underlying infrastructure. Deployments
are triggered automatically on git push (configurable). No SSH access needed for routine
operations.

**Verdict:** The simplest fully-managed option and the easiest to hand off to a non-technical
maintainer. Slightly more expensive than Fly.io for equivalent resources, but the flat pricing
and dashboard-driven setup make it more approachable. Strong recommendation for teams that
want to avoid any CLI work.

---

## Option 5 — Railway

Railway is a developer-focused platform with usage-based billing. Applications deploy from a
`Dockerfile` or `railway.json`; persistent volumes are supported.

**Persistent storage:** Volumes are supported and billed as part of overall resource usage.

**TLS:** Automatic.

**Always-on:** Railway bills by the second for actual CPU and RAM consumed. An idle Vapor server
uses very little CPU, so costs are low when traffic is light — but the billing is less
predictable than Render's flat tiers.

**Estimated cost:** Hard to state precisely due to usage-based billing. For a lightweight,
mostly-idle server, expect **$3–8/month**, but this varies.

**Free tier:** $5 of trial credit (no card required to start).

**Setup effort:** Low to moderate. Similar to Render — connect a repository, set variables,
deploy.

**Ongoing maintenance:** Fully managed. No OS to patch.

**Verdict:** A reasonable option, but the usage-based pricing makes monthly costs less
predictable than Render's flat tiers, which matters when the maintainer checks the bill once a
month rather than daily. Suitable for operators comfortable with variable billing.

---

## Option 6 — Heroku

Heroku is one of the oldest PaaS platforms and pioneered many of the deployment patterns the
others have since adopted. It supports Docker deployments via `heroku.yml`.

**Persistent storage:** This is Heroku's significant limitation for TNG. Heroku dynos have
**ephemeral local filesystems** — any files written to disk are lost when the dyno restarts or
is redeployed. This includes both the SQLite database file and the built PDFs. Using Heroku
would require replacing SQLite with a hosted Postgres database (Heroku Postgres Essential-0:
$5/month) and replacing the local PDF volume with an external object store such as S3. This is
a meaningful architectural divergence from the standard TNG deployment.

**Pricing:** Basic dynos cost $7/month. With Heroku Postgres ($5/month) and the architectural
changes required, the total rises to at least **$12–15/month** for a configuration that still
has less capability than the VPS options.

**Platform trajectory:** In early 2026 Heroku announced a shift toward a "sustainability
model," signalling reduced investment in new features. The platform remains functional but is
no longer actively growing.

**Verdict:** Not recommended for TNG. The ephemeral filesystem requires architectural changes
that add complexity and cost, and the platform's trajectory raises questions about long-term
viability relative to alternatives. The only reason to choose Heroku would be if the team
already has significant Heroku expertise and existing paid credits.

---

## Comparison summary

| | EC2 (reuse) | DO Droplet | Fly.io | Render | Railway | Heroku |
|---|---|---|---|---|---|---|
| **Est. monthly cost** | $5–9 | $6 | $4–6 | $8–9 | $3–8 | $12–15+ |
| **Pricing model** | per-hour | flat | per-second | flat tiers | usage-based | flat |
| **Persistent storage** | local disk | local disk | volume | disk add-on | volume | ❌ (ephemeral) |
| **TLS** | Caddy | Caddy | automatic | automatic | automatic | automatic |
| **Setup effort** | low (reuse) | low | moderate | low | low | high (arch changes) |
| **OS to maintain** | yes | yes | no | no | no | no |
| **Docker Compose** | yes | yes | no¹ | no¹ | no¹ | no¹ |
| **Recommended** | ✅ (existing) | ✅ (fresh) | ✅ (fresh) | ✅ (non-technical) | ⚠️ | ❌ |

¹ These platforms use their own deployment configuration rather than Docker Compose directly.
The project's `docker-compose.yml` is still useful as documentation of the intended topology,
but a platform-specific config file is also required.

---

## Recommendation

- **If the band already has an EC2 instance:** keep it and convert it to run the Docker Compose
  stack. The migration is a single session of work and the monthly cost is unchanged.

- **If starting fresh and the operator is comfortable with a terminal:** a Digital Ocean Droplet
  at $6/month is the simplest and cheapest VPS option.

- **If starting fresh and the operator prefers a dashboard over SSH:** Render offers the most
  approachable fully-managed experience, with flat predictable pricing and a straightforward
  hand-off story.

- **If cost is the primary concern on a fresh deployment:** Fly.io is the cheapest fully-managed
  option once the initial `flyctl` setup is complete.

- **Avoid Heroku** unless there is a compelling pre-existing reason to use it.
