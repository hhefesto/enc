# directo-backup (directo-backup.bend at the repo root, where its steps, its
# docs and its laws are): directo's database pulled from xty into olimpo's
# restic repo every night, restored into a drill database on xty to show the
# backup works, and copied to delfos. This file is only the shim: the programs
# it runs, and the password file restic reads (the agenix secret
# directo-backup-restic, or $RESTIC_PASSWORD_FILE to try it by hand).
{ pkgs, bend }:

let
  bin = pkgs.runCommand "directo-backup-bin" { nativeBuildInputs = [ bend ]; } ''
    export HOME=$TMPDIR BEND_NO_TELEMETRY=1
    cp ${./directo-backup.bend} directo-backup.bend
    mkdir -p $out/bin
    bend directo-backup.bend -o $out/bin/directo-backup
  '';
in
pkgs.writeShellApplication {
  name = "directo-backup";
  runtimeInputs = [
    pkgs.restic
    pkgs.openssh
    pkgs.coreutils
  ];
  text = ''
    export RESTIC_PASSWORD_FILE="''${RESTIC_PASSWORD_FILE:-/run/agenix/directo-backup-restic}"
    export RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
    exec ${bin}/bin/directo-backup "$@"
  '';
}
