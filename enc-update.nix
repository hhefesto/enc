# enc-update (enc-update.bend at the repo root, where its decisions, its docs
# and its laws are): NixOS updates for olimpo, delfos and xty, made only while
# each machine is idle, checked on each machine after its switch, and rolled
# back where they broke something. This file is only the shim: the files the
# program reads (/etc/enc-update/config and /etc/enc-update/health), the
# programs it runs, and the builder's timer.
{ bend }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.enc-update;
  inherit (lib) mkOption mkEnableOption mkIf types concatStringsSep concatMapStrings mapAttrsToList;

  bin = pkgs.runCommand "enc-update-bin" { nativeBuildInputs = [ bend ]; } ''
    export HOME=$TMPDIR BEND_NO_TELEMETRY=1
    cp ${./enc-update.bend} enc-update.bend
    mkdir -p $out/bin
    bend enc-update.bend -o $out/bin/enc-update
  '';

  pkg = pkgs.writeShellApplication {
    name = "enc-update";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gitMinimal
      pkgs.curl
      pkgs.openssh
      pkgs.util-linux
      pkgs.procps
      pkgs.xprintidle
      config.nix.package
      config.systemd.package
    ];
    text = ''exec ${bin}/bin/enc-update "$@"'';
  };

  line = k: v: "${k} ${toString v}\n";
  lines = k: vs: concatMapStrings (line k) vs;

  configText =
    line "user" cfg.user
    + line "load.max" cfg.loadMax
    + line "idle.minutes" cfg.idleMinutes
    + line "ac.required" (if cfg.acRequired then "yes" else "no")
    + line "hours.from" cfg.hours.from
    + line "hours.to" cfg.hours.to
    + line "x.display" cfg.xDisplay
    + line "x.authority" cfg.xAuthority
    + lib.optionalString cfg.builder (
      line "repo" cfg.repo
      + line "branch" cfg.branch
      + line "push" cfg.push
      + line "every.hours" cfg.everyHours
      + lines "target" cfg.targets
      + lines "input" cfg.inputs
      + lines "forbid" cfg.forbid
      + concatStringsSep "" (mapAttrsToList (t: gs: lines "gate.${t}" gs) cfg.gates)
    );
in
{
  options.services.enc-update = {
    enable = mkEnableOption "enc-update's idle and health checks on this machine";

    builder = mkOption {
      type = types.bool;
      default = false;
      description = "This machine runs the update cycle (builds, switches every target).";
    };

    user = mkOption { type = types.str; default = "hhefesto"; };
    loadMax = mkOption { type = types.str; default = "4"; description = "The highest 5-minute load that is still idle."; };
    idleMinutes = mkOption { type = types.int; default = 30; };
    acRequired = mkOption { type = types.bool; default = false; };
    hours = {
      from = mkOption { type = types.int; default = 0; };
      to = mkOption { type = types.int; default = 0; description = "from = to: any hour."; };
    };
    xDisplay = mkOption { type = types.str; default = ":0"; };
    xAuthority = mkOption { type = types.str; default = "/run/user/1000/gdm/Xauthority"; };

    health = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "This machine's checks: `unit NAME`, `http NAME URL [HOST:PORT:ADDR]`, `cmd NAME PROG ARGS...`.";
    };

    repo = mkOption { type = types.str; default = "git@github.com:hhefesto/enc.git"; };
    branch = mkOption { type = types.str; default = "master"; };
    push = mkOption { type = types.enum [ "none" "branch" "master" ]; default = "none"; };
    everyHours = mkOption { type = types.int; default = 20; };
    targets = mkOption { type = types.listOf types.str; default = [ ]; description = "`NAME local` or `NAME root@HOST`, in update order."; };
    inputs = mkOption { type = types.listOf types.str; default = [ ]; description = "The flake inputs updated; none: nothing is."; };
    forbid = mkOption { type = types.listOf types.str; default = [ ]; description = "Derivations an update may not build."; };
    gates = mkOption { type = types.attrsOf (types.listOf types.str); default = { }; description = "A target's apps (of enc's flake) that must pass before its switch."; };
    onCalendar = mkOption { type = types.str; default = "hourly"; };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkg ];
    environment.etc."enc-update/config".text = configText;
    environment.etc."enc-update/health".text = concatMapStrings (h: h + "\n") cfg.health;

    systemd.tmpfiles.rules = lib.optionals cfg.builder [
      "d /var/lib/enc-update 0755 root root -"
      "d /var/lib/enc-update/u 0755 ${cfg.user} users -"
    ];

    systemd.services.enc-update = mkIf cfg.builder {
      description = "enc-update: update every machine while it is idle";
      # The cycle switches this machine too: a switch must not stop it halfway.
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkg}/bin/enc-update run";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.enc-update = mkIf cfg.builder {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
