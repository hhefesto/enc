{ pkgs, lib, inputs, ... }:
let
  llm-transcript = import ./llm-transcript.nix { inherit pkgs; };

  # Every `claude` launch also opens a debug log beside the transcripts, so
  # whatever claude-code is willing to emit lands in a file. `pkgs.claude-code`
  # is deliberately NOT in systemPackages: two packages shipping `bin/claude`
  # collide in the profile, and going through this wrapper is the point.
  # Nothing failure-prone runs before the exec, so a bug here cannot make
  # claude unlaunchable.
  claude-wrapped = pkgs.writeShellScriptBin "claude" ''
    out="$HOME/src/llm-transcript"
    mkdir -p "$out" 2>/dev/null || true
    chmod 700 "$out" 2>/dev/null || true
    stamp=$(${pkgs.coreutils}/bin/date +%Y-%m-%d_%H%M)
    proj=$(${pkgs.coreutils}/bin/basename "$PWD")

    # Fixing the session id up front lets the debug log sit beside the
    # transcript this session will produce. Skipped when resuming, because
    # --session-id is mutually exclusive with those flags.
    resuming=
    for a in "$@"; do
      case "$a" in
        -c|--continue|-r|--resume|--fork-session|--from-pr|--teleport) resuming=1 ;;
      esac
    done

    if [ -z "$resuming" ]; then
      sid=$(${pkgs.util-linux}/bin/uuidgen)
      exec ${pkgs.claude-code}/bin/claude \
        --session-id "$sid" \
        --debug-file "$out/$stamp-$proj-''${sid%%-*}.debug.log" "$@"
    fi
    exec ${pkgs.claude-code}/bin/claude \
      --debug-file "$out/$stamp-$proj.debug.log" "$@"
  '';
in
{
  nixpkgs.overlays = [
    inputs.claude-code-nix.overlays.default
  ];

  # mugen (~/src/mugen) runs `claude -p` itself, on this claude-code rather
  # than the wrapper above, which would open a debug log for every summary
  # it asks for. It does the wrapper's part for its chat calls: a session id,
  # and a debug log in this dir beside the transcript, named as the wrapper
  # names them.
  environment.sessionVariables = {
    MUGEN_CLAUDE = "${pkgs.claude-code}/bin/claude";
    MUGEN_DEBUG_DIR = "$HOME/src/llm-transcript";
  };

  # mugen's spellcheck underlines with SGR 4:3 (curly) in red (SGR 58).
  # tmux passes styled and colored underlines through only to a terminal
  # it knows has them: gnome-terminal (VTE) does, and says xterm-256color.
  programs.tmux.extraConfig = ''
    set -as terminal-features ",xterm*:usstyle"
  '';

  environment.systemPackages = with pkgs; [
    python3
    openssl
    bind
    inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    claude-wrapped
    # mugen (無限): one chat that never ends, in the terminal, on Claude Code
    # (`mugen login` once) or the API (`mugen --api`); wherever Claude Code is.
    inputs.mugen.packages.${pkgs.stdenv.hostPlatform.system}.default
    llm-transcript
    tesseract
    poppler-utils
    sd
    fd
    cmatrix
    bat
    jq
    zip
    rename
    parallel
    direnv
    nix-direnv
    ripgrep
    any-nix-shell
    wget
    vim
    curl
    gh
    gist
    git
    lambda-mod-zsh-theme
    oh-my-zsh
    zsh
    ranger
    htop
    nix-prefetch-git
    nixd
    hunspell
    hunspellDicts.es-any
    hunspellDicts.es-mx
    hunspellDicts.en-us
    (aspellWithDicts (dicts: with dicts; [ es en ]))
    unrar
    unzip
    hack-font
    cachix
    tree
    gnumake
    zlib
    msmtp
    gmp
  ];

  environment.pathsToLink = [
    "/share/nix-direnv"
    "/share/zsh"
  ];

  systemd.user.services.home-manager-hhefesto.serviceConfig = {
    TimeoutStartSec = "20m";
    TimeoutStopSec = "20m";
    Nice = 19;
    IOSchedulingClass = "idle";
    IOSchedulingPriority = 7;
  };

  programs.nix-index.enableZshIntegration = true;

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    ohMyZsh.enable = true;
    ohMyZsh.plugins = [ "git" "sudo" "colorize" "extract" "history" "postgres" ];
    ohMyZsh.theme = "intheloop";

    shellAliases = {
      cat = "bat";
      _cat = "cat";
      gs = "git status";
      ga = "git add -A";
      gd = "git diff";
      gc = "git commit -am";
      gcs = "git commit -am \"squash\"";
      gbs = "git --no-pager branch --sort -committerdate";
      xclip = "xclip -selection c";
      please = "sudo";
      n = "nix -Lv";
      nd = "nix -Lv develop -c zsh";
      # Build and evaluate as the invoking user so the ssh-agent is
      # available for the private git+ssh flake inputs; --sudo elevates
      # only the activation steps.
      sn = "nixos-rebuild -v switch --sudo --flake ~/src/enc";
      ns = "nixos-rebuild switch --sudo --flake ~/src/enc";
      gr = "grep -R --exclude='TAGS' --exclude-dir={.stack-work,dist-newstyle,result,result-2} -n";
      where = "pwd";
    };

    shellInit = ''
      if [[ -o interactive ]]; then
        ssh-add -l >/dev/null 2>&1
        if [ $? -eq 2 ]; then
          eval "$(ssh-agent -s)" >/dev/null
        fi

        ssh-add -q ~/.ssh/xpsoasis-ed25519
        ssh-add -q ~/.ssh/id_ed25519
      fi
    '';

    interactiveShellInit = ''
      save_aliases=$(alias -L)
      eval $save_aliases; unset save_aliases
      RPROMPT=${"'"}''${RPROMPT:+$RPROMPT  }%F{244}[%D{%H:%M:%S}]%f${"'"}
    '';

    promptInit = ''
      any-nix-shell zsh --info-right | source /dev/stdin
    '';
  };

  users.users.root.shell = pkgs.zsh;

  users.extraUsers.hhefesto.extraGroups = lib.mkAfter [ "docker" ];
  virtualisation.docker.enable = true;
}
