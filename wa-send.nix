# wa-send (wa-send.bend at the repo root, where its laws and its docs are): a
# WhatsApp message through the Brave already logged in on this machine's screen,
# by xdotool. Built from Bend like ana's tools; this file is only the shim: where
# the screen is, and the programs it drives (brave and systemd-run are the system's).
{ pkgs, bend }:

let
  bin = pkgs.runCommand "wa-send-bin" { nativeBuildInputs = [ bend ]; } ''
    export HOME=$TMPDIR BEND_NO_TELEMETRY=1
    cp ${./wa-send.bend} wa-send.bend
    mkdir -p $out/bin
    bend wa-send.bend -o $out/bin/wa-send
  '';
in
pkgs.writeShellApplication {
  name = "wa-send";
  runtimeInputs = [
    pkgs.xdotool
    pkgs.scrot
    pkgs.coreutils
  ];
  text = ''
    export DISPLAY="''${DISPLAY:-:0}"
    export XAUTHORITY="''${XAUTHORITY:-/run/user/$(id -u)/gdm/Xauthority}"
    exec ${bin}/bin/wa-send "$@"
  '';
}
