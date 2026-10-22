
{ pkgs, lib, config, xmonadLogWidth ? 60, ... }:
let
  # The terminal xmonad opens (M-S-<Return>, and the startupHook one).
  #
  # Reattach a session no client is on -- typically one whose terminal window
  # was closed -- otherwise start a fresh one. The session count therefore
  # settles at the number of terminals actually kept open, and nothing is lost
  # to an accidentally closed window.
  tmuxAttachOrNew = pkgs.writeShellScript "tmux-attach-or-new" ''
    tmux=${config.programs.tmux.package}/bin/tmux

    orphans=$("$tmux" list-sessions -f '#{==:#{session_attached},0}' \
                                    -F '#{session_name}' 2>/dev/null || true)
    orphan=''${orphans%%$'\n'*}

    if [ -n "$orphan" ]; then
      "$tmux" attach-session -t "$orphan" && exit 0
    else
      "$tmux" new-session && exit 0
    fi

    # gnome-terminal closes the window the moment its command exits, so a tmux
    # failure would otherwise be an invisible flash. Keep a usable shell.
    echo "myterm: tmux failed to start, falling back to a plain shell." >&2
    exec ${pkgs.zsh}/bin/zsh -l
  '';

  myterm = pkgs.writeShellScriptBin "myterm" ''
    exec ${pkgs.gnome-terminal}/bin/gnome-terminal -- ${tmuxAttachOrNew}
  '';
in
{
  networking.networkmanager.enable = true;

  environment.systemPackages = with pkgs; [
    myterm
    (import ./chatgpt-desktop.nix { inherit pkgs; })
    localsend
    insomnia
    brightnessctl
    alsa-utils
    # GCC 16 warns that x86 `regparm` is ignored on x86_64; kvmtool builds with -Werror.
    (kvmtool.overrideAttrs (old: {
      env = old.env // {
        NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " -Wno-error=attributes";
      };
    }))
    kdePackages.kdenlive
    brave
    virt-manager
    slack
    # nixpkgs' Python builder uses structured attributes, which hand each
    # makeWrapperArgs element to makeWrapper as one argument; pywal16 gives
    # `--prefix PATH : <imagemagick>` as a single string, so its build dies.
    (pywal.overridePythonAttrs {
      makeWrapperArgs = [ "--prefix" "PATH" ":" (lib.makeBinPath [ imagemagick ]) ];
    })
    sox
    zoom-us
    discord-ptb
    signal-desktop
    unetbootin
    scrot
    libnotify
    dunst
    xclip
    feh
    firefox
    dmenu
    tabbed
    st
    haskellPackages.xmobar
    obs-studio
    qbittorrent
    libreoffice
    vlc
    dropbox-cli
    nautilus
    gnome-terminal
    sshpass
    gimp
    gparted
    google-chrome
    ffmpeg
    vhs # terminal session GIFs from a tape script (the mugen and ana demos)
    xdotool
    xvkbd
    inkscape
  ];

  fonts.packages = with pkgs; [
    source-code-pro
    noto-fonts-cjk-sans
    ipafont
    kochi-substitute
    font-awesome
    hack-font
  ] ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);

  fonts.fontconfig.enable = true;
  fonts.enableDefaultPackages = true;

  i18n.supportedLocales = [
    "en_US.UTF-8/UTF-8"
    "ja_JP.UTF-8/UTF-8"
  ];

  xdg.mime.defaultApplications = {
    "text/html" = "brave-browser.desktop";
    "x-scheme-handler/http" = "brave-browser.desktop";
    "x-scheme-handler/https" = "brave-browser.desktop";
    "x-scheme-handler/about" = "brave-browser.desktop";
    "x-scheme-handler/unknown" = "brave-browser.desktop";
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };

  programs.dconf.enable = true;

  # Local X11 hosts: copy-mode yanks also land in the X CLIPBOARD selection,
  # the same route the xmonad OCR binding takes. (copy-mode, not
  # copy-mode-vi -- programs.tmux.keyMode is emacs.) Remote hosts are
  # covered by set-clipboard/OSC 52 in configuration-core.nix.
  programs.tmux.extraConfig = ''
    bind -T copy-mode M-w send -X copy-pipe-and-cancel "${pkgs.xclip}/bin/xclip -selection clipboard"
  '';

  hardware.bluetooth.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };
  services.blueman.enable = true;

  services.xserver.enable = true;
  services.xserver.xkb.layout = "us";
  services.xserver.xkb.options = "ctrl:nocaps";
  services.xserver.xkb.variant = "altgr-intl";
  services.xserver.windowManager.xmonad = {
    enable = true;
    enableConfiguredRecompile = false;
    config = builtins.replaceStrings [ "@xmonadLogWidth@" ] [ "${toString xmonadLogWidth}" ] (pkgs.lib.readFile ./xmonad.hs);
    enableContribAndExtras = true;
    extraPackages = haskellPackages: [
      haskellPackages.xmonad-contrib
      haskellPackages.xmonad-extras
      haskellPackages.xmonad
    ];
  };

  services.displayManager.defaultSession = "none+xmonad";
  services.displayManager.gdm.enable = true;
  services.xserver.displayManager.sessionCommands =
    let
      myCustomLayout = pkgs.writeText "xkb-layout" ''
        remove Lock = Caps_Lock
        remove Control = Control_R
        keysym Control_R = Caps_Lock
        keysym Caps_Lock = Control_R
        add Lock = Caps_Lock
        add Control = Control_R
      '';
    in ''
      ${pkgs.xmodmap}/bin/xmodmap ${myCustomLayout}
      ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd --all
      exec >>"$HOME/.xsession.log" 2>&1
      echo "[XSESSION] Started at $(date)"
    '';

  services.desktopManager.gnome.enable = true;

  location.provider = "manual";
  location.latitude = 20.59;
  location.longitude = -100.39;

  virtualisation.libvirtd.enable = true;

  # 587 submission, 5938 teamviewer, 53317 localsend.
  # Dev backends (3000/…) and postgres (5432) stay localhost-only.
  networking.firewall.allowedTCPPorts = [ 587 5938 53317 ];
  networking.firewall.allowedUDPPorts = [ 5938 53317 ];

  users.users.hhefesto.extraGroups = lib.mkAfter [ "video" "networkmanager" "libvirtd" "kvm" ];
}
