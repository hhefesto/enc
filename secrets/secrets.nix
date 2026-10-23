let
  # Recipients able to decrypt this repo's secrets. Add hosts/users here as needed.
  admin  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBAolzCtF1t8rPKSRzvREQPBUjxRAi5medog8Ebi0n/G hhefesto@rdataa.com";
  olimpo = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP5EUe2fiscGEdLFXkTfxPLRmHuRBwqCbHcFSabqVWN1 root@olimpo";
  delfos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINM3/adCok24i8fl600FBto4A/thxXaKpDu5B3ec3QT root@delfos";
  xty    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5cWilmgGZa24PrEFftyajabwxHvR4jxvkIvqkyCtmG root@xty";

  users   = [ admin ];
  systems = [ olimpo delfos xty ];
in
{
  # SHA-512 crypt hash of the shared login password for root + hhefesto,
  # consumed via users.users.*.hashedPasswordFile in configuration-core.nix.
  # Rotate with ./rotate-user-password.sh
  "user-password.age".publicKeys = users ++ systems;
}
