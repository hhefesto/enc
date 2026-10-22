# Dashboard and deployment cache review — 2026-09-21

This entry supersedes the older rollout status below. Dashboard security and
statistics work from review base `d945d39` is now in `3599898`; subsequent
published changes through `16253c2` add curriculum links, presentation edits
and prover-slot counts. Those later changes are retained.

## Production assessment

The user reported a short in-page 404, then successful dashboard login followed
by the normal game page. Read-only production checks found:

- Refl restarted cleanly at 10:59:34 CST and remained active. No matching
  HTTP 404 appeared among the day's requests carrying a Refl referrer.
- Unauthenticated `/dashboard/` returned 401 with the Basic-auth challenge.
  The configured credential returned 200 for both `/dashboard/` and
  `/dashboard/data.json`, at the origin and through Cloudflare. The credential
  was consumed on the host without printing it or putting it in arguments.
- The current CDN JavaScript matched the deployed bundle byte for byte.
  However, `/all.js` used a fixed name and was cached for four hours, while
  Nix store files reported an invariant 1970 modification time. Date-only
  revalidation returned 304. A stale client can show the game at `/dashboard/`;
  clients predating the donation route also show an in-page 404 at `#/donate`.

An authenticated clean Chromium session on September 21 rendered all six
metric tiles and range controls on the live site before this fix was deployed.
This confirms that the dashboard itself worked with the then-current client.
The browser's historical fragment/cache contents were unavailable, so the
exact earlier 404 remains unconfirmed. Server authentication is working;
stale client code is consistent with both reports.

## Cache correction

The built entry document now references `/all-<SHA256>.js`. The legacy
`/all.js` remains available for compatibility. HTML entry responses use
`Cache-Control: no-store` and bypass both static middleware and Warp's
file-mtime conditional responses. Dashboard responses retain their stronger
`private, no-store` header and authentication boundary.

Smoke checks verify that the referenced bundle's bytes match its filename,
that both game and dashboard HTML use that URL, and that a 1970
If-Modified-Since request still returns the current HTML with 200. Browser
checks block the old `/all.js` URL while exercising game, dashboard, themes,
mobile layout, request races, errors/retry and all prover flows.

## Retained analytics semantics

Completions are distinct `(browser identity, lesson, language)` tuples per
UTC period; Agda and Lean count separately. Checking establishes an opening.
Bots and unclassified legacy events are excluded from browser metrics.
Referrers, routes and language/lesson identifiers are sanitized on recording
and historical reads, without automatically rewriting old logs. Full UTC
collection days receive `.covered` sidecars; incomplete coverage suppresses
percentage comparisons. Retention stays 400 days, insufficient for a yearly
comparison. Active browsers means identities seen in the last five minutes,
with minute heartbeats from visible tabs, deduplication across tabs and daily
peaks. Heartbeats do not inflate navigation or completion counts.

## Verification and consumer build

Published fix: `0392db026c8c381e0a8a20cbba54aef9f6fb3581`.
Native suites passed 98 examples; full flake checks passed. Isolated host
verification passed 128 content checks, Chromium dashboard and game checks,
all three provers including Lean outside the sandbox, and security checks.
Evidence is in `/tmp/refl-dashboard-cache-native.log`,
`/tmp/refl-dashboard-cache-flake-verified.log` and
`/tmp/refl-dashboard-cache-isolated-verified.log`.

Only the consumer's refl lock node was updated to the published fix. Other
lock nodes and the existing flake.nix, olimpo.nix and workstation configuration
were verified unchanged. `nixos-rebuild build` succeeded for Olimpo:
`/nix/store/5pqsarm94r0famym0nk8psmx98hamnbi-nixos-system-olimpo-26.11.20260919.20b1ddd`.
Log: `/tmp/refl-cache-olimpo-build.log`. Local activation remains the user's
`ns`; this agent did not switch Olimpo.

## Rollout and rollback

The user authorized production deployment on September 21. The production
candidate is
`/nix/store/lr6j88jqwfnnrzfabzp81a1zwmklclb8-nixos-system-xty-26.11.20260919.20b1ddd`.
Before activation, the backup integrity, pure configuration and live health
gates passed. Recursive comparison of the entire generated `/etc` differs
only for `refl.service` and its target link. The NixOS dry activation explicitly
listed only stopping and starting `refl.service`. Encrypted password bytes
are unchanged. The guarded deployment script checks the exact running system,
profile and dry activation output before switching. Activation succeeded;
only Refl was stopped/started as a system service. NixOS also ran its standard
user activation units and sysinit-reactivation target. Protected nginx,
PostgreSQL, networking and application service PIDs, start timestamps and
restart counts are unchanged.

Production now runs the candidate above. Authenticated origin and public
dashboard HTML/data requests return 200. A clean Chromium session renders all
six metric tiles and the range controls. Public HTML contains the fingerprinted
bundle and `Cache-Control: no-store`; a date-only conditional request returns
200. Evidence: `/tmp/refl-cache-deploy.log`, `/tmp/refl-cache-auth-after.log`
and `/tmp/refl-cache-live-browser-after.log`.

The remote directory `/var/backups/refl/cache-fix-20260921` (root-only) contains
the Refl state backup, previous system/profile paths, dry activation output,
activation log and protected-service comparisons. The previous system and
deploy-rs profile are retained as GC roots. The deployment script is
`/tmp/refl-cache-deploy.sh`; it fails closed on an unexpected activation plan.
No automatic whole-system rollback was enabled.

Only the consumer's refl lock node may change; preserve its unrelated edits
and dependency pins. The pre-fix lock is `/tmp/refl-cache-consumer-before.lock`,
pinning `16253c2c85936fdbf68f54b6dc728095ea61695d`. Re-pin that node on the
current consumer and rebuild for a refl-only rollback, accepting that it
restores the cache issue. Keep player state and analytics data. Do not use a
whole-system rollback.

Future production updates still require approval and a candidate-versus-running
system gate against unrelated service restarts/reloads. The consumer's generic
deploy app does not yet enforce the additional gate used for this release.
Preserve backup checks and disabled automatic rollback. The KVM module test
remains unverified because `/dev/kvm` is absent.

---
# Meet in the middle — Olimpo review, 2026-09-19

Consumer base: `75e231f03f9410612f41d4b0baeb4de5f6663d73`.
Refl review base: `19bb9b7d177c6c3b53a38d7314b8309189f9616e`.
Previous handoff preserved in `HANDOFF-2026-09-19-before-meet-review.md`.

## Findings

**High, open for production:** `deployXty` lacks a candidate/running-system
comparison that blocks unrelated restarts/reloads. Before approved production
activation, protect shared nginx, PostgreSQL, networking, docxty and other
projects. Preserve backup checks and disabled automatic rollback. Publication
to GitHub does not authorize production activation.

**Medium, fixed in refl:** two separate Bend computational paths with number
holes, plus a native rewrite alternative; reflexivity teaching in lesson 2;
stable lesson URLs and original numeric Tutorial bookmark compatibility;
existing-player prerequisite access without fabricated completion. Retained
the earlier same-task draft flush fix and clipboard improvements.

**Low, fixed:** stale publication/lesson guidance and incorrect Bend annotation
claims. `{proof : Type}` is checked; `(proof : Type)` is not equivalent.

**Unverified:** KVM module test; `/dev/kvm` is absent. Host browser/prover tests
do not establish VM boot, cgroup-exhaustion or OOM-recovery behavior.

## Verification and local review

Refl native suites passed 71 examples. Full flake checks passed; isolated host
verification passed 128 content checks, Chromium with Agda/Lean/Bend, retry and
HTTP/WebSocket security. Browser checks submit authored demonstrations and
reject incorrect numbers on either side while keeping partial proofs unsolved.
Full evidence: `~/src/refl/HANDOFF.md`.

Keep `refl.url = "github:hhefesto/refl"`. Update only that lock node after
publication; preserve all of the user's refreshed system pins and kernel.
`ns` is already defined in this repository's `configuration-workstation.nix`
as `nixos-rebuild switch --sudo --flake ~/src/enc`.
Existing shells may need `exec zsh`; do not edit generated `/etc/zshrc`.

The agent builds with `nixos-rebuild build --flake ~/src/enc`.
The user activates with `nixos-rebuild switch --sudo --flake
~/src/enc`, then assesses http://127.0.0.1:3007.
Approval of this new candidate is pending. No activation performed by the agent.
Exact published revision and build result follow below.

## Production and refl-only rollback

Production is unchanged by this work and requires explicit approval after local
assessment. Before deployment, record xty's actual system and refl ExecStart,
retain the old closure as a GC root, back up refl state, and compare candidate
activation effects. Block unrelated service restarts/reloads; monitor external
availability and protected service PIDs. Keep `autoRollback = false` and
`magicRollback = false` plus existing backup checks.

To roll back refl alone, repin only its previous input on the current consumer,
build, pass the same service-diff gate and activate that candidate. Never use
whole-system `--rollback` for a refl regression. Preserve player state unless
a demonstrated incompatible format change requires its backup.

## Verified candidate

Published refl HEAD: `9f84c926c3c5fd70d92ab9152fff07ae978a6923`.
Tested implementation: `11649932894938d432535e407f0c8bc2d92c5189`.
Only lock node `refl` differs from `/tmp/refl-meet-consumer-before.lock`;
all unrelated user-refreshed pins are preserved.

`nixos-rebuild build --flake ~/src/enc` succeeded:
`/nix/store/aqk38xfyhb7vici9jgpqk2a3cfsvhxh4-nixos-system-olimpo-26.11.20260919.20b1ddd`.
Log: `/tmp/refl-meet-olimpo-build.log`.
Candidate refl ExecStart:
`/nix/store/d68whka6mrplwjmhmqa4dhxrx1k5xjyc-refl-site/bin/refl-site`.

Compared against the currently running system:
`/nix/store/abcxpdmda31bp9xl0jbzcc0fvcjy79qf-nixos-system-olimpo-26.11.20260919.20b1ddd`.
Recursive systemd unit comparison differs only for `refl.service` and its
multi-user target link. Both systems use exactly the same kernel closure:
`/nix/store/qmdwpmr1s2wj89ibpa8j72wikxzjhldy-linux-6.18.52/bzImage`.
The candidate's generated zshrc contains the requested `ns` alias.

The new module is built but not activated. Live verification of this candidate
at http://127.0.0.1:3007 must follow the user's switch; the currently running
module is the previous revision. Production remains unchanged and unapproved.
Previous refl lock for refl-only rollback:
`19bb9b7d177c6c3b53a38d7314b8309189f9616e`.
