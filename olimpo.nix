{ config, pkgs, inputs, ... }:
{
  imports = [ ./hardware-configuration-olimpo.nix ./lan-cache.nix inputs.refl.nixosModules.default ];

  networking.hostName = "olimpo";

  # Refl's own agenix secret, as with the other project inputs: the
  # password never enters the store or the unit's ExecStart, systemd
  # LoadCredential hands it to the process.
  age.secrets.refl-dashboard-password = {
    file = "${inputs.refl}/secrets/refl-dashboard-password.age";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.refl.profile = {
    enable = true;
    backend = { address = "127.0.0.1"; port = 3007; };
    ingress.enable = false;
    # http://127.0.0.1:3007/dashboard/ — user "refl"
    dashboard.passwordFile = config.age.secrets.refl-dashboard-password.path;
  };

  # OpenCL for the RX 580 (Polaris/gfx803). ROCm dropped this GPU, so the
  # compute path is Mesa's rusticl; RUSTICL_ENABLE exposes the radeonsi
  # driver as an OpenCL device. Consumed by the Futhark GPU training
  # backend in ~/src/modArTransformer (see ELLIOTT-LLM.md there).
  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.mesa.opencl ];
  };
  environment.variables.RUSTICL_ENABLE = "radeonsi";

  # Relax amdgpu's job watchdog from ~10 s to 60 s so training kernels can
  # run in larger launches (see TRAINING-GUIDE.md Lesson 10).
  # Tradeoff: a genuinely hung GPU job stalls the desktop up to 60 s
  # before soft recovery instead of 10 s.
  # NOTE (2026-07-10): a single value sets only the NON-COMPUTE rings
  # (GFX, SDMA, Video); rusticl submits OpenCL work to the COMPUTE ring,
  # which kept its default and soft-reset ana's (then formalTransformer's)
  # small-preset gradient kernel after ~11 s.  The four-value form
  # [GFX,Compute,SDMA,Video] covers the compute ring explicitly.  Takes
  # effect on reboot.
  boot.kernelParams = [ "amdgpu.lockup_timeout=60000,60000,60000,60000" ];

  # mugen itself comes with Claude Code, in configuration-workstation.nix.
  environment.systemPackages = [
    # wa-send: a WhatsApp message through this screen's Brave (wa-send.bend)
    (import ./wa-send.nix {
      inherit pkgs;
      bend = inputs.bend2.packages.${pkgs.stdenv.hostPlatform.system}.default;
    })
    # `mu`: go to the tmux session where mugen runs. From the phone, an ssh
    # login lands in tmux "main" (configuration-core.nix); `mu` switches
    # that client to mugen's session (attaches, outside tmux).
    (pkgs.writeShellScriptBin "mu" ''
      tmux=${config.programs.tmux.package}/bin/tmux
      s=$("$tmux" list-panes -a -F '#{session_name} #{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '$3 == "mugen" { print $1 ":" $2; exit }')
      if [ -z "$s" ]; then
        echo "mu: no mugen running in tmux; start one with: mugen" >&2
        exit 1
      fi
      if [ -n "$TMUX" ]; then
        exec "$tmux" switch-client -t "$s"
      else
        exec "$tmux" attach-session -t "$s"
      fi
    '')
  ];

  # --- mugen's chat in a browser ------------------------------------------

  # mugen-web reads ~/.mugen and types into mugen's tmux pane, so it runs
  # here, as hhefesto: on the tailnet at http://olimpo:3008/chat/, and at
  # https://mugen.hhefesto.dev through a reverse tunnel to xty. Its
  # password's bcrypt hash is an agenix secret (rotate with
  # secrets/rotate-mugen-web-password.sh); `mugen-web link` prints a
  # one-time sign-in link.
  age.secrets.mugen-web-password = {
    file = ./secrets/mugen-web-password.age;
    owner = "hhefesto";
    mode = "0400";
  };
  services.mugen-web.origin = {
    enable = true;
    user = "hhefesto";
    tailnet = true;
    tmux = config.programs.tmux.package;
    passwordFile = config.age.secrets.mugen-web-password.path;
    tunnel = {
      enable = true;
      host = "62.238.6.4";
      identityFile = "/home/hhefesto/.ssh/hetzner_ed25519";
    };
  };

  # --- The sound stays on the BenQ through the screensaver -----------------

  # When DPMS powers the BenQ off with the screensaver, its HDMI sink goes
  # away and the default falls back to S/PDIF or the dock; an open Sound
  # panel then keeps it there. audio-keep remembers the sink in use and puts
  # it back when it returns (audio-keep.hs). Logs: journalctl --user -u audio-keep
  systemd.user.services.audio-keep = {
    description = "Put the sound back on the output it had before the screen blanked";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "pipewire.service" "wireplumber.service" ];
    serviceConfig = {
      ExecStart = "${import ./audio-keep.nix { inherit pkgs; }}/bin/audio-keep ${pkgs.pipewire}/bin/pw-metadata ${pkgs.pipewire}/bin/pw-cli";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # --- The iPhone, over Tailscale -------------------------------------------

  # The phone reaches olimpo through the tailnet only; nothing new opens to
  # the LAN or the internet. Log in once with `tailscale up`.
  # openFirewall is tailscaled's own UDP port (41641), for direct links
  # instead of DERP relays. The operator runs tailscale's commands (up, down,
  # set) without sudo.
  services.tailscale = {
    enable = true;
    openFirewall = true;
    extraSetFlags = [ "--operator=hhefesto" ];
  };

  # mosh (Blink on iOS) keeps the session through sleep and network changes;
  # its ssh login attaches to tmux "main" (configuration-core.nix). Its UDP
  # ports open on the tailnet interface only.
  programs.mosh = {
    enable = true;
    openFirewall = false;
  };
  networking.firewall.interfaces.tailscale0.allowedUDPPortRanges = [
    { from = 60000; to = 61000; }
  ];

  # enc-update (enc-update.nix, enc-update.bend): olimpo is the builder. It
  # updates the system inputs only (nixpkgs and the like; the project inputs
  # stay where you pinned them), refuses an update that would build GHC, a
  # kernel or a browser, and switches olimpo, then xty (delfos, below, once
  # it takes the key), each only while idle, checking each and switching it
  # back if it broke.
  services.enc-update = {
    enable = true;
    builder = true;
    loadMax = "4";
    idleMinutes = 30;
    # delfos joins once root there takes olimpo's key (delfos.nix sets it;
    # it needs one switch on delfos itself, `ns` there): till then a cycle
    # that can't reach it would never finish, so it isn't a target yet
    targets = [ "olimpo local" "xty root@62.238.6.4" ];
    inputs = [ "nixpkgs" "home-manager" "agenix" "determinate" "deploy-rs" "flake-parts" "claude-code-nix" "codex-cli-nix" ];
    forbid = [ "ghc" "rustc" "linux" "gcc" "glibc" "llvm" "firefox-unwrapped" "chromium-unwrapped" "libreoffice" "qtwebengine" "electron" ];
    gates.xty = [ "pre-deploy-xty-live" ];
    # every machine updated and well: the lock fast-forwards GitHub's master
    # (a master that moved meanwhile refuses it; the next cycle starts from
    # it), so a `ns` from ~/src/enc after a `git pull` keeps the update
    push = "master";
    health = [ "unit sshd" "unit nix-daemon" "unit display-manager" "unit tailscaled" ];
  };
}
