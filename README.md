# enc

NixOS flake for hhefesto's machines: `olimpo` + `delfos` (workstations) and `xty` (production server at 62.238.6.4 hosting docxty.net, cfo-vision.com, and xty-y-dan.net).

The name `enc` is an abbreviation of the repo's old name,
**e**tc-**n**ixos-**c**onfiguration (renamed on 2026-10-22). It is not
about encryption. The checkout lives in `~/src/enc` on every workstation:
`home.nix` links `~/.spacemacs` into it.

- Rebuild locally: `ns` (alias for `nixos-rebuild switch --sudo --flake ~/src/enc`; `sn` is the same with `-v`; `nb` builds without switching: `nixos-rebuild build --flake ~/src/enc`)
- Deploy production: `nix run .#deploy-xty`
- Details: `Claude.md`

## Tailscale: olimpo from the iPhone

`olimpo.nix` runs `tailscaled` (its UDP port 41641 open, for direct links
instead of DERP relays), makes `hhefesto` its operator, and opens mosh's
UDP ports (60000-61000) on `tailscale0` only. The tailnet is the personal
one, **daniel.herrera.rendon@gmail.com** (where the iPhone, `iphone183`,
already is), not rdataa.com.

Once, on olimpo:

1. If `tailscale` answers "Access denied: checkprefs access denied", make
   the operator by hand: `sudo tailscale set --operator=hhefesto`.
2. Log out of any other tailnet: `tailscale switch --list` shows the
   accounts; `tailscale logout` leaves the current one (rdataa.com).
3. `tailscale login`, open the URL it prints, and sign in with Google as
   daniel.herrera.rendon@gmail.com.
4. In the admin console (https://login.tailscale.com/admin/machines):
   approve olimpo if it asks, and, from olimpo's `…` menu, "Disable key
   expiry", so the login doesn't lapse in 180 days.
5. Check: `tailscale status` lists olimpo and iphone183; `tailscale ip -4`
   is olimpo's 100.x.y.z address; its MagicDNS name is `olimpo`.

On the iPhone: the Tailscale app, signed in with the same account and
connected. Then, in Blink, `mosh hhefesto@olimpo` (or `ssh`): the login
attaches to tmux's `main` session (`configuration-core.nix`), so mugen
running there is where you left it. Blink's public key must be in
`users.users.hhefesto.openssh.authorizedKeys.keys`
(`configuration-core.nix`), followed by a rebuild.

Every day: nothing. `tailscaled` starts at boot and keeps the login;
`tailscale down` / `tailscale up` take olimpo off the tailnet and back.
