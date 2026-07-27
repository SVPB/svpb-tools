# SVPB Tools — Next Generation (TNG) Project Plan

## Executive Summary

TNG replaces the fragile, multi-tool Gen.1 pipeline with a single, self-contained web service that any
technically-inclined band member can deploy and maintain. The core principle is that the server
should require **no specialist knowledge** to run: one `docker compose up` command should be
sufficient to have a working system.

The two headline improvements over Gen.1 are:

1. **Simplified operations** — ABC-to-PDF conversion is handled entirely in-process by two Swift
   libraries ([CeolKit] and [SVGPDFKit]), so the server has no external build-tool dependencies
   whatsoever. The only runtime requirement is Docker for the compose stack itself.

2. **Personalised binders** — Band members can assemble a custom PDF that contains only the parts
   they need, with page numbers that reflect *their* binder rather than the master copy.

---

## Background and Constraints

- Source music is stored in ABC notation in the [svpb-music] GitHub repository.
- Conversion from ABC → SVG is handled in-process by [CeolKit] (a Swift library).
- Conversion from SVG → PDF is handled in-process by [SVGPDFKit] (built on SwiftDraw +
  CoreGraphics).
- Finished PDFs are distributed via a shared Box folder.
- Band members are notified via Slack.
- The operator of the server **should not** need to understand Apache, certbot, Perl, or make.

---

## Feature List

### Core — Automated Build Pipeline

| # | Feature | Description |
|---|---------|-------------|
| C1 | GitHub webhook receiver | An HTTPS endpoint that accepts `push` events from GitHub. Validates the shared webhook secret before acting. |
| C2 | Repository sync | On a valid webhook event, pull (or clone) the latest state of `svpb-music` into a working directory on the server. |
| C3 | In-process conversion | For each changed ABC file, invoke `CeolKit` (configured for one SVG per page) to produce a sequence of per-page SVG documents, then pass them as an ordered list of `SVGSource` values to `SVGPDFKit` to produce a per-part PDF. Both steps run inside the server process — no external tools or containers required. |
| C4 | Box upload | Walk the output directory for freshly-built PDFs and upload them to Box via the Box REST API. PDFs are placed in a year-named subfolder of `pipe_music` (e.g. `pipe_music/2026/`) matching the git branch. If the subfolder does not yet exist it is created automatically via the Box API before uploading. Replaces any previous version of the same file within that folder. |
| C5 | Slack notification | Post a build-summary message to the configured Slack channel (success / failure, list of changed files, link to Box folder). |
| C6 | Build log retention | Store the stdout/stderr of each build locally, accessible via the admin UI, so failures can be diagnosed without SSH access. |

### Binder — Personalised PDF Assembly

| # | Feature | Description |
|---|---------|-------------|
| B1 | Tune catalogue | The server parses the ABC source files after each build and maintains a SQLite catalogue of every tune and every named part/voice within it, scoped to the branch (year) that was just built. The same tune slug may appear in multiple branches with differing arrangements. |
| B2 | Canonical binder definition | The pipe major defines the official band binder as a YAML file committed to the relevant branch of `svpb-music`. The repository is the sole source of truth; the server reads this file from the working directory during the build — after the repo is pulled but before conversion results are persisted — and stores the binder definition in SQLite alongside the tune catalogue. |
| B3 | Binder constructor (UI) | A web page that lets the pipe major assemble a binder interactively — browsing the tune catalogue, selecting parts, and setting the order — and then displays the resulting YAML for copy-paste into the repository. The page never commits anything itself; the pipe major remains in control of what lands in source control. |
| B4 | Personal binder builder (UI) | A web page where any band member can browse the tune catalogue, select the specific parts they need, reorder them, name the binder, and request a PDF. No login required — a shareable URL encodes the binder definition. The binder constructor (B3) and the personal binder builder share the same tune-selection UI component; they differ only in their output (YAML vs. PDF). |
| B5 | Personalised PDF generation | Given a binder definition, the server assembles the pre-built per-part PDFs for the selected entries and passes them to `SVGPDFKit` with a `startingPageNumber` offset, so footers reflect position within the *personal* binder rather than the master. No re-conversion from ABC is needed — the part PDFs produced during the build step are reused directly. |
| B6 | Binder download link | The generated personalised PDF is served directly from the TNG server as a download. It is not pushed to Box (Box is for official band copies only). |
| B7 | Binder URL sharing | A binder definition can be encoded in a URL so a band member can share their configuration with a section leader or print it later without re-selecting everything. |

### Authentication — Slack-based session login

Band members and administrators authenticate by messaging the TNG Slack bot. No passwords are
managed by TNG itself; identity is delegated entirely to the band's Slack workspace.

| # | Feature | Description |
|---|---------|-------------|
| S1 | Slack Events API listener | `POST /slack/events` receives message events from Slack. Request signatures are validated with HMAC-SHA256 using `SLACK_SIGNING_SECRET` — the same approach already used for the GitHub webhook. On first registration, Slack sends a `url_verification` challenge that the endpoint echoes back. |
| S2 | Magic-link token generation | When the bot receives any direct message it generates a single-use `LoginToken` (UUID, 10-minute expiry, tied to the sender's Slack `user_id`) and replies with a personalised login link. |
| S3 | Token redemption and session | `GET /auth/token/{token}` validates the token (exists, not expired, not yet used), marks it used, and sets a signed session cookie identifying the user by Slack `user_id`. |
| S4 | Session-protected admin routes | All `/admin/*` routes require a valid session cookie. The authenticated user must have the `admin` role; others receive 403. This replaces HTTP Basic Auth entirely. |
| S5 | User table with roles | A `User` record is created automatically on first login if one does not already exist for that Slack `user_id`. Users have a role of either `admin` or `member`. Existing admins can promote or demote users through the admin UI. |
| S6 | Initial admin bootstrap | On first startup, if the `User` table is empty, TNG creates one `admin` User for the Slack user ID specified in `INITIAL_ADMIN_SLACK_USER_ID`. This replaces the `ADMIN_PASSWORD` environment variable from earlier designs. |

### Operations and Administration

| # | Feature | Description |
|---|---------|-------------|
| O1 | Single-command startup | `docker compose up` starts the entire system. A `docker-compose.yml` is provided alongside the server image. |
| O2 | Environment-variable configuration | All secrets and settings (GitHub webhook secret, Box credentials, Slack webhook URL, repo URL) are configured via environment variables or a `.env` file — no config files inside the container to edit. |
| O3 | Automatic TLS | TLS termination is handled by [Caddy](https://caddyserver.com/) (included in the compose stack), which obtains and renews Let's Encrypt certificates automatically. No `certbot` cron jobs. |
| O4 | Admin dashboard | A minimal web page showing: last build status, build history, links to build logs, and a trigger for a manual rebuild. Access is controlled by session authentication (see S1–S6 below). |
| O5 | Health endpoint | `GET /health` returns 200 OK with a JSON payload of server state, suitable for an uptime monitor. |
| O6 | Graceful error handling | If Box or Slack are unreachable the build artefacts are retained locally and re-upload/re-notify is retried on the next build. The failure is surfaced in the admin dashboard. |

---

## Technical Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    docker compose stack                 │
│                                                         │
│  ┌──────────┐   HTTPS    ┌─────────────────────────┐    │
│  │  Caddy   │ ◄────────► │      TNG Server         │    │
│  │ (TLS +   │            │  (Swift / Vapor)        │    │
│  │  proxy)  │            │                         │    │
│  └──────────┘            │  • Webhook handler      │    │
│                          │  • CeolKit (ABC→SVG)    │    │
│                          │  • SVGPDFKit (SVG→PDF)  │    │
│                          │  • Binder builder UI    │    │
│                          │  • Admin dashboard      │    │
│                          │  • Box & Slack clients  │    │
│                          └─────────────────────────┘    │
│                                                         │
│  Named volume: /music-workspace (cloned repo + PDFs)    │
└─────────────────────────────────────────────────────────┘
         │                        │
         ▼                        ▼
    Box Drive              Slack Channel
  (official PDFs)         (build notices)
```

### Component Choices

**Language / Framework:** Swift 6 + [Vapor 4](https://vapor.codes/)

- Vapor is the most mature Swift web framework, with built-in async/await support, routing,
  middleware, and WebSockets.
- Swift compiles to a single native binary; the final Docker image can be kept very small using
  a multi-stage build (builder stage: `swift:6.3-noble`, runtime stage: `swift:6.3-noble-slim`).
- Vapor's structured concurrency model makes it straightforward to run background build jobs
  without blocking the HTTP server.

**ORM / Data Store:** SQLite via [Fluent](https://docs.vapor.codes/fluent/overview/) +
[FluentSQLiteDriver](https://github.com/vapor/fluent-sqlite-driver)

- Zero-dependency, zero-configuration relational store — part of the standard Vapor ecosystem.
- Stores build history, logs, and the cached tune catalogue.
- The database file lives on a Docker volume so it survives container restarts.

**ABC → SVG Conversion:** [CeolKit](https://github.com/sbeitzel/CeolKit)

- Pure-Swift ABC parser and engraver — no vendored C library and no external binary. Replaces
  the `abcm2ps`-backed ABCKit used earlier in the project's life.
- Consumed as two of its four library products: `CeolKitParser` (ABC text → `Score`) and
  `CeolKitSVGRenderer` (`Score` → SVG). `CeolKitModel` is deliberately *not* a declared
  dependency — its `Tune` type would shadow-clash with the Fluent `Tune` model, so score values
  flow through the app without their types ever being named.
- Public API is a two-step pipeline rather than a single `convert` call:
  1. `CeolKitParser(for:fileResolver:).parse(_:options:)` returns a `ParseResult` carrying a
     `Score` and an array of `Diagnostic` values. The `for:` base directory is what makes
     `I:abc-include` references resolve, so it is set to the ABC file's own directory.
  2. `SVGRenderer(config:).render(_:)` takes that `Score` and returns `[String]` — **one
     complete SVG document per page**. This gives SVGPDFKit a one-to-one mapping of SVG inputs
     to PDF pages, making `startingPageNumber` injection precise and unambiguous.
- Configured via `SVGRenderConfig` (page size, margins, staff size, system/tune gaps, flag and
  slur styling). Bagpipe-specific engraving is no longer a converter flag: it is driven from the
  ABC source itself with `%%ceolkit:pipeformat true`, so the score files own that decision.
- Diagnostics replace the stdout/stderr that `abcm2ps` used to emit. `BuildService` formats the
  `error` and `warning` entries into the build log, which is what the admin UI shows for a
  failed or suspicious conversion.
- `CeolKitSVGRenderer` ships the Bravura (music) and Libertinus Serif (text) fonts as a SwiftPM
  resource bundle loaded through `Bundle.module`. The bundle must be deployed **alongside the
  executable** — see the staging step in the `Dockerfile`, without which every conversion throws.
- CeolKit's manifest declares `swift-tools-version: 6.3`, which sets the floor for the Docker
  build image (`swift:6.3-noble`). Its `platforms` declaration (`.macOS(.v14)`) does not exclude
  Linux; in Swift Package Manager a minimum macOS version implies Linux compatibility.

**SVG → PDF Conversion and Binder Assembly:** [SVGPDFKit](https://github.com/sbeitzel/SVGPDFKit)

- Swift package built on SwiftDraw + CoreGraphics; supports both macOS and Linux.
- Public API: `SVGPDFConverter` struct; call `convert(sources:)` with an array of `SVGSource`
  values (`.data(Data)` accepts in-memory SVG output directly from CeolKit) and receive a `Data`
  blob containing the finished PDF.
- `ConversionOptions.startingPageNumber` is used directly for personal binder page numbering:
  each binder request calculates the correct offset and passes it in, so footer page numbers
  automatically reflect position within the personal binder rather than the master.

**TLS / Reverse Proxy:** [Caddy](https://caddyserver.com/)

- Handles HTTPS automatically with zero configuration beyond a domain name.
- Eliminates the certbot dependency from Gen.1.

**HTTP Client (for Box and Slack):** [AsyncHTTPClient](https://github.com/swift-server/async-http-client)
(part of the Swift on Server ecosystem)

- Used to call the Box REST API directly via OAuth2 (the same credentials already in use by the
  Gen.1 toolchain, so no new Box admin work is required). No official Swift SDK exists; the REST
  API is straightforward and well-documented.
- Used to POST to the Slack Incoming Webhook URL.

**Slack Integration:** Incoming Webhook URL (no OAuth app required for notifications)

---

## Data Model

Because the arrangement of a tune can differ from year to year (e.g. the last two measures of
"Archie Beag" may be rewritten between 2025 and 2026), the printable identity of any piece of
music is **tune slug + part name + branch**, where a git branch is the proxy for a year. The
data model reflects this three-part key throughout.

> **Note on UUIDs and SQLite:** SQLite has no native UUID column type. All UUID values are
> stored as TEXT (the standard lowercase hyphenated representation, e.g.
> `550e8400-e29b-41d4-a716-446655440000`). Fluent's SQLite driver handles this conversion
> automatically when the Swift model field is typed as `UUID`.

```
Branch
  name        TEXT  PRIMARY KEY   -- git branch name, used as year proxy, e.g. "2025", "2026"
  last_built  DATETIME            -- timestamp of the most recent successful build
  head_sha    TEXT                -- commit SHA at last successful build

Tune
  id          TEXT  PRIMARY KEY   -- UUID, stored as TEXT in SQLite
  branch      TEXT  NOT NULL      -- FK → Branch.name
  slug        TEXT  NOT NULL      -- derived from ABC filename, e.g. "archie_beag"
  title       TEXT                -- human-readable title from ABC T: field
  abc_path    TEXT                -- path within the repo on this branch
  updated_at  DATETIME
  UNIQUE (branch, slug)           -- same tune name may exist on multiple branches

Part
  id          TEXT  PRIMARY KEY   -- UUID, stored as TEXT in SQLite
  tune_id     TEXT  NOT NULL      -- UUID FK → Tune.id
  name        TEXT  NOT NULL      -- e.g. "Melody", "Harmony 1", "Harmony 2"
  pdf_path    TEXT                -- path to the pre-built single-part PDF for this branch
  -- Composite natural key: (tune.branch, tune.slug, part.name)

Build
  id          TEXT  PRIMARY KEY   -- UUID, stored as TEXT in SQLite
  branch      TEXT  NOT NULL      -- FK → Branch.name
  triggered   DATETIME
  commit_sha  TEXT
  status      TEXT                -- "running" | "success" | "failure"
  log         TEXT
  files       TEXT                -- JSON list of output PDF filenames

BinderRequest
  id          TEXT  PRIMARY KEY   -- UUID, stored as TEXT in SQLite
  definition  TEXT                -- JSON-encoded binder spec (see below)
  created_at  DATETIME
  pdf_path    TEXT                -- NULL until generation completes

User
  id              TEXT  PRIMARY KEY   -- UUID, stored as TEXT in SQLite
  slack_user_id   TEXT  NOT NULL      -- Slack user ID, e.g. "U012AB3CD"
  display_name    TEXT                -- Slack display name at time of last login
  role            TEXT  NOT NULL      -- "admin" | "member"
  created_at      DATETIME
  last_login_at   DATETIME
  UNIQUE (slack_user_id)

LoginToken
  id              TEXT  PRIMARY KEY   -- UUID, stored as TEXT in SQLite; also the URL token
  slack_user_id   TEXT  NOT NULL      -- Slack user ID this token was issued for
  expires_at      DATETIME NOT NULL
  used_at         DATETIME            -- NULL until redeemed; single-use enforcement
```

**Binder spec (JSON):**

The `branch` field anchors the entire binder to a specific year's arrangements. Each entry
identifies a tune by its slug (stable across years) and one or more parts by name. Together,
`branch + tune_slug + part` uniquely identifies the exact PDF to include.

```json
{
  "name": "My Binder - March 2026",
  "branch": "2026",
  "entries": [
    { "tune_slug": "archie_beag",        "parts": ["Harmony 1"] },
    { "tune_slug": "scotland_the_brave", "parts": ["Melody", "Harmony 1"] }
  ]
}
```

> **Note:** A binder is scoped to a single branch. If a musician needs tunes from two different
> years (an unusual edge case), they would generate two separate binders and combine them
> manually. Multi-branch binders are out of scope for TNG.

---

## API Surface

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/webhook/github` | GitHub push webhook receiver |
| `GET`  | `/health` | Health check |
| `GET`  | `/branches` | List all known branches (years) |
| `GET`  | `/branches/{branch}/tunes` | List all tunes in the catalogue for a given branch |
| `GET`  | `/branches/{branch}/tunes/{slug}` | Tune detail including available parts for that branch/year |
| `GET`  | `/binder-constructor` | Interactive YAML generator for the pipe major |
| `POST` | `/binders` | Submit a binder spec; returns a binder ID |
| `GET`  | `/binders/{id}` | Binder status (pending / ready) |
| `GET`  | `/binders/{id}/download` | Download the generated PDF |
| `POST` | `/slack/events` | Slack Events API receiver (bot messages + url_verification challenge) |
| `GET`  | `/auth/token/{token}` | Redeem a login token; sets session cookie |
| `GET`  | `/admin` | Admin dashboard (session auth, admin role required) |
| `GET`  | `/admin/builds` | Build history (session auth, admin role required) |
| `POST` | `/admin/builds/trigger` | Manually trigger a rebuild (session auth, admin role required) |
| `GET`    | `/admin/users` | List users and roles (session auth, admin role required) |
| `POST`   | `/admin/users` | Create a new user by Slack user ID with a specified role (session auth, admin role required) |
| `PATCH`  | `/admin/users/{id}` | Update a user's role (session auth, admin role required) |
| `DELETE` | `/admin/users/{id}` | Remove a user (session auth, admin role required) |

---

## Implementation Phases

### Phase 0 — Skeleton (1–2 days)

- Repository scaffolding: `Package.swift`, multi-stage `Dockerfile`, `docker-compose.yml`,
  `Caddyfile`.
- Vapor app with `/health` and `/webhook/github` stub routes.
- GitHub webhook validation (HMAC-SHA256 using `Crypto` from Swift Crypto).
- Environment variable loading and validation at startup (using Vapor's `Environment` API).
- README with setup instructions (< 10 steps, no specialist knowledge required).

### Phase 1 — Automated Build Pipeline (C1–C6) (3–5 days)

- Implement `git pull` / `git clone` of `svpb-music` via `Foundation.Process` on webhook receipt.
- For each ABC file in the working directory, parse it with `CeolKitParser` and render the
  resulting `Score` with `CeolKitSVGRenderer.SVGRenderer`, which yields an ordered sequence of
  per-page SVG strings. Pass them as `[SVGSource]`
  to `SVGPDFKit.SVGPDFConverter` to produce a single per-part PDF; write it to the named volume.
  Both conversions run in a Swift structured-concurrency task group so files are processed
  concurrently without blocking the HTTP server.
- Persist `Build` records and captured diagnostic output in SQLite via Fluent models.
- Upload output PDFs to Box using direct REST API calls via AsyncHTTPClient.
- Post Slack notification (success/failure summary) via Incoming Webhook.
- Admin dashboard (Leaf templated HTML) with build history and log viewer.
- Slack Events API handler (`POST /slack/events`): verify Slack request signature (HMAC-SHA256
  with `SLACK_SIGNING_SECRET`), handle `url_verification` challenge, dispatch DM events to the
  token-generation flow.
- `LoginToken` and `User` Fluent models; database migrations for both.
- On first startup (empty `User` table), seed an admin `User` from `INITIAL_ADMIN_SLACK_USER_ID`.
- Token generation: create a `LoginToken`, call `chat.postMessage` via AsyncHTTPClient to reply
  with the login link.
- Token redemption (`GET /auth/token/{token}`): validate and mark used; establish Vapor session.
- Session middleware applied to all `/admin/*` routes; role check (`admin`) returns 403 for
  authenticated non-admins.
- User management endpoints (`GET /admin/users`, `POST /admin/users`, `PATCH /admin/users/{id}`,
  `DELETE /admin/users/{id}`) for creating, promoting, demoting, and removing members.

### Phase 2 — Tune Catalogue and Binder UI (B1–B6) (5–7 days)

- Tune titles and part names are taken from the `Score` that CeolKit already produced to render
  the file — `CatalogueExtractor` maps them onto catalogue fields and the app parses no ABC
  itself. Upsert `Branch`, `Tune`, and `Part` Fluent models after each successful build, keyed on
  `(branch, slug)` so that year-specific arrangements are stored and queried independently.
- Shared tune-selection UI component (plain HTML + vanilla JavaScript, rendered via
  [Leaf](https://docs.vapor.codes/leaf/overview/) templates): browse/search tunes, select parts,
  drag to reorder, name the binder. Used by both pages below.
- **Binder constructor page** (`/binder-constructor`): renders the shared component with a
  "Generate YAML" button. On click, the YAML is rendered in a read-only `<textarea>` for the
  pipe major to copy and commit to the `svpb-music` branch. No server-side state is created.
- **Personal binder builder page** (`/binder-builder`): renders the same shared component with
  a "Generate PDF" button. Also produces a shareable URL (Base64-encoded binder spec) so the
  configuration can be bookmarked or sent to a section leader. Polls `GET /binders/{id}` for
  completion, then presents a download link.
- Binder generation backend:
  - Look up the pre-built per-part PDF paths from the `Part` table for each binder entry.
  - Feed the PDFs as `SVGSource.fileURL` inputs to `SVGPDFConverter`, setting
    `startingPageNumber` to the correct offset for this binder (calculated by summing page
    counts of preceding entries).
  - Persist the completed `BinderRequest` record; serve the PDF via a streaming Vapor `Response`.

### Phase 3 — Hardening and Handoff (2–3 days)

- Retry logic for Box uploads and Slack notifications.
- Admin dashboard: manual rebuild trigger, binder PDF cache cleanup.
- Integration test suite covering the webhook → build → Box flow (using a local mock).
- Operator runbook: how to deploy, how to rotate secrets, how to update CeolKit or SVGPDFKit dependencies.
- Migration notes from Gen.1 (what to decommission, how to redirect the GitHub webhook).

---

## Out of Scope (for now)

- **User authentication for band members** — the binder URL is the "credential"; there are no accounts.
- **Editing ABC files through the UI** — source control (GitHub) remains the authoring tool.
- **Mobile app** — the web UI should be usable on a phone, but no native app is planned.
- **Multiple bands / repositories** — TNG is scoped to SVPB. Multi-tenancy is a future concern.

---

## Success Criteria

- A new operator can go from zero to a running TNG server in under 30 minutes following the README.
- A push to `svpb-music` on GitHub results in updated PDFs in Box and a Slack message within
  5 minutes, with no manual intervention.
- A band member can generate and download a personalised binder PDF in under 2 minutes from a
  browser, without installing any software.
- The system can be maintained (upgraded, restarted, debugged) by anyone comfortable with
  `docker compose` — no Linux administration expertise required.

---

[svpb-music]: https://github.com/SVPB/svpb-music
[CeolKit]: https://github.com/sbeitzel/CeolKit
[SVGPDFKit]: https://github.com/sbeitzel/SVGPDFKit
