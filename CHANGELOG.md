# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

#### Binder page numbering, which was inert (#19)

- A binder now re-engraves each tune from its ABC source with `%%ceolkit:pagenumber` set to the
  page it opens on, so the footer prints where the tune sits in *that* binder. Before this, every
  tune in an assembled binder restarted its footer at 1 — the one thing a binder needs to be
  usable in rehearsal was the thing that did not work.
- The old mechanism could not have worked. `BinderService` set
  `ConversionOptions.startingPageNumber`, which drives SVGPDFKit's `PageNumberInjector`, which
  rewrites a `<text id="svgpdfkit-page-number">` element that CeolKit does not emit — and returns
  the SVG unchanged, without error, when it finds none. Nor was there anything to rewrite:
  CeolKit's `textRendering` defaults to `.outlines`, so a footer is path geometry by the time a
  binder sees it, and the runtime image installs no fonts, so nothing downstream of CeolKit could
  draw a replacement either. The number has to be right when CeolKit draws it.
- `TunePageRenderer` (new) prepends the directive to a tune's ABC, after any `%abc` version line
  and before everything else, so a tune that sets its own page number still wins.
- Nothing in TNG dictates the footer itself; the music repository's style sheets do, and the
  directive moves both of their page-number tokens — `$P`, and the `${pagenumber}` mark CeolKit
  1.6 added (sbeitzel/CeolKit#137), whose default value is the same number. A binder wants that
  default drawn, so it needs nothing of the mark beyond CeolKit honouring the directive.
- A tune whose `%%footer` names neither token is engraved and numbered correctly and simply
  prints nothing — and nothing in the rendered pages can say so, because a drawn number is
  outlines like everything else. So the check reads the footer template rather than the output,
  and the build log names the tunes that print no number. Against `svpb-music` branch `2027`,
  that is 14 tunes over 20 of 107 pages: the ones still including `style.abh`, which carries no
  page-number token, rather than `ckstyle.abh`, which prints `Page ${pagenumber}`.
- Divider pages are counted but print no number, as a book's part titles are: the tune behind a
  divider is numbered as though the divider were a page, because it is one.
- A tune with no readable ABC source still reaches the binder, from the pages the build made of
  it. Those footers number from 1, which is logged at `error` — it is the silent version of the
  bug this change exists to fix, and it should not pass unremarked.
- `SVGPDFConverter` is now called with `injectPageNumbers = false` rather than left to perform a
  no-op. Filed upstream as sbeitzel/SVGPDFKit#3: a missed injection should not be silent.

### Added

#### The band's circuit thistle as the site icon

- `Brand/` holds vector traces of the circuit thistle — the mark beside the wordmark in the band
  logo — taken from artboard 5 of `SV_Pipeband_Logo_Final.ai` and coloured the way the thistle is
  coloured in the lockup: `#AA04BC` for the bloom, `#44C40E` for the leaves. `Brand/README.md`
  records where the artwork came from and which file to reach for.
- `Brand/slack-app-icon-512.png` is the 512x512 icon to upload for the TNG Slack app.
- `Public/favicon.ico` (16/32/48), `Public/favicon.svg` and `Public/apple-touch-icon.png`, linked
  from both the public layout and the admin sign-in page, which has its own `<head>`.
- Renderings at 48px and below scale the stroke weights 1.8x. The thistle is fine line art —
  strokes are about 1% of its height — and at true weight it disappears in a favicon.

### Changed

- The page header shows the thistle (`Public/img/thistle.svg`) in place of the music-note emoji.
  The header mark is transparent rather than white-backed, so it sits on the navy bar the way the
  reversed logo does in the `.ai`.

#### CeolKit 1.5.0 -> 1.6.0

#### Documentation reconciled with the deployment as built (#14)

- `HOSTING_OPTIONS.md` is marked as a superseded decision record. It compared hosts before one was
  chosen, and its DigitalOcean numbers never caught up with the deployment: it recommended the
  1 GB / $6 droplet (which does not survive a full catalogue build), said the boot disk meant "no
  additional storage product is needed" (persistent across reboots, not across droplet
  replacement — #3), called a Reserved IP a "Floating IP" (#2), and described updating as a
  by-hand `docker compose pull && up -d` (#6). Rather than maintain six costed alternatives for a
  decision that has been made, the header tabulates those four corrections and sends readers to
  README § Deployment; the comparison below it is frozen as of March 2026.
- The README's opening no longer offers `HOSTING_OPTIONS.md` as current hosting guidance; it
  points at § Deployment and labels the older document a superseded decision record.
- The `box-auth` entry under 0.2.0 gave `docker compose run --rm tng swift run TNG box-auth`,
  which cannot work — the runtime image has no Swift toolchain and its `ENTRYPOINT` is already
  `./TNG`. Corrected to `docker compose run --rm tng box-auth`, matching the README. The bare
  `swift run TNG box-auth` in the tunnel workflow is unchanged and still correct there.


## [0.2.0] - 2026-09-17

### Added

#### Admins can remove a branch (#33)

- `DELETE /admin/branches/:branch` (admin session required) and a **✕ Remove** button beside each
  branch on `/admin`, behind a confirmation that names the branch. It removes the branch's
  `binder_definitions`, `parts`, `tunes`, `builds` (including their logs) and `branches` rows in
  one transaction, then `<workspace>/<branch>/` and `<workspace>/output/<branch>/`. The response
  and the dashboard report the row counts and bytes freed; the server logs the same, with who asked.
- Box is not touched, and personalised binders (`<workspace>/binders/`) are left alone. Everything
  removed is derived, so syncing the branch again rebuilds it from the repository.
- Rows without directories, or directories without rows, remove cleanly; a branch with neither is
  `404`.
- A name that could escape the music workspace (empty, `.`, `..`, empty or absolute components,
  backslashes) or that collides with `output` or `binders` is rejected with `400` before anything
  is deleted.
- Builds and removals of the same branch now exclude each other in `BuildService`: removal is
  `409` while a build of that branch is running in this process, and a build that arrives mid-removal
  is logged and not started. This is tracked in memory rather than from `builds.status`, so a build
  left `running` by a crash does not block removal forever.

#### Official binder definitions read from `binders.yaml` (#10)

- Every build, and every catalogue sync, now reads `binders.yaml` from the root of the branch after
  conversion and stores its binders as `BinderDefinition` records (new `binder_definitions` table),
  replacing the branch's previous set in one transaction. This is the reading-and-persisting half
  of B2; assembling the binders is #18.
- `BindersFile` / `OfficialBinder` / `OfficialBinderSection` / `OfficialBinderEntry` decode the
  file with Yams (new dependency). Entries use `tune:`; `parts:` is optional and is kept through
  decoding and storage even though assembly will ignore it until per-part rendering lands (#20).
- A branch with no `binders.yaml` logs that and builds as before, with no official binders.
- A file that cannot be used marks the build partial and leaves the branch with no stored
  definitions rather than stale ones. The build log names the problem: YAML syntax errors by line
  and column, a wrong shape by key path (`binders[0].sections[1].entries[2]: missing key 'tune'`),
  and binders with a blank name, an `output` that is not a bare `.pdf` filename, or an `output`
  another binder already uses (compared case-insensitively).
- Entries naming a tune missing from the branch's catalogue are each logged with their binder and
  section, and mark the build partial, so a typo cannot silently drop a tune from a printed binder.
  The definition is still stored as written.
  
#### Scripted deploys (#6)

- `Scripts/deploy.sh` replaces the manual `git pull && docker compose pull && docker compose up -d`
  on the server. It waits for the publish workflow for the image tag's commit to succeed before
  pulling (pulling `develop` mid-publish silently fetches the old build), waits for the `tng`
  healthcheck after recreating and fails loudly if it does not pass, reports the running revision
  from the image's OCI label and fails if it is not the expected commit, and runs
  `docker image prune -f` so superseded builds do not fill the disk. `--no-wait` skips the build
  gate. README § Updating now points at the script.

#### Sections in personal binders (#29)

- A personal binder built on `/binder-builder` can now be divided into titled sections, and each
  titled section gets a divider page ahead of it in the generated PDF. Before this a personal
  binder was one undifferentiated run of tunes.
- `BinderSpec` carries `sections` (each an optional `title` and ordered `entries`) in place of the
  flat `entries` list. The nesting matches `binders.yaml`. The flat shape still decodes, as a
  single untitled section, so existing `binder_requests` rows and URLs shared before this change
  keep working; encoding always writes `sections`. `BinderSpec.entries` remains as a read-only
  view across all sections.
- `DividerPageRenderer` — renders a divider page as one Letter SVG page. The title is engraved by
  CeolKit as a title-only tune, so it is drawn as Libertinus Serif glyph outlines exactly like the
  tune pages, never as `<text>` resolved through a host font; the title is then moved to the
  upper-middle of the page and scaled up, or down to fit when long. Line breaks in a title are
  collapsed so they cannot inject ABC, and `%` and `\` are escaped as `\%` and `\\`, which CeolKit
  decodes from 1.5.0 (sbeitzel/CeolKit#145). Official binder assembly (#18) is meant to reuse it.
- `BinderService` inserts the divider ahead of a titled section's first page. A section that ends
  up with no pages (empty, or every tune missing from the catalogue) gets no divider, and a binder
  that would contain only dividers is not produced.
- The shared `TuneSelector` component models its selection as sections. Pages opt in with
  `sections: true`; the builder does, and gets section headers with an editable title, section
  reorder and remove (a removed section's tunes join its neighbour), a highlighted section that
  catalogue additions go into, per-tune arrows that carry a tune across a section boundary, and a
  move-to-section menu. The constructor does not opt in yet and behaves as before; its YAML
  output gains sections under #21.
- Share URLs now Base64-encode the spec's UTF-8 bytes, so titles and binder names outside
  Latin-1 no longer make `btoa` throw. URLs produced the old way still restore.

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
  - Invoked as described in the README: `docker compose run --rm tng box-auth`. The runtime
    image has no Swift toolchain and its `ENTRYPOINT` is already `./TNG`, so the subcommand is
    passed straight to the binary.

### Changed

#### Binder constructor writes `binders.yaml` (#21)

- `/binder-constructor` now emits the `binders.yaml` shape — a `binders:` root, `name`, `output`,
  titled `sections`, and entries keyed `tune:` — instead of the personal binder spec, which the
  build could not read. It writes a complete one-binder file; everything after its first line
  pastes onto the end of an existing file's list. Scalars are double-quoted, so slugs such as
  `yes` or `1990` stay strings.
- Sections are turned on for the constructor, and every section with tunes must be titled. Empty
  sections are left out.
- New output filename field, suggested from the binder name until edited, and checked as a bare
  filename ending in `.pdf`.
- Part tags are hidden and `parts:` is never emitted: an official binder takes each tune whole
  until per-part rendering lands (#20). `TuneSelector.init` gains `parts` and `untitledSections`
  options; the personal builder is unchanged (#24).
- New `POST /binder-constructor/check` runs YAML through the build's own decoder and catalogue
  check without storing anything. The page calls it after generating, and a **Check** button
  checks whatever is in the (now editable) text area, so a pasted `binders.yaml` can be checked too.

#### Shared tune-selection component (#30)

- The binder constructor and the personal binder builder no longer carry two copies of the
  tune-selection UI. `PROJECT_PLAN.md` (B4) claimed they shared a component; in fact it had been
  copy-pasted and the copies had drifted. The shared parts now live in one place:
  - `Public/js/tune-selector.js` — the `TuneSelector` module: catalogue load, search filter,
    the selection list, part tags, and the reorder/remove controls. Pages supply two hooks —
    `setStatus` (the constructor has one status style and ignores the severity argument, the
    builder styles it) and `onClear` (each page resets its own output) — plus an optional
    `restore` hook, which the builder uses to seed the selection from a shared `?spec=` URL.
  - `Resources/Views/partials/tune-catalogue.leaf`, `partials/binder-entries.leaf`, and
    `partials/tune-selector-styles.leaf` — the shared markup and CSS. Each page imports the
    two strings that genuinely differ (the binder-name label and the entries heading).
- Output generation stays with the page that owns it: `generateYAML` on the constructor,
  `requestPDF` / `buildSpec` / `shareURL` on the builder.
- `BinderPageTests` renders both pages and asserts the shared element IDs, headings, and styles
  survive the partials.

#### Persistent state on a detachable volume (#3)

- `docker-compose.yml` no longer keeps the database or Caddy's certificates in Docker `local`
  named volumes. Those live under `/var/lib/docker/volumes` on the host's boot disk, and a
  Digital Ocean droplet's boot disk cannot be detached — it is destroyed with the droplet. They
  are now bind mounts under `${TNG_STATE_DIR:-./state}`: `data/`, `caddy/data/`, and
  `caddy/config/`.
- `TNG_STATE_DIR` is a new optional setting. Unset, it resolves to `./state` in the checkout and
  local development is unaffected; on the droplet it is set to `/mnt/tng`, a Block Storage volume
  that survives the droplet.
- `music-workspace` remains a named volume. It holds the clone of the music repository and the
  rendered SVG/PDF output, all of which the next sync reproduces, and it is the bulky one.
- `README.md` gains a *Persistent state* section describing the layout — including `.env`, which
  now lives on the volume and is symlinked into the checkout — a volume-provisioning step in the
  Digital Ocean walkthrough, and a procedure for migrating an already-running droplet off its
  named volumes without losing the database.
- The Digital Ocean walkthrough now describes what actually happens on attach: Digital Ocean
  formats and mounts the volume at `/mnt/<volume-name>` (hyphens become underscores, so `tng-state`
  arrives at `/mnt/tng_state`) but writes **no** `/etc/fstab` entry, leaving a live-only mount that
  vanishes on the next reboot — after which the stack would create a fresh database on the boot
  disk and look perfectly healthy doing it. The steps check `lsblk -f` and `/etc/fstab` before
  touching anything, make `mkfs` conditional on there being no filesystem, and prove the fstab
  entry with an unmount/remount cycle rather than trusting it.

#### CeolKit 1.2.1 → 1.3.0

- `Package.swift` now requires CeolKit `from: "1.3.0"`. No application code changed; the build and
  the full test suite pass against it unmodified.
- 1.3.0 is CeolKit's polyphony release: `%%score` / `%%staves` staff plans are read and obeyed,
  voices sharing a staff are engraved as two parts, lyrics are drawn, and voice state (key, unit
  note length, accidental memory) is genuinely per-voice rather than leaking through a shared
  cursor. Multi-voice ABC in the music repository will therefore engrave differently — and more
  correctly — than it did under 1.2.1.
- This does **not** deliver per-part PDFs. `SVGRenderConfig` still has no voice-selection option, so
  a file is still rendered once, whole, and every `Part` row still points at that one score
  (SVPB/svpb-tools#20, deferred past MVP 2026). The per-voice model 1.3.0 introduces is what would
  make that feature feasible upstream.
- Footer page numbering is unchanged and still unusable across an assembled binder: `$P` numbers
  from the page's index within its own file, `%%ceolkit:pagenumber` is parsed but never applied
  (sbeitzel/CeolKit#138), and under `.outlines` there is no `<text>` element for SVGPDFKit to
  rewrite (sbeitzel/CeolKit#137, SVPB/svpb-tools#19).

#### Box now receives official binders only (docs)

- `PROJECT_PLAN.md` and `README.md` corrected: Box receives **only** the assembled official
  binder PDFs named in `binders.yaml`, a specially-named spec file committed to the root of each
  branch of the music repository. Per-tune PDFs are build intermediates that stay on the server,
  and personalised binders are downloaded straight from TNG and never reach Box.
- `binders.yaml` replaces the Gen.1 `Makefile` as the definition of the official binders. It
  declares one or more binders, each with an `output` filename and an ordered list of titled
  sections; the binder constructor page (`/binder-constructor`) is how its contents are authored.
- Core feature list restructured accordingly: C4 is now official binder assembly, C5 is the Box
  upload of those binders, and Slack notification / build log retention shift to C6 / C7.
- No code changes yet — `BuildService` still uploads each per-tune PDF, which now contradicts the
  plan.

#### ABC → SVG engine: ABCKit replaced by CeolKit

- The `abcm2ps`-backed [ABCKit](https://codeberg.org/sbeitzel/ABCKit) dependency is replaced by
  the pure-Swift [CeolKit](https://github.com/sbeitzel/CeolKit). `Package.swift` now depends on
  CeolKit's `CeolKitModel`, `CeolKitParser`, and `CeolKitSVGRenderer` products. No vendored C
  library remains in the dependency graph.
- CeolKit is pinned to 1.3.0, whose renderer defaults to `TextRendering.outlines`: glyphs are
  written into each SVG as `<path>` geometry in `<defs>`, drawn by `<use>`, with no `@font-face`
  block and no `<text>` element. The output no longer depends on the host's font environment, so
  the process-scope `CeolKitFonts.register()` call in `configure.swift` is gone.
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

- **Personal binder builder:** "Clear" left the tune catalogue showing "Added ✓" on every tune
  that had just been removed. The constructor refreshed the catalogue after clearing and the
  builder's copy did not; the shared component now always does (#30).

#### SVG/PDF conversion pipeline

- Scores rendered on Linux (i.e. every deployed build) came out with staff lines and stems but
  no noteheads, clefs, rests, or accidentals, and with body text in the wrong face.

  The cause was font resolution. CeolKit used to embed all three faces in every SVG as
  `@font-face` base64 data URIs, which is why the output looked right on macOS — there SVGPDFKit
  rasterises in-process through CoreGraphics against process-registered fonts. On Linux SVGPDFKit
  shells out to `/usr/bin/rsvg-convert`, and librsvg ignores `@font-face` entirely, resolving
  `font-family` only through fontconfig; `fc-match Bravura` in the old image returned DejaVu Sans,
  which has no glyphs at the SMuFL codepoints.

  Fixed upstream in CeolKit 1.2, and the fix removes the font environment from the problem rather
  than configuring it: `TextRendering.outlines` writes the glyph geometry into the document, so
  the same score rasterises identically everywhere. The interim workaround — installing the
  bundled faces into `/usr/local/share/fonts/ceolkit` and running `fc-cache` in both the
  Dockerfile and the CI job — is therefore gone, along with the `fontconfig` runtime package.
  What the image still needs is the CeolKit resource bundle itself, since the renderer reads the
  OTFs to extract outlines; the Dockerfile asserts all three faces shipped.

  `ConversionPipelineTests` could not have caught the original bug: it asserted only that the
  output began with `%PDF` and was over 1 kB, both true of a fontless render. It now asserts the
  outlines contract directly — the page defines Bravura and Libertinus Serif glyph outlines, every
  `<use>` resolves to one of them, and no `@font-face` or `<text>` is emitted. A companion test
  asserts the converted PDF embeds *no* fonts at all, since anything else means a run reached the
  page as host-resolved text; that one runs on Linux only, CoreGraphics vectorising every glyph
  regardless of how the SVG expressed it.

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

### Removed

#### openapi.yaml - no longer serving

 - The file documents the server API, but the only client, current or proposed, is the server
 itself. It doesn't make sense to keep paying the documentation tax to keep it up to date. If
 we ever see interest, we can regenerate the document then.
 
