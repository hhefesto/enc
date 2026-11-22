#!/usr/bin/env bash
# Rotate mugen-web's (mugen-app's) sign-in password.
# `mugen-web passwd` asks for the new password (never echoed) and writes its
# bcrypt hash into a scratch state dir; the hash is age-encrypted for the
# admin key and olimpo, and the scratch dir removed. Nothing is stored in
# plaintext. olimpo's mugen-web links the secret as its password.bcrypt
# (services.mugen-web.origin.passwordFile), so the new password counts as
# soon as olimpo is rebuilt (!ns).
set -euo pipefail
cd "$(dirname "$0")"

recipients=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAolzCtF1t8rPKSRzvREQPBUjxRAi5medog8Ebi0n/G hhefesto@rdataa.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP5EUe2fiscGEdLFXkTfxPLRmHuRBwqCbHcFSabqVWN1 root@olimpo"
)

args=()
for r in "${recipients[@]}"; do
  args+=(-r "$r")
done

mw=(mugen-web)
command -v mugen-web > /dev/null || mw=(nix run "git+ssh://git@github.com/hhefesto/mugen-app" --)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
MUGEN_WEB_STATE="$tmp" "${mw[@]}" passwd
nix run nixpkgs#age -- "${args[@]}" -o mugen-web-password.age < "$tmp/password.bcrypt"
echo "wrote $(pwd)/mugen-web-password.age"
echo "now: git add secrets/mugen-web-password.age && rebuild olimpo (!ns)"
