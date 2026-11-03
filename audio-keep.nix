# audio-keep (audio-keep.hs at the repo root): the sound goes back to the
# output it was on before the screen blanked. Standalone like
# llm-transcript.nix; olimpo.nix runs it as a user service.
{ pkgs }:

pkgs.writers.writeHaskellBin "audio-keep" { libraries = _: [ ]; } ./audio-keep.hs
