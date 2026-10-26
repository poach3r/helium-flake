# helium-flake

The [Helium](https://helium.computer) browser built from source with Nix.

Helium releases are only picked up once nixos-unstable ships the Chromium
version they are based on, so this can lag a little behind upstream.

Prebuilt binaries built weekly and served from `https://cache.poacher.dev/helium`:

# Installation

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Don't follow nixpkgs here as that means you aren't using the cache
    helium-flake.url = "git+https://tangled.org/poacher.dev/helium-flake";
  };

  outputs = {nixpkgs, helium-flake, ...}: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {inherit helium-flake;};
      modules = [./configuration.nix];
    };
  };
}
```

```nix
# configuration.nix
{pkgs, helium-flake, ...}: {
  nix.settings = {
    substituters = ["https://cache.poacher.dev/helium"];
    trusted-public-keys = ["helium:30StiIr4aOLW446BMkKaE6r+NSdHoeIjJf437XgRY4k="];
  };

  environment.systemPackages = [
    helium-flake.packages.${pkgs.system}.default
  ];
}
```

## Options

The package takes the same wrapper overrides as nixpkgs' `chromium`:

```nix
helium-flake.packages.${pkgs.system}.default.override {
  inherit (pkgs) widevine-cdm;
  enableWideVine = true;
  commandLineArgs = "--ozone-platform-hint=auto";
}
```
