# Refl tutorial review and Olimpo module rollout — 2026-09-19

## Current follow-up: published GitHub input with refreshed system pins

The user regenerated `flake.lock` and switched Olimpo to
`/nix/store/n3k99kmnxmxlkvigqjw4gkkw75aykfjs-nixos-system-olimpo-26.11.20260919.20b1ddd`
(kernel 6.18.52). That removed the former local refl override and selected
GitHub `13f600c`, which explains why the tutorial had not changed.

The user explicitly requested GitHub publication. Refl HEAD
`19bb9b7d177c6c3b53a38d7314b8309189f9616e` is pushed to `origin/master`.
`flake.nix` retains `refl.url = "github:hhefesto/refl"`; `nix flake update refl`
now pins that HEAD. Comparison with the user's refreshed lock shows only node
`refl` changed. All of the user's new unrelated pins are preserved. The local
store override and old-kernel build described below are superseded.

The tested lesson implementation remains `476f27d` (newer refl commits change
only handoff documentation), so its native/content/browser/security evidence
below still applies. No additional application code was changed in this fix.

`ns` is defined in **this repository**, `configuration-workstation.nix:139`,
as `nixos-rebuild switch --sudo --flake ~/src/enc`.
NixOS generates `/etc/zshrc` from it; that generated file was never edited by
the agent. The current active configuration already contains the alias.
Existing zsh sessions, including reattached tmux panes, need `exec zsh`.

The refreshed consumer lock already contained user changes when this follow-up
started. Preserve them; they are not an agent-requested dependency downgrade.
Production activation still awaits explicit approval; publication is not a deploy.

Previous domain-move history: `HANDOFF-2026-09-19-domain-move.md`.
Earlier rollout/outage: `HANDOFF-2026-09-18-refl-rollout-and-earlier.md`.
Full teaching/review evidence: `~/src/refl/HANDOFF.md`.

## Review baseline and findings

Consumer `05765c2`, refl `13f600c`; both checkouts are on **master**, initially
clean. The old `refl-xty` branch/unmerged descriptions are historical.
Production uses https://refl.hhefesto.dev with nginx/ACME, not public :3007.

**High, open:** `deployXty` has backup/pure/live gates, but no candidate versus
running-system gate against unrelated restarts/reloads. Block production until
one establishes that shared nginx, PostgreSQL, networking, docxty and all other
projects remain untouched. Keep backup checks and disabled automatic rollback.

**Medium, fixed:** same-task input/navigation reproduced a lost edit from stale
reactive text. The departure flush now reads the live textarea; exact Unicode
and per-language drafts pass the new regression checks (details below).

**Low, addressed:** stale branch, publication, hint and deployment documentation.

**Unverified:** KVM NixOS module test; Olimpo has no `/dev/kvm`. Isolated prover
and local module acceptance do not substitute for VM resource-exhaustion tests.

## Local rollout and approval

Only the reviewed refl snapshot is pinned; unrelated dependencies are unchanged.
Added `ns = "nixos-rebuild switch --sudo --flake ~/src/enc"`
to workstation zsh aliases. Existing `sn` remains available. The user's final
path spelling had an extra slash; use the actual existing checkout above.

Built with `nixos-rebuild build --flake ~/src/enc`.
The user then runs `nixos-rebuild switch --sudo --flake
~/src/enc`; start a new zsh afterwards for `ns`.
After switch, verify http://127.0.0.1:3007 through the module and let the user
assess the lesson. Explicit production approval is still required.

Exact source, build and test results are recorded below.
No production switch, publication, remote push or local activation performed.

## Production and rollback

Historical production: xty generation 71 at the previous pinned refl revision;
not re-deployed by this review. Before approved deployment, record the actual
running system and previous refl ExecStart/input, retain the old closure with
a GC root and back up refl state. Compare candidate services/activation effects
with the running system; block unrelated restart/reload changes. Monitor public
site availability and protected service PIDs throughout activation.

For refl-only rollback, repin the previous refl input on the current consumer,
build and pass the same unrelated-service gate before activation. Never use a
whole-system `--rollback` for a refl regression. Keep player state unless a
specific incompatible format change requires restoring its backup.

## Verified candidate

Reviewed implementation: refl `476f27d3d9bb7ebbc3a1ba3a65a2083bfe9223e7`.
Immutable source `/nix/store/y3vyjacprm8dpkagr5fiy98b10anl36a-source`, NAR hash
`sha256-QzAOP7R3u1meVRKGOB2xToCq9TAcTW/jVDUI9qXvrv0=`. Retained by
`~/src/refl/result-reviewed-source`. The lock override is persistent: the normal
build/switch commands select it without flags. Exactly one lock node changed:
`refl`; all unrelated pins remain identical. Previous refl pin:
`f529203020105b3e995833798348307ab80868a4`. Nothing pushed.

Passed in refl: 67 native tests; manifest and website builds; 122 content checks
including host Lean; full `nix flake check` (106 in-sandbox content checks,
browser with explicit Lean session skip, smoke/security/Bend); `verify-local`
with 122 isolated checks, all-three-prover Chromium flows, failure/retry and
security. Browser checks both actual authored hint proofs against level
restrictions, rejects wrong proofs and leaves templates unfinished, checks hint
order/building blocks before completion, selectors and exact immediate drafts.

The immediate edit/navigation test reproduced a lost edit. Fixed by reading the
live textarea on departure rather than stale reactive text, and prioritizing the
flush over simultaneous debounce. Repeated Unicode navigation and all language
drafts now pass. Close/unmount delays remain; no claim of crash/tab-close or
arbitrary-network-stall durability. KVM module test still unverified.

The running module at http://127.0.0.1:3007 and public production health both
reported 61 variants before activation. These probes do not validate the new
candidate. After the user's switch, run the updated browser suite in existing
service mode against :3007 and verify its ExecStart references the new closure.
Olimpo lesson assessment and explicit xty approval are pending.

## Olimpo build result and pre-existing drift

Consumer configuration commit: `188cc609869d70a929c6c4bad882eb86f49a858d`;
later commits only finalize these records. The module build succeeded:
`/nix/store/yqsv22fni68nggn5q0iakm088d86yavd-nixos-system-olimpo-26.11.20260831.34ab990`.
Its `etc/zshrc` contains the exact `ns` alias. Refl service ExecStart is
`/nix/store/f8lx96yyy0hjswwgsk1h8v25447dw793-refl-site/bin/refl-site`.
Log: `/tmp/refl-olimpo-build.log`.

**Read before switching:** Olimpo currently runs
`/nix/store/5pghfdayjcpb2vvjbsbxhl5hmn7cb109-nixos-system-olimpo-26.11.20260916.b1b8759`.
This checkout has older pins; its full switch would change unrelated units
including local nginx, PostgreSQL and NetworkManager, and change the next-boot
kernel from 6.18.52 to 6.18.48. Only the refl lock entry was edited in this task;
the unrelated drift was already present. The user was informed before switch.
Unit comparison: `/tmp/refl-olimpo-unit-diff.txt`. No local switch was performed.

After the user switches, verify the actual service and run:

```sh
cd ~/src/refl
REFL_BROWSER_EXISTING_URL=http://127.0.0.1:3007 FONTCONFIG_FILE=/etc/fonts/fonts.conf \
  /nix/store/r5n6ysvs7iwdsvja01f875a40sf2d7qs-refl-backend-0.1.0.0/bin/refl-browser-test \
  result-browser-tools/bin/chromium unused games/refl
```

This uses a fresh browser identity and does not start/stop the module. Confirm
that refl's ExecStart matches the candidate above before accepting the result.

## GitHub follow-up build verified

`nixos-rebuild build --flake ~/src/enc` succeeded with
`/nix/store/abcxpdmda31bp9xl0jbzcc0fvcjy79qf-nixos-system-olimpo-26.11.20260919.20b1ddd`.
Log: `/tmp/refl-olimpo-github-build.log`. It retains the running kernel 6.18.52.
Only refl.service (and its wantedBy symlink) differs in the system unit tree
from the current running generation. The built zshrc contains `ns`; refl's
ExecStart references the reviewed `/nix/store/f8lx96yyy0hjswwgsk1h8v25447dw793-refl-site/bin/refl-site`.
Activation remains the user's step:
`nixos-rebuild switch --sudo --flake ~/src/enc`.
The running lesson will remain old until that switch; afterwards verify :3007
using the previously documented existing-service browser test.
