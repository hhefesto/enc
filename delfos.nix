{ lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration-delfos.nix ./lan-cache.nix ];

  networking.hostName = "delfos";

  # Dynamic time zone for travel: IP-based via tzupdate.
  # Triggered (a) at boot after network is up, (b) on every NM connection up.
  time.timeZone = lib.mkForce null;

  systemd.services.tzupdate = {
    description = "Update system timezone from IP geolocation";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      # tzupdate 3.1.0 unlinks targets before symlinking; ENOENT on first run.
      ExecStartPre = pkgs.writeShellScript "tzupdate-ensure-targets" ''
        [ -e /etc/localtime ] || ${pkgs.coreutils}/bin/ln -sfn ${pkgs.tzdata}/share/zoneinfo/UTC /etc/localtime
        [ -e /etc/timezone ]  || ${pkgs.coreutils}/bin/touch /etc/timezone
      '';
      ExecStart = "${pkgs.tzupdate}/bin/tzupdate --always-write-debian-timezone -z ${pkgs.tzdata}/share/zoneinfo";
    };
  };

  networking.networkmanager.dispatcherScripts = [{
    type = "basic";
    source = pkgs.writeShellScript "tzupdate-on-nm-up" ''
      status=$2
      case "$status" in
        up|vpn-up|dhcp4-change|dhcp6-change)
          ${pkgs.systemd}/bin/systemctl start --no-block tzupdate.service
          ;;
      esac
    '';
  }];
}
