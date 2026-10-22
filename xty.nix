{ pkgs, ... }:
{
  imports = [ ./hardware-configuration-xty.nix ];

  # Host concern: the production data directory was initialised with
  # PostgreSQL 16. Never bump without a migration plan (pre-deploy checks
  # assert this major).
  services.postgresql.package = pkgs.postgresql_16;

  networking.hostName = "xty";

  # nginx resolves proxy_pass upstreams at start-up, and the aaspectra vhost
  # proxies to xpsoasis.hhefesto.dev: on 2026-09-18 a dead domain made nginx
  # refuse to start and took every vhost (docxty.net included) down. Pin our
  # own names to the origin so nginx never depends on public DNS for them,
  # and so the aaspectra → xpsoasis auth subrequest skips the Cloudflare
  # proxy (the names publicly resolve to Cloudflare edge addresses).
  networking.hosts."62.238.6.4" = [
    "xpsoasis.hhefesto.dev"
    "aaspectra.xpsoasis.hhefesto.dev"
    "directo.hhefesto.dev"
    "refl.hhefesto.dev"
  ];
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
  networking.useDHCP = false;

  networking.interfaces.enp1s0.ipv4.addresses = [
    {
      address = "62.238.6.4";
      prefixLength = 32;
    }
  ];

  networking.defaultGateway = {
    address = "172.31.1.1";
    interface = "enp1s0";
  };

  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment.enable = true;
  };

  security.sudo.wheelNeedsPassword = false;

  # ~/.spacemacs. xty has no home-manager and no ~/src, so instead of a
  # link into a checkout (the workstations' home.nix) it links to this
  # flake's ./spacemacs in the store, which every deploy brings along.  L+
  # replaces whatever is there, such as the dead link into this repo's
  # old checkout path that an early docxty deploy left.
  systemd.tmpfiles.rules = [
    "L+ /home/hhefesto/.spacemacs - - - - ${./spacemacs}"
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcDIsto/6GS7XwTl+uVo4ABeRlRjDwAU0HHy8irqLaB hhefesto@olimpo"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAolzCtF1t8rPKSRzvREQPBUjxRAi5medog8Ebi0n/G hhefesto@delfos"
  ];
}
