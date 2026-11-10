# lan-cache.nix: olimpo and delfos share their Nix stores over the LAN.
#
# Each machine serves its store read-only over ssh-ng to the other's root
# (the nix-ssh user, nix.sshServe), signs what it builds with
# /etc/nix/cache-priv-key.pem, and trusts the other's key.
#
# The other's store is a substituter only while it answers. nix-lan-probe
# pings it every 20 s and writes /run/nix-lan/substituters.conf, which
# nix.conf includes. When the other machine is off, Nix doesn't list it and
# prints no errors. When it's on but lacks a path, Nix silently takes the
# path from the next cache or builds it. (Listed for good, an unreachable
# ssh-ng store printed "error: failed to start SSH master connection" and
# an error for each path, though the build went on.)
#
# hhefesto is a trusted Nix user, so his ~/.config/nix/nix.conf reaches the
# daemon, and a plain `substituters = ...` there replaces this whole list.
# delfos's did, so it asked neither olimpo nor FlakeHub until 2026-11-10.
# home.nix now writes that file with only extra-* lines.
{ config, lib, pkgs, ... }:
let
  hosts = {
    olimpo = {
      ip = "192.168.3.5";
      # /etc/ssh/ssh_host_ed25519_key.pub
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP5EUe2fiscGEdLFXkTfxPLRmHuRBwqCbHcFSabqVWN1";
      # /root/.ssh/id_ed25519.pub: the key its nix-daemon logs in with
      rootKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPffFDK3fp6W/Z9PXCT7ZK+fSUB40JW/6Ezi9GwkiT9R root@olimpo";
      # /etc/nix/cache-pub-key.pem: what its paths are signed with
      cacheKey = "olimpo:TF6AYCr4dpXzfG9KXGRaRxWuqo6lnyXABLhIc5wVnD0=";
    };
    delfos = {
      ip = "192.168.3.6";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINM3/adCok24i8fl600FBto4A/thxXaKpDu5B3ec3QT";
      rootKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPjABQfwQ+vpgGqO6zsWNsG40ZFc55Z3zZQPA+3F4V9 root@delfos";
      cacheKey = "delfos:D3sIYhrkcJUb7O01+r94oD50NVYvOS02Hg2opXu7aGw=";
    };
  };

  me = config.networking.hostName;
  peerName = if me == "olimpo" then "delfos" else "olimpo";
  peer = hosts.${peerName};
  alias = "${peerName}-nix-cache";
  store = "ssh-ng://nix-ssh@${alias}";
  conf = "/run/nix-lan/substituters.conf";

  probe = pkgs.writeShellApplication {
    name = "nix-lan-probe";
    runtimeInputs = [ pkgs.coreutils pkgs.iputils pkgs.openssh config.nix.package ];
    text = ''
      # A ping costs the other machine nothing and leaves no log there. A
      # login (nix store info) is what Nix will do, so it's made when the
      # other machine comes back, and every 5 minutes while it's up: on
      # another network, someone else may have its address.
      mkdir -p "$(dirname '${conf}')"
      state=down
      n=0
      while true; do
        if ping -c 1 -W 1 ${peer.ip} > /dev/null 2>&1; then
          if [ "$state" = down ] || [ "$n" -ge 15 ]; then
            n=0
            if timeout 15 nix store info --store '${store}' > /dev/null 2>&1; then
              state=up
            else
              state=down
            fi
          fi
        else
          state=down
        fi
        n=$((n + 1))
        if [ "$state" = up ]; then
          line='extra-substituters = ${store}'
        else
          line='# ${peerName} is not answering: its store is left out until it does'
        fi
        if [ "$(cat '${conf}' 2> /dev/null)" != "$line" ]; then
          printf '%s\n' "$line" > '${conf}.tmp'
          mv '${conf}.tmp' '${conf}'
          echo "${peerName}'s store: $state"
        fi
        sleep 20
      done
    '';
  };
in
{
  # Pull from the other's store, while it answers (see above).
  nix.settings.trusted-substituters = [ store ];
  nix.settings.trusted-public-keys = [ peer.cacheKey ];
  nix.extraOptions = ''
    !include ${conf}
  '';

  systemd.services.nix-lan-probe = {
    description = "Lists ${peerName}'s Nix store as a substituter while it answers";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = lib.getExe probe;
      Restart = "always";
      RestartSec = 5;
      # ssh and nix want a home; the key is named in programs.ssh below.
      Environment = "HOME=/root";
    };
  };

  # Serve this store to the other's root.
  nix.sshServe = {
    enable = true;
    protocol = "ssh-ng";
    keys = [ peer.rootKey ];
  };

  # Sign every path this machine builds, so the other accepts it.
  nix.settings.secret-key-files = [ "/etc/nix/cache-priv-key.pem" ];

  # nix.sshServe runs `nix-daemon --stdio` as the nix-ssh user.
  # allowed-users is restricted in configuration-core.nix, so re-grant
  # nix-ssh here (list-merges with the core values).
  nix.settings.allowed-users = [ "nix-ssh" ];
  nix.settings.trusted-users = [ "nix-ssh" ];

  # The other's host key, so root's ssh doesn't prompt.
  programs.ssh.knownHosts.${alias} = {
    hostNames = [ alias peer.ip ];
    publicKey = peer.hostKey;
  };

  programs.ssh.extraConfig = ''
    Host ${alias}
      HostName ${peer.ip}
      User nix-ssh
      IdentityFile /root/.ssh/id_ed25519
      IdentitiesOnly yes
      BatchMode yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ConnectTimeout 3
  '';
}
