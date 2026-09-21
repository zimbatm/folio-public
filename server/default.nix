{ pkgs, ... }:
# folio-server: builds Folio's versions with an agent, serves them to the
# tablet, and mirrors and searches the notebooks. Stdlib-only Go.
pkgs.buildGoModule {
  pname = "folio-server";
  version = "0.2.0";
  src = ./.;
  vendorHash = null;
  meta.mainProgram = "folio-server";
}
