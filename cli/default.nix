{ pkgs, ... }:
# folio: send something to read to the tablet, and get the digest of your
# notes back. Stdlib-only Go.
pkgs.buildGoModule {
  pname = "folio";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  meta.mainProgram = "folio";
}
