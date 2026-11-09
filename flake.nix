{
  description = "Helium browser built from source.";

  nixConfig = {
    extra-substituters = ["https://cache.poacher.dev/helium"];
    extra-trusted-public-keys = ["helium:30StiIr4aOLW446BMkKaE6r+NSdHoeIjJf437XgRY4k="];
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Uses the pinned nixpkgs rather than the overlaid package set
    overlays.default = final: _prev: {
      helium = self.packages.${final.stdenv.hostPlatform.system}.helium;
    };

    packages.${system} = {
      helium = pkgs.callPackage ./pkgs/helium {inherit nixpkgs;};
      default = self.packages.${system}.helium;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [pkgs.python3 pkgs.git];
    };
  };
}
