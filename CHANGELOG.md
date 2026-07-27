# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

#### Tune catalogue (B1)

- `CatalogueExtractor` — maps the `Score` that CeolKit produced while rendering a file onto the
  catalogue's title and part-name fields. Returns a deduplicated, ordered list of part names;
  defaults to `["Full Score"]` when the file declares no voices.
- `AddSvgPathsToPart` migration — adds a nullable `svg_paths` TEXT column to the `parts` table.
  Stores a JSON-encoded `[String]` of absolute paths to the per-page SVG files produced during
  the build, so the binder pipeline can re-render them with a custom `startingPageNumber` without
  re-running CeolKit.
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

### Changed

#### ABC → SVG engine: ABCKit replaced by CeolKit

- The `abcm2ps`-backed [ABCKit](https://codeberg.org/sbeitzel/ABCKit) dependency is replaced by
  the pure-Swift [CeolKit](https://github.com/sbeitzel/CeolKit). `Package.swift` now depends on
  CeolKit's `CeolKitModel`, `CeolKitParser`, and `CeolKitSVGRenderer` products. No vendored C
  library remains in the dependency graph.
- `BuildService` conversion is now a two-step pipeline. Where it previously called a single
  `ABCConverter.convert(_:)`, it now calls `CeolKitParser.parse(_:options:)` to obtain a `Score`
  and then `SVGRenderer.render(_:)` to obtain the per-page SVG documents.
- `SVGRenderer.render(_:)` returns `[String]` — one complete SVG document per page — so the
  `splitSVGPages(_:)` helper that carved up ABCKit's concatenated return value is gone. The
  string-splitting workaround described under *Fixed* below is no longer needed at all.
- `I:abc-include` directives now resolve: the parser is constructed per file with the ABC file's
  own directory as its base directory, replacing ABCKit's `includedFiles:` argument.
- Bagpipe engraving is no longer a converter option. ABCKit took `bagpipeFormat: true` in its
  configuration; CeolKit reads `%%ceolkit:pipeformat true` from the ABC source, so the score
  files now own that decision.
- Parse diagnostics replace `abcm2ps` stdout/stderr in the build log. `BuildService` formats
  `error` and `warning` diagnostics with file, line, column, message, diagnostic code, and any
  hint, so the admin UI log viewer still explains a bad conversion.
- `Dockerfile`: the build and runtime images move from `swift:6.2-noble` to `swift:6.3-noble`,
  because CeolKit's manifest declares `swift-tools-version: 6.3`. The build stage now also
  stages every SwiftPM resource bundle next to the executable — `CeolKitSVGRenderer` loads the
  Bravura and Libertinus Serif fonts through `Bundle.module`, and every conversion throws
  without them. The stage asserts the CeolKit bundle is present so a packaging regression fails
  the image build rather than the first webhook.
- The app no longer parses ABC at all. The hand-rolled `ABCParser` — which scanned for `T:` and
  `V:` lines to populate the catalogue — is deleted in favour of `CatalogueExtractor`, which
  reads the `Score` CeolKit already produced to render the file. Each ABC file is now parsed
  once per build instead of twice, and three behaviours change as a result:
  - `V:2 nm="Harmony 1"` is now recognised. The old parser matched only the `name=` spelling,
    so `nm=` used to fall through and label the part with its bare voice ID.
  - A voice with `snm=` but no `nm=` is labelled with the short name rather than the voice ID.
  - Part names are collected across *every* tune in a file. The old parser scanned `V:` lines
    for the whole file without regard to which `X:` block they belonged to, which happened to
    produce the same union — but by accident rather than design.
- `Tune.title` for a multi-tune file (a medley) is documented as the first tune's title, which
  is what the previous scan produced and what the catalogue UI shows.
- `CeolKitModel` is no longer a declared dependency of the `App` target. Its `Tune` type would
  shadow-clash with the Fluent `Tune` model, so score values flow through without being named.
- `CatalogueExtractorTests` — covers title extraction, the `name=`/`nm=`/`snm=`/voice-ID
  fallback chain, the "Full Score" default, and part collection across multi-tune files.
- `ConversionPipelineTests` — first test coverage of the conversion pipeline. Exercises parse →
  render → PDF on an inline tune, asserts the one-SVG-document-per-page contract SVGPDFKit
  depends on, and checks that `I:abc-include` resolves against the parser's base directory. The
  render test also fails if the CeolKit font bundle is missing, so the packaging regression is
  caught in CI as well as in the image build.

### Fixed

#### SVG/PDF conversion pipeline

- Fixed a build/sync failure ("At least one SVGSource must be provided" / rsvg-convert XML
  parse error) caused by a fundamental misreading of the ABCKit return value, compounded by
  two secondary bugs:
  - **All pages mishandled** — ABCKit returns *all* pages as concatenated `<svg>…</svg>`
    documents in the return value (not just page 1 as the C header comment implies). The
    original code passed this to `collectSVGFiles` unused, so nothing was converted. The
    intermediate fix wrote the entire multi-page blob as a single file, giving rsvg-convert
    invalid XML ("Extra content at the end of the document").
  - **Wrong output file naming** — `svgOutputDirectory` was set to `outputDir + "/"` (trailing
    slash), which caused any disk files to use the generic `Out` prefix rather than the tune
    stem. The stem-prefix filter in `collectSVGFiles` therefore never matched any files.
  - **Dangerous cross-tune fallback** — when no stem-matching files were found,
    `collectSVGFiles` fell back to returning *all* SVGs in the directory, which would have
    mixed pages from different tunes on multi-file builds.
- The fix drops `svgOutputDirectory` entirely. ABCKit's return value (all pages concatenated)
  is split on `</svg>` into individual documents and each is written to its own numbered file
  (`<stem>000.svg`, `<stem>001.svg`, …). `collectSVGFiles` is replaced by `splitSVGPages`.

- Magic-link tokens are no longer consumed by Slack's link-preview bot. `AuthController` now
  returns a neutral HTML response (without marking the token used) when the request `User-Agent`
  contains `Slackbot`.

#### Persistent sessions

- Switched from in-memory sessions to Fluent-backed sessions (`app.sessions.use(.fluent)`).
  Session cookies now survive server restarts — authenticated admin users no longer need to
  re-login after a container restart or redeploy.
- `SessionRecord.migration` added as the first migration so the `_fluent_sessions` table is
  always present before any route handler attempts to read a session.

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

#### Catalogue sync — admin-triggered pull without Box upload

- `BuildService.syncCatalogue(branch:db:logger:)` — new public method that runs the full
  conversion pipeline (git pull → CeolKit → SVGPDFKit → Tune/Part upsert) but skips Box upload
  and Slack notification. Produces PDFs on disk so the binder builder works immediately after
  a sync. Creates a `Build` record (visible in the build history log) with a note that external
  services were skipped.
- Internally, `runBuild` and `syncCatalogue` now share a private `_performBuild` method
  parameterised by `uploadToBox` and `notifySlack` flags, eliminating code duplication.
- `POST /admin/branches/:branch/sync` — new admin-only route (guarded by
  `AdminAuthMiddleware`) that fires `syncCatalogue` as a background task and returns
  `202 Accepted`. Accepts branch names not yet in the database, enabling a first-time sync
  without waiting for a GitHub push event.
- Admin dashboard (`admin/index.leaf`) — two new UI elements in the Known Branches section:
  - **↻ Sync** button next to each existing branch badge; posts to the sync endpoint and
    shows inline status feedback.
  - Branch name text input + **↻ Sync branch…** button below the badges, for syncing a
    branch that does not yet appear in the Known Branches list.

#### Admin UI — user display names

- `SlackService.fetchDisplayName(for:)` — new method that calls `GET slack.com/api/users.info`
  with the bot token and returns the user's profile display name (falling back to real name, then
  nil). Requires the `users:read` bot scope already listed in the README setup.
- `SlackEventsController` now calls `fetchDisplayName` in the login-token background task and
  saves the result to `User.displayName`, refreshing it on every login-link request.
- The admin users page shows the Slack display name (falling back to the Slack user ID for
  accounts that have never requested a login link).

#### Admin UI — user management page and navigation

- `GET /admin/users` now renders an HTML page instead of returning a JSON array. The page
  shows all users in a table with inline controls: **Toggle role** (member ↔ admin) and
  **Delete**, both powered by JavaScript calls to the existing PATCH/DELETE JSON APIs. An
  **Add user** form at the bottom of the page calls `POST /admin/users`.  The authenticated
  user's own row shows "(you)" and has the action buttons disabled, matching the server-side
  self-protection rules.
- All three admin Leaf templates (`index`, `build-detail`, `users`) now share a consistent
  header navigation bar with links to **Dashboard** and **Users**.
