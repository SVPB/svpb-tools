# Issue draft — state-of-the-system review, 2026-07-26

Review of `develop` @ `76ed332` against PROJECT_PLAN.md. Edit or delete entries; once approved
these get filed with `gh issue create` and this file is removed.

Legend: **P0** blocks the product working at all · **P1** blocks the DO deployment ·
**P2** correctness/maintenance · **P3** polish

---

## P0-1 — Box upload is entirely unimplemented; builds still report success

**Labels:** `bug`, `phase-1`, `box`

`Sources/App/Services/BoxService.swift` is a skeleton. `refreshAccessToken`, `createYearFolder`,
and `uploadFile` all end in `throw Abort(.notImplemented, …)`, and `resolveYearFolder` ignores the
"does the folder already exist" path entirely — it calls `createYearFolder` unconditionally
(BoxService.swift:78-94). Every `Phase 1 TODO` comment in that file is still outstanding.

Feature C4 — "walk the output directory for freshly-built PDFs and upload them to Box" — is
therefore not delivered, even though README.md and CHANGELOG.md both describe it as working. This
is the distribution half of the product: without it, a push to `svpb-music` produces PDFs that
never leave the server.

Worse, the failure is silent from the operator's point of view. `BuildService._performBuild`
catches the upload error per file, appends a line to the build log, and continues
(BuildService.swift:182-190) — then unconditionally posts a **success** notification to Slack and
sets `build.status = .success` (BuildService.swift:216-232). A build in which zero of N files
reached Box shows up green in the admin dashboard and green in Slack.

**Work:**
- Implement the four TODOs against the Box REST API using the existing `httpClient`.
- Persist the rotated refresh token to the database. Right now `refreshToken` is only an actor
  property, so every restart falls back to the (eventually expired) `.env` seed value — the README
  already promises DB persistence, and BoxService.swift:110-112 acknowledges it as unfinished.
- Decide the failure policy: a build where uploads failed must not report success. Suggest a
  `partial` build status, or `failure` with the successful conversions still recorded.

---

## P0-2 — Build success/failure status does not reflect what actually happened

**Labels:** `bug`, `observability`

Broader than P0-1. `_performBuild` treats Box upload failure, Slack notification failure, and
catalogue upsert failure as warnings appended to the log; the build is marked `.success` as long as
the git pull and conversion did not throw (BuildService.swift:182-232). `BuildStatus` offers only
`running`/`success`/`failure`.

The admin dashboard is the only diagnostic surface for a band member with no SSH access (feature
C6/O4), so "green means it worked" needs to be true.

**Work:** add a `partial` case to `BuildStatus`, set it whenever any per-file step logged a
failure, and surface the distinction in `admin/index.leaf` and the Slack notification text.

---

## P1-1 — Music workspace is not mounted on a volume; all build output is lost on redeploy

**Labels:** `bug`, `deployment`

`docker-compose.yml:11` mounts the `music-workspace` named volume at `/workspace`, but
`.env.example:44` sets `MUSIC_WORKSPACE_PATH=/app/music`, and that env var is what
`configure.swift:131` feeds to `GitService`, `BuildService`, and `BinderService`.

Consequences on a real deployment:

- The cloned repo, the rendered SVGs, the per-part PDFs, and generated binder PDFs all land in the
  container's writable layer and are destroyed by every `docker compose up -d`.
- The named volume is created and stays empty forever.
- SQLite (on its own correctly-mounted volume) survives, so after a redeploy the `parts.svg_paths`
  rows point at files that no longer exist. `BinderService` then logs "part … has no SVG paths" or
  fails the conversion, and the binder builder is broken until someone runs a manual sync.
- Every redeploy also forces a full re-clone and re-render of the whole repository.

**Work:** mount `music-workspace` at `/app/music` to match `MUSIC_WORKSPACE_PATH`, and set the
variable in the compose `environment:` block so it cannot drift out of sync with the mount again.

---

## P1-2 — `docker compose pull` is a no-op; there is no published image

**Labels:** `deployment`, `docs`

`docker-compose.yml:4` uses `build: .`, so the README's documented update flow
(`git pull && docker compose pull && docker compose up -d`, README.md:274-279) does nothing on the
pull step and silently rebuilds from source instead.

Building in place also does not fit the recommended host: HOSTING_OPTIONS.md:68 recommends a 1 GB
droplet, but a Swift release build of this dependency graph needs several GB of RAM and 10–20
minutes of CPU.

**Work:** publish `linux/amd64` images to GHCR from CI and switch compose to `image:`. (Addressed
by the deployment change set alongside this review — keep the issue for tracking the README
rewrite.)

---

## P1-3 — No CI

**Labels:** `infrastructure`, `testing`

There is no `.github/workflows` directory. The 19 tests in `Tests/AppTests` only run when someone
remembers to run them locally, and nothing verifies the Linux build — which is the only build that
matters for deployment, and the one most likely to break given the macOS-only development loop.

**Work:** workflow that runs `swift build` + `swift test` in a `swift:6.3-noble` container on push
and PR.

---

## P1-4 — `Package.resolved` is gitignored, so production builds are not reproducible

**Labels:** `infrastructure`, `dependencies`

`.gitignore:15-18` excludes `Package.resolved`, with a comment about resolved-file format
differences across environments. But `Dockerfile:10-11` copies it (`Package.resolved*`) and runs
`swift package resolve` — with the file absent from a fresh clone, the image resolves whatever
satisfies `CeolKit from: 1.0.0` and `SVGPDFKit from: 0.2.0` **at image build time**.

Both of those are first-party repos under active development. A release to either can change what
production runs with no commit in this repository, and two builds of the same commit can differ.

**Work:** commit `Package.resolved`. The format concern is moot now that the only build that ships
is the CI Linux build.

---

## P1-5 — Box refresh token needs re-issuing before the first deploy

**Labels:** `operations`

Not a code defect — a checklist item. Box refresh tokens expire after 60 days of disuse
(README.md:253-257) and this project has been idle since March. Whatever is in the local
`.env.development` is dead; a fresh `box-auth` run is required to populate `BOX_REFRESH_TOKEN` on
the droplet. Note that this only matters once P0-1 is done, since nothing calls Box today.

---

## P2-1 — B2 (canonical binder definition) is not implemented at all

**Labels:** `enhancement`, `phase-2`, `binder`

PROJECT_PLAN.md:51 specifies that the pipe major commits a YAML binder definition to `svpb-music`,
that the server reads it from the working directory during the build, and that it is stored in
SQLite alongside the tune catalogue. None of this exists: there is no YAML parsing anywhere in
`Sources`, no `BinderDefinition` model, and no migration.

`binder-constructor.leaf` therefore produces YAML that nothing on the server ever consumes. The
page is useful as a human-authoring aid, but the "repository is the sole source of truth" half of
the design is missing.

**Work:** decide whether B2 is still wanted. If yes: model + migration, read during
`_performBuild`, and a way to view/print the canonical binder. If no: strike it from
PROJECT_PLAN.md and re-describe the constructor page as a standalone YAML authoring tool.

---

## P2-2 — No manual rebuild trigger

**Labels:** `enhancement`, `phase-3`, `admin`

PROJECT_PLAN.md:289 lists `POST /admin/builds/trigger`. What exists is
`POST /admin/branches/:branch/sync` (AdminController.swift:31), which deliberately skips Box upload
and Slack notification. There is no way to re-run a full build — including distribution — from the
admin UI, which is the documented recovery path when a build fails.

---

## P2-3 — No retry for Box or Slack (O6)

**Labels:** `enhancement`, `phase-3`

O6 specifies that when Box or Slack are unreachable, artefacts are retained locally and
re-upload/re-notify happens on the next build. There is no retry logic anywhere in `Sources`
(`grep -i retry` returns nothing) and no record of which files failed to upload, so a "retry on
next build" cannot be implemented without also tracking per-file upload state.

**Work:** track upload state per produced file, then reconcile at the start of the next build.
Depends on P0-1.

---

## P2-4 — Phase 3 hardening and handoff work is untouched

**Labels:** `phase-3`, `docs`

Beyond P2-2 and P2-3, the following Phase 3 items (PROJECT_PLAN.md:357-364) have no
corresponding code or documentation:

- Binder PDF cache cleanup — `<workspace>/binders/` grows without bound; nothing ever deletes a
  generated binder or its `BinderRequest` row.
- Integration test suite covering webhook → build → Box against a local mock.
- Operator runbook: deploying, rotating secrets, updating CeolKit/SVGPDFKit.
- Gen.1 migration notes: what to decommission and how to redirect the GitHub webhook.

Worth splitting into separate issues once P0/P1 are cleared.

---

## P2-5 — Documentation describes unbuilt behaviour

**Labels:** `docs`

README.md and CHANGELOG.md both present Box upload as a working feature, which sent this review
looking for bugs in code that turned out never to have been written. Specific corrections needed:

- README.md "How it works" step 3 and the Box section: mark upload as not yet implemented.
- README.md:245 gives the box-auth command as `docker compose run --rm tng swift run TNG box-auth`.
  The runtime image has no Swift toolchain and its ENTRYPOINT is already `./TNG`, so the correct
  invocation is `docker compose run --rm tng box-auth`.
- CHANGELOG.md's Unreleased section describes C4 as delivered.

---

## P3-1 — `Package.swift` declares tools version 6.2 while the toolchain floor is 6.3

**Labels:** `chore`

`Package.swift:1` says `swift-tools-version:6.2`, but CeolKit's manifest requires a 6.3 toolchain
to parse, which is why `Dockerfile:4` pins `swift:6.3-noble`. The manifest understates the real
requirement, so a contributor on 6.2 gets a confusing resolution error rather than a clear one.
`platforms: [.macOS(.v26)]` is also worth a second look — it is stricter than CeolKit's own
`.macOS(.v14)`.

---

## P3-2 — Compose `depends_on` is backwards and there is no healthcheck

**Labels:** `chore`, `deployment`

`docker-compose.yml:15-16` has the TNG service depend on Caddy; the actual dependency runs the
other way (Caddy proxies to TNG). Harmless — Caddy retries — but misleading. Neither service
declares a healthcheck, so `docker compose ps` cannot distinguish "running" from "serving", and
`/health` (O5) goes unused by the stack that ships it.

---

## P3-3 — `Public/openapi.yaml` has not been checked against the implemented routes

**Labels:** `docs`

Flagged for verification, not confirmed as wrong. The spec predates several route changes
(`/admin/branches/:branch/sync`, `/admin/users` returning HTML rather than JSON, the binder
endpoints), and nothing validates it against the router.
