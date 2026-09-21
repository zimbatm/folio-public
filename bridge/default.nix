{ pkgs, ... }:
# folio-bridge: the Anthropic Messages API on top of `claude -p`, so Folio runs
# on a Claude subscription. Stdlib-only Go.
pkgs.buildGoModule {
  pname = "folio-bridge";
  version = "0.2.0";
  src = ./.;
  vendorHash = null;
  meta.mainProgram = "folio-bridge";
}
