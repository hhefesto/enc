{ config, pkgs, inputs, ... }:
{
  imports = [ ./hardware-configuration-olimpo.nix inputs.refl.nixosModules.default ];

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

  # --- LAN binary-cache: olimpo <-> delfos over ssh-ng ---------------------

  # Pull from delfos's store.
  nix.settings.substituters = [
    "ssh-ng://nix-ssh@delfos-nix-cache"
  ];
  nix.settings.trusted-substituters = [
    "ssh-ng://nix-ssh@delfos-nix-cache"
  ];
  nix.settings.trusted-public-keys = [
    # Contents of /etc/nix/cache-pub-key.pem on delfos.
    "delfos:D3sIYhrkcJUb7O01+r94oD50NVYvOS02Hg2opXu7aGw="
  ];

  # Serve olimpo's store to delfos. Authorize delfos's root key.
  nix.sshServe = {
    enable   = true;
    protocol = "ssh-ng";
    keys = [
      # Contents of /root/.ssh/id_ed25519.pub on delfos.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPjABQfwQ+vpgGqO6zsWNsG40ZFc55Z3zZQPA+3F4V9 root@delfos"
    ];
  };

  # Sign every path olimpo serves so delfos accepts the signature.
  nix.settings.secret-key-files = [ "/etc/nix/cache-priv-key.pem" ];

  # nix.sshServe runs `nix-daemon --stdio` as the `nix-ssh` user.
  # allowed-users is restricted in configuration-core.nix, so re-grant
  # nix-ssh explicitly here (list-merges with the core values).
  nix.settings.allowed-users = [ "nix-ssh" ];
  nix.settings.trusted-users = [ "nix-ssh" ];

  # Pre-seed delfos's host key so root's ssh client doesn't prompt.
  programs.ssh.knownHosts."delfos-nix-cache" = {
    hostNames = [ "delfos-nix-cache" "192.168.3.6" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINM3/adCok24i8fl600FBto4A/thxXaKpDu5B3ec3QT";
  };

  programs.ssh.extraConfig = ''
    Host delfos-nix-cache
      HostName 192.168.3.6
      User nix-ssh
      IdentityFile /root/.ssh/id_ed25519
      IdentitiesOnly yes
      BatchMode yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ConnectTimeout 3
  '';

  # mugen itself comes with Claude Code, in configuration-workstation.nix.
  environment.systemPackages = [
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
  # https://mugen.hhefesto.dev through a reverse tunnel to xty. Set its
  # password with `mugen-web passwd`; `mugen-web link` prints a one-time
  # sign-in link.
  services.mugen-web.origin = {
    enable = true;
    user = "hhefesto";
    tailnet = true;
    tmux = config.programs.tmux.package;
    tunnel = {
      enable = true;
      host = "62.238.6.4";
      identityFile = "/home/hhefesto/.ssh/hetzner_ed25519";
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
}
