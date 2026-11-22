{ pkgs, lib, config, inputs, tmuxAccent ? "#7fff00", ... }:
let
  passwordRotated = builtins.pathExists ./secrets/user-password.age;
  burnedHash = "$6$/RvS0Se.iCx$A0eA/8PzgMj.Ms9ohNamfu53c9S.zdG30hEmUHLjmWP0CaXTPVA6QxGIZ6fy.abkjSOTJMAq7fFL6LUBGs4BU0";
in
{
  imports = [ inputs.agenix.nixosModules.default ];

  environment.systemPackages = [ pkgs.emacs ];
  environment.variables.EDITOR = "emacs";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  networking.enableIPv6 = false;
  time.timeZone = lib.mkDefault "America/Mexico_City";

  nixpkgs.config.allowUnfree = true;

  services.openssh.enable = true;
  services.sshd.enable = true;

  programs.zsh = {
    enable = true;

    shellAliases.t = "tmux new-session -A -s main";

    # An interactive SSH login lands in one persistent session, so a dropped
    # link costs nothing. Non-interactive SSH (deploy-rs, the pre-deploy
    # health checks) never reaches this. `tmux ...; then exit` rather than
    # `exec tmux`: if tmux ever fails to start you keep a usable shell.
    interactiveShellInit = ''
      if [[ -n $SSH_CONNECTION && -z $TMUX && -z $NO_AUTO_TMUX ]]; then
        if tmux new-session -A -s main; then exit; fi
      fi
    '';
  };

  # Prefix is C-o, not the C-b default: C-b is backward-char in both terminal
  # Emacs and zsh, and both are driven with emacs keys here (spacemacs
  # dotspacemacs-editing-style 'emacs, no bindkey -v anywhere). C-o is
  # open-line / accept-line-and-down-history -- neither is in daily use.
  programs.tmux = {
    enable = true;
    shortcut = "o";            # prefix C-o; C-o C-o = last-window, C-o o = send-prefix
    keyMode = "emacs";         # module default; stated because it is the point
    baseIndex = 1;             # windows/panes start at 1, matching the number row
    escapeTime = 10;           # the 500ms default makes M-<key> unusable in Emacs
    historyLimit = 50000;      # `nix build -L` output
    aggressiveResize = true;
    clock24 = true;
    terminal = "tmux-256color";

    extraConfig = ''
      set  -g  renumber-windows on
      set  -g  focus-events on
      set  -g  set-clipboard on              # OSC 52: a yank on xty reaches the local clipboard
      set  -as terminal-features ",*256color*:RGB"
      set  -g  display-time 2000
      set  -g  status-interval 1

      # splits that look like what they do, inheriting the pane's cwd
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"
      bind c new-window     -c "#{pane_current_path}"

      # Emacs-style copy (keyMode emacs): C-o C-SPC enters copy-mode (Ctrl
      # held from the prefix), then C-SPC sets the mark, the Emacs motions
      # move (C-f/b/n/p, M-f/b, C-a/e, C-v/M-v, M-</M->, C-s/C-r), M-w copies
      # and leaves (to tmux's buffer, OSC 52 and, on X hosts, the clipboard),
      # C-g drops the mark, q leaves. C-o C-y pastes tmux's last copy.
      # C-o [ and C-o ] still do the same.
      bind C-Space copy-mode
      bind C-y     paste-buffer -p

      bind R source-file /etc/tmux.conf \; display-message "tmux.conf reloaded"

      # palette lifted from xmobarrc-* and xmonad.hs: black bg, #646464
      # inactive, per-host accent (green on the workstations, red on xty)
      set -g status-style                "bg=black,fg=#646464"
      set -g window-status-style         "fg=#646464"
      set -g window-status-current-style "fg=${tmuxAccent},bold"
      set -g pane-border-style           "fg=#4a4a4a"
      set -g pane-active-border-style    "fg=${tmuxAccent}"
      set -g message-style               "bg=black,fg=${tmuxAccent}"

      set -g status-left        "#[fg=${tmuxAccent},bold][#S] "
      set -g status-left-length 20
      set -g status-right       "#[fg=${tmuxAccent}]#H  #[fg=#ababab][%H:%M:%S]"
    '';
  };

  # Login password hash lives agenix-encrypted in ./secrets (shared by
  # root + hhefesto on every host). Rotate with secrets/rotate-user-password.sh
  #
  # TODO(H1): the fallback branch below dies once secrets/user-password.age
  # exists (run secrets/rotate-user-password.sh, then `git add` the file).
  # The fallback hash is already burned — it lives in git history — so it
  # only preserves bootstrap-ability until the rotation happens.
  age.secrets = lib.mkIf passwordRotated {
    user-password = {
      file = ./secrets/user-password.age;
      mode = "0400";
    };
  };

  users.mutableUsers = false;
  users.users.root =
    if passwordRotated
    then { hashedPasswordFile = config.age.secrets.user-password.path; }
    else { initialHashedPassword = burnedHash; };

  users.extraUsers.hhefesto = {
    createHome = true;
    isNormalUser = true;
    home = "/home/hhefesto";
    description = "Daniel Herrera";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcDIsto/6GS7XwTl+uVo4ABeRlRjDwAU0HHy8irqLaB hhefesto@olimpo"
                                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2Ttj29zyClCr8pSobzAIJVcsEuL4GsPY7+aiK5eaA1"
                                  ];
    shell = pkgs.zsh;
    # tmux's socket lives in $XDG_RUNTIME_DIR (programs.tmux.secureSocket);
    # without lingering systemd removes it on last logout and detached
    # sessions die with it.
    linger = true;
  } // (if passwordRotated
        then { hashedPasswordFile = config.age.secrets.user-password.path; }
        else { initialHashedPassword = burnedHash; });

  nix.settings.auto-optimise-store = true;
  nix.settings.allow-import-from-derivation = true;
  nix.settings.fallback = true;
  nix.settings.connect-timeout = 3;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.extraOptions = ''
    keep-outputs = true
    keep-derivations = true
    accept-flake-config = true
    allow-import-from-derivation = true
  '';

  nix.settings.trusted-public-keys = [
    "telomare.cachix.org-1:H0qRjVstxtb9oyEPvDDpmPSLyJ9oViAsTgwR02ra6Dk="
    "claude-code.cachix.org-1:Yexf2anu7utx8vwrze0za1weds+4dui2kvewee4fsrk="
    "codex-cli.cachix.org-1:1Br3H1hHoRYG22n//cGKJOk3cQXgYobUel6O8DgSing="
  ];

  nix.settings.trusted-substituters = [
    "https://hercules-ci.cachix.org"
    "https://cache.nixos.org"
    "https://telomare.cachix.org"
    "https://claude-code.cachix.org"
    "https://codex-cli.cachix.org"
  ];

  nix.settings.substituters = [
    "https://hercules-ci.cachix.org"
    "https://telomare.cachix.org"
    "https://claude-code.cachix.org"
    "https://codex-cli.cachix.org"
  ];

  nix.settings.allowed-users = [ "@wheel" "hhefesto" ];
  nix.settings.trusted-users = [ "hhefesto" ];

  system.stateVersion = "25.11";
}
