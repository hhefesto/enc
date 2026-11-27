# directo's binary cache, https://cache.hhefesto.dev, served by xty.
#
# The owner, 2026-11-26: "Do everything that doesn't need extra renting.  You
# have xty and olimpo."  So the cache the OVH lab was to hold lives here, as
# plain files: olimpo signs each path with directo-cache-1 (the key never
# leaves olimpo) and uploads with `nix run .#cache-push -- xty` from
# ~/src/directo (branch plan-terranix).  xty only serves what it was given.
#
#   who may write   the directo-cache user, with olimpo's ~/.ssh/id_ed25519
#                   only, and only by rsync into /var/lib/directo-cache
#                   (rrsync: no shell, no pty, no forwarding, no other path)
#   who may read    anyone: nginx serves the directory, no listing; the
#                   paths are signed, so a client that trusts
#                   directo-cache-1:iE/HQg1DI09LQsWn0Wqwo3szLl6HpJ8MpmLAc9N0bOY=
#                   rejects anything else found here
#   what is in it   what directo's CI would otherwise build (Lean 4.34.0,
#                   BendTT, bend, OpenTofu with its providers), only the
#                   paths cache.nixos.org lacks
#
# Its DNS record (A, proxied) is made and kept by OpenTofu in directo's
# infra/tf/xty.nix, before this was first switched.
{ pkgs, ... }:
let
  dir = "/var/lib/directo-cache";
in
{
  users.groups.directo-cache = { };
  users.users.directo-cache = {
    isSystemUser = true;
    group = "directo-cache";
    home = dir;
    createHome = true;
    homeMode = "755"; # nginx reads it
    # sshd runs the forced command through the user's shell
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      ''restrict,command="${pkgs.rrsync}/bin/rrsync ${dir}" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2Ttj29zyClCr8pSobzAIJVcsEuL4GsPY7+aiK5eaA1 olimpo cache-push''
    ];
  };
  # rrsync runs the rsync on PATH on this side
  environment.systemPackages = [ pkgs.rsync ];

  services.nginx.virtualHosts."cache.hhefesto.dev" = {
    enableACME = true;
    forceSSL = true;
    root = dir;
    extraConfig = ''
      autoindex off;
      add_header X-Content-Type-Options nosniff always;
    '';
    # fixed here, not uploaded: what a Nix client reads first.  Priority 50
    # puts cache.nixos.org (40) ahead of it.
    locations."= /nix-cache-info".extraConfig = ''
      default_type text/x-nix-cache-info;
      return 200 "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 50\n";
    '';
    # a .narinfo may appear later (an upload): never cache a miss for long
    locations."~ \\.narinfo$".extraConfig = ''
      default_type text/x-nix-narinfo;
      expires 1m;
    '';
    locations."/nar/".extraConfig = ''
      default_type application/x-nix-nar;
      expires 30d;
    '';
  };
}
