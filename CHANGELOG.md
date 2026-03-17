# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

#### Tune catalogue (B1)

- `ABCParser` — pure-Swift parser that extracts `T:` (title) and `V:` (voice/part) fields from
  ABC notation files. Returns a deduplicated, ordered list of part names; defaults to
  `["Full Score"]` when no `V:` fields are present.
- `AddSvgPathsToPart` migration — adds a nullable `svg_paths` TEXT column to the `parts` table.
  Stores a JSON-encoded `[String]` of absolute paths to the per-page SVG files produced during
  the build, so the binder pipeline can re-render them with a custom `startingPageNumber` without
  re-running ABCKit.
- `CatalogueController` — unauthenticated read-only JSON API:
  - `GET /branches` — lists all known branches (years), newest first.
  - `GET /branches/:branch/tunes` — lists all tunes for a branch, sorted by slug.
  - `GET /branches/:branch/tunes/:slug` — returns tune detail including available parts.
- `CatalogueDTO` — `BranchDTO`, `TuneListItemDTO`, `TuneDetailDTO`, `PartDTO`, and
  `BinderStatusDTO` response types.
- `BuildService` now populates the tune catalogue after each file conversion: upserts `Tune` and
  `Part` records (including `svgPaths`) and ensures the `Branch` record exists before any
  `Tune` inserts (FK constraint).

#### Binder UI and API (B2–B6)

- `BinderService` actor — assembles personalised binder PDFs by collecting `Part.svgPaths` for
  each selected entry and passing them in order to `SVGPDFConverter`. Writes the result to
  `<musicWorkspace>/binders/<id>.pdf` and updates the `BinderRequest` record. Runs
  asynchronously; the HTTP handler fires-and-forgets and the client polls for completion.
- `BinderController` — routes for both the interactive HTML pages and the REST API:
  - `GET /binder-constructor` — YAML generator page for the pipe major.
  - `GET /binder-builder` — personal binder builder page; accepts an optional `spec` query
    parameter (Base64-encoded JSON) to restore a shared binder configuration.
  - `POST /binders` — accepts a `BinderSpec` JSON body, creates a `BinderRequest`, and kicks
    off background PDF generation. Returns `202 Accepted` with a `BinderStatusDTO`.
  - `GET /binders/:id` — returns current status (`pending` or `ready`) and a `downloadURL`
    once the PDF is ready.
  - `GET /binders/:id/download` — streams the generated PDF as an `application/pdf` attachment.
- `binder-constructor.leaf` — interactive YAML generator for the pipe major. Fetches the branch
  list and tune catalogue via the JSON API; lets the user browse, search, select, and reorder
  tunes and toggle individual parts; generates a YAML binder definition for copy-paste into
  `svpb-music`. No server-side state is created.
- `binder-builder.leaf` — personal binder builder. Same tune-selection UI as the constructor;
  adds a **Generate PDF** button (posts to `/binders`, polls for completion, presents a download
  link) and a **Share URL** button that Base64-encodes the binder spec into the page URL so the
  configuration can be bookmarked or sent to a section leader.

#### Box OAuth2 helper (operations)

- `BoxAuthCommand` — `box-auth` Vapor subcommand that runs the one-time Box OAuth2
  authorisation flow needed to obtain an initial refresh token:
  1. Validates `BOX_CLIENT_ID` and `BOX_CLIENT_SECRET` are set.
  2. Constructs and prints the Box authorisation URL.
  3. Starts a temporary HTTP server on the configured port (default 8080).
  4. Waits for Box to redirect to `/box-callback?code=…`.
  5. Exchanges the authorisation code for tokens via `POST https://api.box.com/oauth2/token`.
  6. Prints `BOX_REFRESH_TOKEN=<value>` for copy-paste into `.env`.
  - In `box-auth` mode `configure()` skips env-var validation and service initialisation, so the
    command works when only the Box credentials are present.
  - Invoked as described in the README: `docker compose run --rm tng swift run TNG box-auth`.

### Fixed

- Magic-link tokens are no longer consumed by Slack's link-preview bot. `AuthController` now
  returns a neutral HTML response (without marking the token used) when the request `User-Agent`
  contains `Slackbot`.

#### Box OAuth2 helper — `--redirect-base-url` option

- `BoxAuthCommand` now accepts a `--redirect-base-url` option that sets the public-facing URL
  Box redirects to after authorisation, independently of the address the server binds to. Use
  this when the server is behind a tunnel or reverse proxy (e.g. ngrok) where the external URL
  differs from `localhost`. Example:

  ```sh
  swift run TNG box-auth --redirect-base-url https://my-tunnel.ngrok-free.app
  ```

  The path `/box-callback` is appended automatically. When the option is omitted the behaviour
  is unchanged: the redirect URI defaults to `http://localhost:<port>`.

#### Admin UI — user management page and navigation

- `GET /admin/users` now renders an HTML page instead of returning a JSON array. The page
  shows all users in a table with inline controls: **Toggle role** (member ↔ admin) and
  **Delete**, both powered by JavaScript calls to the existing PATCH/DELETE JSON APIs. An
  **Add user** form at the bottom of the page calls `POST /admin/users`.  The authenticated
  user's own row shows "(you)" and has the action buttons disabled, matching the server-side
  self-protection rules.
- All three admin Leaf templates (`index`, `build-detail`, `users`) now share a consistent
  header navigation bar with links to **Dashboard** and **Users**.
