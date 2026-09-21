{ pkgs, ... }:
# rmc — renders reMarkable v6 .rm pages to SVG (github.com/ricklupton/rmc).
# folio-server renders the mirrored notebooks with it. 0.3.0 pins
# rmscene < 0.7; nixpkgs has 0.8.0, which renders the Move's pages the same.
pkgs.python3Packages.buildPythonApplication {
  pname = "rmc";
  version = "0.3.0";
  pyproject = true;
  src = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/source/r/rmc/rmc-0.3.0.tar.gz";
    hash = "sha256-V6/hTVZpQIW2o4KqK5O3uG6yHpPnILFqgpkKoNZRPcs=";
  };
  build-system = [ pkgs.python3Packages.poetry-core ];
  dependencies = with pkgs.python3Packages; [
    click
    rmscene
  ];
  pythonRelaxDeps = [ "rmscene" ];
  meta.mainProgram = "rmc";
}
