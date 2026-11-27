{ pkgs, ... }:
{
  imports = [ ./hardware-configuration-xty.nix ];

  # /boot is 253 MB: a deploy failed on 11-04 with it full of old kernels
  boot.loader.systemd-boot.configurationLimit = 4;

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
    # A client that stops answering is dropped after 45 s (3 probes, 15 s
    # apart) instead of TCP keepalive's ~2 h.  A dead session of olimpo's
    # mugen-web tunnel (below) kept 127.0.0.1:3008 bound here for ~2h10m on
    # 11-12, 11-13 and 11-14, refusing every reconnect, so mugen-web's API
    # was down that long.
    ClientAliveInterval = 15;
    ClientAliveCountMax = 3;
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
    # olimpo's ~/.ssh/id_ed25519 (no passphrase): enc-update's ssh and nix
    # copy, which run from a system unit with no ssh agent (enc-update.nix)
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2Ttj29zyClCr8pSobzAIJVcsEuL4GsPY7+aiK5eaA1"
  ];

  # olimpo's reverse tunnel for mugen-web (services.mugen-web.origin.tunnel
  # there) logs in as hhefesto with this key, from a system unit with no
  # ssh agent: the key may only open 127.0.0.1:3008 here (no shell, no pty,
  # no other forward).
  users.users.hhefesto.openssh.authorizedKeys.keys = [
    ''restrict,port-forwarding,permitlisten="127.0.0.1:3008" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAolzCtF1t8rPKSRzvREQPBUjxRAi5medog8Ebi0n/G mugen-web tunnel from olimpo''
  ];

  # enc-update: xty is updated by olimpo (olimpo.nix), last, only from 3 to
  # 6 in the morning and quiet; every site checked on xty itself before and
  # after its switch (a site that stops answering switches it back)
  services.enc-update = {
    enable = true;
    loadMax = "1";
    idleMinutes = 30;
    hours = { from = 3; to = 6; };
    health = [
      "unit sshd" "unit nginx" "unit postgresql" "unit fail2ban"
      "unit directo-backend" "unit expedientes-backend" "unit xpsoasis-backend"
      "unit aaspectra" "unit wedding-backend" "unit refl"
      "http directo https://directo.hhefesto.dev directo.hhefesto.dev:443:127.0.0.1"
      "http docxty https://docxty.net docxty.net:443:127.0.0.1"
      "http elcubodeedgar https://elcubodeedgar.hhefesto.dev elcubodeedgar.hhefesto.dev:443:127.0.0.1"
      "http telomare https://telomare.hhefesto.dev telomare.hhefesto.dev:443:127.0.0.1"
      "http cata https://cata.hhefesto.dev cata.hhefesto.dev:443:127.0.0.1"
      "http directo-devops https://directo-devops.hhefesto.dev directo-devops.hhefesto.dev:443:127.0.0.1"
      "http directo-cache https://cache.hhefesto.dev/nix-cache-info cache.hhefesto.dev:443:127.0.0.1"
      "http mugen https://mugen.hhefesto.dev mugen.hhefesto.dev:443:127.0.0.1"
      "http refl https://refl.hhefesto.dev refl.hhefesto.dev:443:127.0.0.1"
      "http xpsoasis https://xpsoasis.hhefesto.dev xpsoasis.hhefesto.dev:443:127.0.0.1"
      "http aaspectra https://aaspectra.xpsoasis.hhefesto.dev aaspectra.xpsoasis.hhefesto.dev:443:127.0.0.1"
      "http xty-y-dan https://xty-y-dan.net xty-y-dan.net:443:127.0.0.1"
      "http edgarsrubicscube https://edgarsrubicscube.hhefesto.dev edgarsrubicscube.hhefesto.dev:443:127.0.0.1"
    ];
  };
}
