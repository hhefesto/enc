{ config, osConfig, pkgs, lib, telomare, xmobarrc, ... }:
let
  # This checkout. ~/.spacemacs points into it and the spacemacs activation
  # commits to it, so it must live here on every host.
  repo = "${config.home.homeDirectory}/src/etc-nixos-configuration";
  spacemacsRev = lib.fileContents ./spacemacs.rev;
in
{
  home = {
    username = "hhefesto";
    homeDirectory = "/home/hhefesto";
    stateVersion = "22.11";
  };
  home.activation = {
    # ~/.claude/settings.json is a real file that Claude Code rewrites itself,
    # so it must not become a /nix/store symlink. Merge in just the two hook
    # entries and leave everything else untouched. Idempotent across rebuilds.
    #
    # The hooks call llm-transcript by name rather than by store path: hooks
    # inherit the user's PATH, and ~/.claude is not a GC root, so a pinned
    # store path could be collected out from under it.
    claudeTranscriptHooks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings="$HOME/.claude/settings.json"
      mkdir -p "$HOME/.claude"
      [ -s "$settings" ] || echo '{}' > "$settings"

      hook='{"hooks":[{"type":"command","command":"jq -r \".transcript_path // empty\" | xargs -r llm-transcript render","timeout":120}]}'
      tmp=$(mktemp)
      if ${pkgs.jq}/bin/jq --argjson h "$hook" \
           '.hooks = ((.hooks // {}) | .Stop = [$h] | .SessionEnd = [$h])' \
           "$settings" > "$tmp"; then
        mv "$tmp" "$settings"
      else
        echo "claudeTranscriptHooks: could not merge hooks into $settings" >&2
        rm -f "$tmp"
      fi
    '';

    # Spacemacs runs as it would on any distro: ~/.emacs.d is a git checkout
    # of develop that I and Spacemacs update, ELPA packages are Spacemacs'
    # own, and ~/.spacemacs is ./spacemacs (home.file below). Nix only clones
    # the checkout when it is missing (a new machine, at ./spacemacs.rev), and
    # on every switch commits what the live state has moved to. Failures warn
    # and never fail the switch.
    spacemacs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      git=${pkgs.git}/bin/git
      emacsd="$HOME/.emacs.d"
      repo=${repo}

      if ! { [ -e "$emacsd/.git" ] && $git -C "$emacsd" rev-parse -q --verify HEAD >/dev/null; }; then
        mkdir -p "$emacsd"
        $git -C "$emacsd" init -q
        $git -C "$emacsd" remote add origin https://github.com/syl20bnr/spacemacs.git 2>/dev/null || true
        if $git -C "$emacsd" fetch -q origin develop \
           && $git -C "$emacsd" checkout -q -f -B develop ${spacemacsRev} \
           && $git -C "$emacsd" branch -q -u origin/develop; then
          rm -f "$emacsd/.nix-spacemacs-src"
        else
          echo "spacemacs: could not check out Spacemacs into $emacsd; the next switch retries" >&2
        fi
      fi

      if [ -d "$repo/.git" ] && head=$($git -C "$emacsd" rev-parse -q --verify HEAD); then
        # The recorded core only moves forward: a host that is behind (or
        # has not fetched what another host recorded) leaves it alone.
        old=$(cat "$repo/spacemacs.rev" 2>/dev/null || true)
        if [ "$head" != "$old" ]; then
          if $git -C "$emacsd" merge-base --is-ancestor "$old" "$head" 2>/dev/null; then
            echo "$head" > "$repo/spacemacs.rev"
          else
            echo "spacemacs: $emacsd is at ''${head:0:7}, not ahead of spacemacs.rev ''${old:0:7}; not recording it" >&2
          fi
        fi

        what=""
        $git -C "$repo" diff --quiet HEAD -- spacemacs || what="dotfile"
        $git -C "$repo" diff --quiet HEAD -- spacemacs.rev \
          || what="''${what:+$what, }core ''${old:0:7}..''${head:0:7}"
        if [ -n "$what" ]; then
          $git -C "$repo" commit -q -m "spacemacs: $what (${osConfig.networking.hostName})" \
               -- spacemacs spacemacs.rev \
            || echo "spacemacs: could not auto-commit; commit spacemacs and spacemacs.rev by hand" >&2
        fi
      fi
    '';
  };

  programs.zsh.enable = true;

  # Add the doom binary to your PATH
  # home.sessionPath = [ "$HOME/.emacs.d/bin"
  #                    ];

  # The bare binary: Spacemacs installs every elisp package itself.
  programs.emacs.enable = true;

  home.file.".spacemacs".source =
    config.lib.file.mkOutOfStoreSymlink "${repo}/spacemacs";
  # The whole source tree, so telomare-mode-spacemacs.el finds its flake.nix.
  home.file.".local/share/telomare".source = telomare;

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  programs.git = {
    enable = true;
    signing.format = null;
    settings = {
      user = {
        email = "hhefesto@rdataa.com";
        name = "hhefesto";
      };
      core = {
        editor = "emacs";
      };
      merge = {
        conflictstyle = "diff3";
      };
      alias = {
        lg = "!git lg1 --simplify-by-decoration";
        lg1 = "!git lg1-specific --all --simplify-by-decoration";
        lg2 = "!git lg2-specific --all --simplify-by-decoration";
        lg3 = "!git lg3-specific --all --simplify-by-decoration";

        lg1-specific = "log --graph --abbrev-commit --decorate --format=format:\'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(auto)%d%C(reset)\'";
        lg2-specific = "log --graph --abbrev-commit --decorate --format=format:\'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(auto)%d%C(reset)%n\'\'          %C(white)%s%C(reset) %C(dim white)- %an%C(reset)\'";
        lg3-specific = "log --graph --abbrev-commit --decorate --format=format:\'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset) %C(bold cyan)(committed: %cD)%C(reset) %C(auto)%d%C(reset)%n\'\'          %C(white)%s%C(reset)%n\'\'          %C(dim white)- %an <%ae> %C(reset) %C(dim white)(committer: %cn <%ce>)%C(reset)\'";

        # ATTENTION: All aliases prefixed with ! run in /bin/sh make sure you use sh syntax, not bash/zsh or whatever
        # recentb = "!r() { refbranch=$1 count=$2; git for-each-ref --sort=-committerdate refs/heads --format=\'%(refname:short)|%(HEAD)%(color:yellow)%(refname:short)|%(color:bold green)%(committerdate:relative)|%(color:blue)%(subject)|%(color:magenta)%(authorname)%(color:reset)\' --color=always --count=${count:-20} | while read line; do branch=$(echo \"$line\" | awk \'BEGIN { FS = \"|\" }; { print $1 }\' | tr -d \'*\'); ahead=$(git rev-list --count \"${refbranch:-master}..${branch}\"); behind=$(git rev-list --count \"${branch}..${refbranch:-master}\"); colorline=$(echo \"$line\" | sed \'s/^[^|]*|//\'); echo \"$ahead|$behind|$colorline\" | awk -F\'|\' -vOFS=\'|\' \'{$5=substr($5,1,70)}1\' ; done | ( echo \"ahead|behind||branch|lastcommit|message|author\\n\" && cat) | column -ts\'|\';}; r";
      };
    };
  };
  programs.xmobar.enable = true;
  programs.xmobar.extraConfig = builtins.readFile xmobarrc;
  # The binary only: with no `remotes` declared, the module leaves
  # ~/.config/rclone/rclone.conf to rclone itself.
  programs.rclone.enable = true;
  programs.home-manager.enable = true;

  services.dunst.enable = true;

  home.packages = with pkgs; [
    gnome-themes-extra
    adw-gtk3  # Add this for better Adwaita theme support
  ];

  gtk = {
    enable = true;

    theme = {
      name = "adw-gtk3-dark";  # Using adw-gtk3 instead of plain Adwaita
      package = pkgs.adw-gtk3;
    };

    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
    };

    gtk4.theme = null;
    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = true;
    };
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "adw-gtk3-dark";
      enable-hot-corners = false;
    };

    "org/gnome/settings-daemon/plugins/media-keys" = {
      screenshot = [];
      window-screenshot = [];
      area-screenshot = [];
      screenshot-clip = [];
      window-screenshot-clip = [];
      area-screenshot-clip = [];
    };

    # These additional settings help ensure dark mode consistency
    "org/gnome/shell/extensions/user-theme" = {
      name = "adw-gtk3-dark";
    };

    "org/gtk/settings/file-chooser" = {
      theme-variant = "dark";
    };

    "org/gnome/nautilus/preferences" = {
      theme-variant = "dark";
    };
  };
}
