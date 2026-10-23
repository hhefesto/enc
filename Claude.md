# CLAUDE.md — enc (short for etc-nixos-configuration)

## FP taste

Primary languages: **Nix, Haskell, Agda**. Strongly prefers functional, type-driven, declarative solutions. When explaining code, favour equational reasoning and type-driven thinking over imperative walkthroughs. Do not suggest Python/Bash alternatives without a clear reason (small Bash commands are OK) — reach for Nix derivations or Haskell programs first.

- Emacs (spacemacs) is the primary editor. Do not suggest switching editors or IDEs.
- Rebuild shorthand: `sn` → `sudo nixos-rebuild -v switch --flake ~/src/enc`.

---

## Repo layout

**Flat** — everything lives at the repo root; there are no `hosts/`, `modules/`, or `users/` subdirectories. Do not create subdirectory trees without explicit request.

| File | Purpose |
|---|---|
| `flake.nix` | Entry point. Uses `flake-parts`. `mkHost` helper. Builds `nixosConfigurations.{olimpo,delfos,xty}`, `deploy.nodes.xty`, pre-deploy checks, `apps.deploy-xty`. |
| `configuration-core.nix` | Every host: users (agenix-managed login hash in `secrets/user-password.age`, `linger = true` for tmux), ssh, nix settings, agenix module import, `programs.tmux` + the zsh SSH auto-attach. |
| `configuration-workstation.nix` | Workstations: dev tools, zsh (system-wide aliases; root shell is zsh), docker, claude-code overlay. |
| `configuration-gui.nix` | Workstations: X11/xmonad, desktop apps, fonts, pipewire, LAN firewall. |
| `configuration.nix` | 7-line stub = core + workstation (imported by olimpo/delfos only). |
| `home.nix` | home-manager for `hhefesto` (NixOS module, `useGlobalPkgs` + `useUserPackages`); seeds `~/.claude` hooks. |
| `llm-transcript.hs` / `llm-transcript.nix` | Session-transcript renderer (Haskell + its derivation). |
| `olimpo.nix` / `delfos.nix` / `xty.nix` + `hardware-configuration-*.nix` | Per-host. olimpo↔delfos share LAN ssh-ng binary caches; delfos has dynamic timezone; xty is the headless production server (62.238.6.4, fail2ban, keys-only SSH). |
| `secrets/` | agenix: `secrets.nix` recipients + `user-password.age` (rotate: `secrets/rotate-user-password.sh`). |
| `xmonad.hs`, `xmobarrc-olimpo`, `xmobarrc-delfos` | xmonad config; `@xmonadShortenLength@` substituted per host. `myTerminal = "myterm"` (tmux wrapper from `configuration-gui.nix`). |
| `spacemacs`, `spacemacs.rev` | `~/.spacemacs` (symlinked here, edited live from Emacs) and the recorded Spacemacs core commit. See "Spacemacs setup". |

**Navigation:** `flake.nix` → `mkHost` → per-host module lists (workstations: `configuration.nix` + gui + projects desktop-profile; xty: core + projects production-profile).

### Hosts & hosted projects

- **olimpo**, **delfos** — workstations; test the app stacks with desktop profiles.
- **xty** — production. Hosts (all sharing one postgres 16 on 5432):

| Input | App | Prod domain | Backend port | DB |
|---|---|---|---|---|
| `docxty` | expedientes (medical records) | docxty.net | 3000 | `expedientes` |
| `wedding-page` | wedding RSVP | xty-y-dan.net | 3001 | `wedding` |
| `directo` | store (refacciones, Querétaro) | directo.hhefesto.dev | 3002 | `directo` |
| `xpsoasis` | AAnalyzer (Servant + Reflex; production Yesod is reference-only in master) | xpsoasis.hhefesto.dev | 3003 | `aanalyzer_yesod` (user `analyzer`) |
| `refl` | The Refl Game (Agda/Lean/Bend proof game, no DB) | refl.hhefesto.dev | 3007 | none |

Workstation dev nginx ports: expedientes 80, wedding 8084, directo 8085, xpsoasis 8086; refl on olimpo is loopback 3007 (no nginx). xpsOasis has one Servant backend on 3003 for `/api`, `/b`, `/ws`, and the SPA.

Deploy: `nix run .#deploy-xty` (docxty backup health check → pure checks → live SSH checks → build → deploy-rs). Backup health check standalone: `nix run .#check-docxty-backups` (`DOCXTY_BACKUP_CHECK_FAST=1` skips the restic integrity pass). **Update policy: manual only** — no `system.autoUpgrade`; every prod update goes through the check pipeline.

### Key flake inputs

`nixpkgs` (nixos-unstable), `flake-parts`, `deploy-rs`, `home-manager` (release-25.11), `agenix`, `docxty`/`wedding-page`/`directo`/`refl` (project repos; `refl` keeps its own nixpkgs pins for the provers, no `follows`), and an Olimpo-local `path:/home/hhefesto/src/xpsoasis` input. Restore xpsOasis to its Git branch after the single-backend changes are committed; never deploy xty while path-pinned. Other inputs: `claude-code-nix`, `telomare`.

Binary caches: `hercules-ci.cachix.org`, `telomare.cachix.org`, `nixcache.reflex-frp.org`, `claude-code.cachix.org`.

`nixpkgs.config.allowUnfree = true`.

### Conventions

- **Per-host parametrisation** via `extraSpecialArgs` (e.g., `xmonadShortenLength`, `tmuxAccent`), not conditionals inside shared files.
- **Project modules own project code**; this repo only sets collide-able facts (ports, db names, serverName, profile) and host concerns.
- **Secrets**: agenix only. App secrets live in each project repo (`${input}/secrets/*.age`); this repo's `secrets/` has the login hash. Never commit plaintext credentials or password hashes.
- **Test project changes without pushing**: `nix build .#nixosConfigurations.olimpo.config.system.build.toplevel --override-input docxty path:$HOME/src/expedientes -L` (new files in the project must be `git add`ed — flake purity).
- **Build after changes**: `nix build .#nixosConfigurations.olimpo.config.system.build.toplevel -L`.

---

## LLM transcripts

Every Claude Code session is rendered to `~/src/llm-transcript/` (flat, one
Markdown file per session, mode 0700) by `llm-transcript`, a Haskell program
built from `llm-transcript.hs` at the repo root via
`pkgs.writers.writeHaskellBin` (see `llm-transcript.nix`, imported by both
`configuration-workstation.nix` and `flake.nix`'s `packages.llm-transcript`).

- **`claude` is wrapped** (`configuration-workstation.nix`): the wrapper pins a
  session UUID and passes `--debug-file`, so each launch also drops a debug log
  beside the transcripts. `pkgs.claude-code` is **not** in `systemPackages` —
  two packages shipping `bin/claude` would collide; the wrapper `exec`s the
  store path directly. `--session-id` is skipped for `-c/-r/--fork-session/
  --from-pr/--teleport`, which are mutually exclusive with it.
- **Hooks** `Stop` and `SessionEnd` re-render the transcript, merged into the
  mutable `~/.claude/settings.json` by `home.activation.claudeTranscriptHooks`
  (jq, idempotent, preserves other keys). They invoke `llm-transcript` **by
  name**, not by store path — `~/.claude` is not a GC root.
- **Labels**: `👤 User` (typed, queued, and accepted-suggestion prompts) /
  `⚙️ System` (harness-injected turns: task notifications, reminders) /
  `⌨️ Command` (slash-command records) / `⚙️ Interrupt` / `🤖 Claude` /
  `🔧 <Tool>`, and for Bash a `#### Ran · compile|runtime|shell` line with
  **stdout** and **stderr** fenced separately (capped at 100 lines, middle
  elided). Claude Code records no exit code, but when it records a
  `returnCodeInterpretation` ("No matches found", "Files differ") the
  transcript shows it. Edits render as diffs from `structuredPatch`, falling
  back to an old/new diff from the tool input; Reads include a 30-line
  excerpt; Agent calls show the subagent's answer, not just the prompt. The
  session header lists model(s) and git branch(es).
- **Reasoning text is not recoverable.** Verified four ways: all 7,470
  `thinking` blocks on disk are empty; no hook event carries reasoning;
  `--debug-file` under every filter (`api`, `*`, none) yields none; and
  `--output-format stream-json --include-partial-messages` emits
  `thinking_delta` events (790 thinking tokens in a probe) whose text is
  **empty**. Only the opaque `signature` survives. Transcripts therefore record
  reasoning *metadata* — token count and effort — never prose.
- The renderer treats a session as a **DAG**, walking `parentUuid` back from
  `last-prompt.leafUuid`; superseded turns land under "Abandoned branches".
  Subagent files (`<session>/subagents/agent-*.jsonl`) fold into their parent
  `Agent` call via `meta.json`'s `toolUseId`.
- **`llm-transcript corpus [projectsDir] [out.jsonl] [--segment-bytes=N]`**
  emits a training corpus as JSONL `{id, text}` (ids `<session8>-<NNNN>`,
  documents cut at turn boundaries, ~4 KB default) straight from the raw
  session files — NOT from the rendered Markdown. It deliberately does not
  walk the DAG: compaction restarts the `parentUuid` chain, so the surviving
  branch of a long session holds a few percent of the conversation; corpus
  mode takes the conversation lines in append order instead. Includes
  prompts, prose, commands with capped output, edit diffs, and subagent
  answers; excludes `Read` file bodies (the worst secret vector), system
  turns, command records, compaction summaries, and per-turn metadata.
  Output is sanitized (ANSI escapes, `\r`, control bytes) and **scrubbed with
  a printed per-class report** (`<out>.scrub-report.txt`): crypt hashes, API
  keys/tokens, PEM blocks, `root@<ip>` box addresses **and bare occurrences
  of any IP ever seen after `root@`**, and all emails except the owner's. A
  scrubber that reports nothing is more likely broken than lucky: after any
  change, re-scan the emitted JSONL with the same patterns and expect zero.
  Exact-duplicate documents are dropped, and four whole sessions go to
  `<out>.holdout.jsonl` so a later split cannot put neighbouring segments of
  one session on both sides.

**These transcripts are secret-bearing** (a `Read` of `configuration-core.nix`
inlines the `$6$…` crypt hash). `~/src` is not a git repo, so nothing
auto-commits, but treat the directory accordingly. The corpus files are
scrubbed, but the `.md` renderings are **not** — only the corpus is safe to
move off this machine.

## Spacemacs setup

Spacemacs is not Nix-managed beyond the bare `emacs` binary (`programs.emacs`, no `extraPackages`). It behaves as on any distro:

- `~/.emacs.d` is a git checkout of Spacemacs `develop`. Update it with `git pull` there; ELPA packages are installed and updated by Spacemacs.
- `~/.spacemacs` is an out-of-store symlink to `./spacemacs`, so edits from Emacs (SPC f e d, customize) land in this working tree.
- The `spacemacs` activation entry in `home.nix` runs on every switch:
  - It clones `~/.emacs.d` at `spacemacs.rev` only when it is missing (a new machine).
  - It records the live `~/.emacs.d` HEAD in `spacemacs.rev` when that HEAD is ahead of the recorded one. A host that is behind leaves the record alone.
  - It auto-commits `spacemacs` and `spacemacs.rev` with a message like `spacemacs: dotfile, core abc1234..def5678 (olimpo)`.
- xty has no home-manager and no `~/src`: `xty.nix` links its `~/.spacemacs` (tmpfiles `L+`) to the store copy of `./spacemacs`, so a deploy carries the dotfile there. xty has no `~/.emacs.d`.
- telomare-mode is loaded from `~/.local/share/telomare` (a symlink to the `telomare` input).

## tmux setup

`programs.tmux` lives in `configuration-core.nix`, so **all three hosts** get it
(xty has no home-manager and never imports `configuration-workstation.nix`;
core is the only shared module, and it already owns `programs.zsh`).

- **Prefix `C-o`** (`shortcut = "o"`), not `C-b` — `C-b` is `backward-char` in
  both terminal Emacs and zsh, and this setup is emacs-keys throughout
  (`spacemacs:135` `dotspacemacs-editing-style 'emacs`, no `bindkey -v`, Caps
  is Control). `C-o C-o` = last-window, `C-o o` = send-prefix (needed for
  tmux-inside-tmux when SSHing olimpo → xty).
- `keyMode = "emacs"`, `baseIndex = 1`, `escapeTime = 10` (the 500 ms default
  breaks `M-<key>` in Emacs), `historyLimit = 50000`, `terminal = "tmux-256color"`.
- **`users.users.hhefesto.linger = true`** is load-bearing: `secureSocket`
  (default `true`) puts the socket in `$XDG_RUNTIME_DIR`, which systemd deletes
  on last logout — without lingering, detached sessions die.
- **Auto-attach**: `programs.zsh.interactiveShellInit` runs
  `tmux new-session -A -s main` when `$SSH_CONNECTION` is set, `$TMUX` is not,
  and `$NO_AUTO_TMUX` is unset. Non-interactive SSH (deploy-rs, the pre-deploy
  health checks) never reaches it. Escape hatch: `ssh -t <host> zsh -f`.
  Alias `t` does the same thing locally.
- **Status line** mirrors `xmobarrc-*`: black bg, `#646464` inactive,
  `#ababab` clock, accent from the per-host `tmuxAccent` `extraSpecialArgs` —
  `#7fff00` on olimpo/delfos, **`#ff5f5f` on xty so production is unmistakable**.
- `configuration-gui.nix` adds the one X11-only line (`M-w` → `xclip
  -selection clipboard`); remote hosts rely on `set-clipboard on` (OSC 52).

**Local terminals are tmux too.** `configuration-gui.nix` defines a `myterm`
wrapper (`writeShellScriptBin`) = `gnome-terminal -- tmux-attach-or-new`, and
`xmonad.hs` uses it for both `myTerminal` (so `M-S-<Return>`) and the
`startupHook`. `tmux-attach-or-new` reattaches a session no client is on —
typically one whose window you closed — and otherwise starts a fresh one, so
sessions settle at the number of terminals actually kept open and a closed
window loses nothing. It falls back to a plain login zsh if tmux fails, because
gnome-terminal closes the window as soon as its command exits.

This deliberately lives in the terminal, **not** in zsh: an unguarded zsh
auto-start would also fire in Emacs shell buffers, `nd`
(`nix -Lv develop -c zsh`) and `sudo -i`. The zsh snippet in
`configuration-core.nix` stays scoped to `$SSH_CONNECTION`.

## xmonad setup

xmonad is configured as a **NixOS module** (`configuration-gui.nix:98-108`), not via home-manager. Maybe we should change to home-manager for a better xmonad experience (reload of xmonad still needs logout from the xsession when it should only need `M-q`)

```
services.xserver.windowManager.xmonad = {
  enable = true;
  enableConfiguredRecompile = true;
  config = builtins.replaceStrings ["@xmonadShortenLength@"] ["${toString xmonadShortenLength}"] (pkgs.lib.readFile ./xmonad.hs);
  enableContribAndExtras = true;
  extraPackages = haskellPackages: [ ... ];
};
```

Launched via **GDM** (`services.displayManager.gdm.enable = true`, `defaultSession = "none+xmonad"` at `configuration-gui.nix:110-111`).

`sessionCommands` (`configuration-gui.nix:112-127`) swaps Caps_Lock ↔ Control_R (via xmodmap), runs `dbus-update-activation-environment --systemd --all`, and tees xsession output to `~/.xsession.log`.

**Startup hook** (`xmonad.hs:15-23`): nautilus, brave, feh wallpaper, `myterm` (tmux terminal, see above), emacs, signal-desktop, gnome-control-center. No `spawnOnce "dunst"` — dunst is a systemd user unit.

**Notification daemon:** `dunst` + `libnotify` installed as system packages (`configuration-gui.nix:22-23`). `home.nix:100` has `services.dunst.enable = true` so dunst runs as a proper systemd user service with correct dbus activation.

### The `<Print>` key / screenshot notification problem

**Status:** open as of 2026-04-20. Prior dbus/dunst hypothesis resolved — both fixes are already applied (`services.dunst.enable = true` in `home.nix:100`; `dbus-update-activation-environment` in `configuration-gui.nix:124`; dunst verified `active (running)`). `notify-send test` from a terminal works.

**Notification daemon:** dunst is running (verified Apr 20 2026). `notify-send test` from a terminal works.

**Current status (Apr 20 2026):** `sn` was run, xmonad binary rebuilt at 12:15, xsession started at 12:21 (new binary active). After pressing `<Print>`, `/tmp/xmonad-print.log` still does not exist. The diagnostic binding at `xmonad.hs:60` writes the log *before* notify-send — so the spawn itself is never running. This is a **keybinding-not-firing** problem, not a notify-send problem.

**Next debug steps (run in xmonad session, in order):**

1. Check what keysym `<Print>` actually produces — it may be `XF86Print`, `Sys_Req`, or nothing:
   ```sh
   xev -event keyboard   # press Print; look for keysym line
   ```
   If not `keysym 0xff61, Print` → fix the binding in `xmonad.hs:60-61` to match actual keysym.

2. Confirm `additionalKeysP` list is live by testing another binding:
   ```sh
   # Press M-j (xmonad.hs:66) — should trigger amixer + notify-send Volume
   ```

3. Simulate Print programmatically to rule out physical-key grab:
   ```sh
   xdotool key --clearmodifiers Print
   ls /tmp/xmonad-print.log
   ```

4. Check xmonad stderr for parse errors:
   ```sh
   grep -iE "error|warn" ~/.xsession-errors | tail -40
   ```

**Branch A — wrong keysym from xev:** Update `xmonad.hs:60-61` from `<Print>` to the real keysym (e.g., `<XF86Print>`), then `sn` + `M-q`.

**Branch B — `M-j` also broken:** `additionalKeysP` is broken. Check GHC recompile log in `~/.cache/xmonad/build-x86_64-linux/`.

**Branch C — `xdotool key Print` creates the log but physical Press does not:** a hardware/xkb remapping issue; add explicit xmodmap in `configuration-gui.nix:112` sessionCommands.

**If spawn fires but notify-send fails (log exists, notify≠0):** check DBUS_SESSION_BUS_ADDRESS in the log. If missing → `dbus-update-activation-environment` doesn't propagate to xmonad `spawn` children; fix with `systemd-run --user --scope notify-send …` in the binding.
