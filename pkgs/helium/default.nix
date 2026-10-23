# Adapted from nixpkgs' pkgs/applications/networking/browsers/chromium/default.nix.
{
  nixpkgs,
  newScope,
  lib,
  makeWrapper,
  buildPackages,
  ed,
  gnugrep,
  coreutils,
  xdg-utils,
  glib,
  gtk3,
  gtk4,
  adwaita-icon-theme,
  gsettings-desktop-schemas,
  libva,
  pipewire,
  wayland,
  runCommand,
  libkrb5,
  widevine-cdm,
  pkgsBuildBuild,
  pkgs,
  # package customization
  # Note: enable* flags should not require full rebuilds (i.e. only affect the wrapper)
  upstream-info ? lib.importJSON ./info.json,
  proprietaryCodecs ? true,
  enableWideVine ? false,
  cupsSupport ? true,
  commandLineArgs ? "",
}: let
  stdenv = pkgs.rustc.llvmPackages.stdenv;

  chromiumExprs = "${nixpkgs}/pkgs/applications/networking/browsers/chromium";

  # Helper functions for changes that depend on specific versions:
  chromiumVersionAtLeast = min-version: lib.versionAtLeast upstream-info.version min-version;
  versionRange = min-version: upto-version:
    lib.versionAtLeast upstream-info.version min-version
    && lib.versionOlder upstream-info.version upto-version;

  callPackage = newScope chromium;

  chromium = {
    inherit stdenv upstream-info;

    mkChromiumDerivation = callPackage "${chromiumExprs}/common.nix" {
      inherit chromiumVersionAtLeast versionRange;
      inherit proprietaryCodecs cupsSupport;
      ungoogled = true;
      gnChromium = buildPackages.gn.override upstream-info.deps.gn;
    };

    browser = callPackage ./browser.nix {
      inherit chromiumExprs;
    };

    # Consumed by common.nix as the "ungoogler" (patch tree + utils).
    ungoogled-chromium = pkgsBuildBuild.callPackage ./helium-src.nix {
      heliumInfo = upstream-info.helium;
    };
  };

  inherit (chromium) browser;
  inherit (browser) packageName sandboxExecutableName;

  # Fetch, unpack and patch only (no compiling): a cheap check that Helium's
  # patches still apply on top of nixpkgs' chromium expressions.
  patchCheck = browser.overrideAttrs {
    pname = "helium-patch-check";
    configurePhase = "true";
    buildPhase = "true";
    installPhase = "mkdir -p $out $sandbox";
    dontFixup = true;
    requiredSystemFeatures = [];
  };

  # We want users to be able to enableWideVine without rebuilding all of
  # Helium, so we have a separate derivation here that copies Helium
  # and adds the unfree WidevineCdm.
  heliumWV =
    if enableWideVine
    then
      runCommand (browser.name + "-wv") {inherit (browser) version;} ''
        mkdir -p $out
        cp -a ${browser}/* $out/
        chmod u+w $out/libexec/${packageName}
        cp -a ${widevine-cdm}/share/google/chrome/WidevineCdm $out/libexec/${packageName}/
      ''
    else browser;
in
  stdenv.mkDerivation {
    pname = "helium";
    version = upstream-info.helium.version;

    nativeBuildInputs = [
      makeWrapper
      ed
    ];

    buildInputs = [
      # needed for GSETTINGS_SCHEMAS_PATH
      gsettings-desktop-schemas
      glib
      gtk3
      gtk4

      # needed for XDG_ICON_DIRS
      adwaita-icon-theme

      # Needed for kerberos at runtime
      libkrb5
    ];

    outputs = [
      "out"
      "sandbox"
    ];

    buildCommand = let
      browserBinary = "${heliumWV}/libexec/${packageName}/${packageName}";
      libPath = lib.makeLibraryPath [
        libva
        pipewire
        wayland
        gtk3
        gtk4
        libkrb5
      ];
    in
      ''
        mkdir -p "$out/bin"

        makeWrapper "${browserBinary}" "$out/bin/helium" \
          --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
          --add-flags ${lib.escapeShellArg commandLineArgs}

        ed -v -s "$out/bin/helium" << EOF
        2i

        if [ -x "/run/wrappers/bin/${sandboxExecutableName}" ]
        then
          export CHROME_DEVEL_SANDBOX="/run/wrappers/bin/${sandboxExecutableName}"
        else
          export CHROME_DEVEL_SANDBOX="$sandbox/bin/${sandboxExecutableName}"
        fi

        # Make generated desktop shortcuts have a valid executable name.
        export CHROME_WRAPPER='helium'

        # To avoid loading .so files from cwd, LD_LIBRARY_PATH here must not
        # contain an empty section before or after a colon.
        export LD_LIBRARY_PATH="\$LD_LIBRARY_PATH\''${LD_LIBRARY_PATH:+:}${libPath}"

        # libredirect causes chromium to deadlock on startup
        export LD_PRELOAD="\$(echo -n "\$LD_PRELOAD" | ${coreutils}/bin/tr ':' '\n' | ${gnugrep}/bin/grep -v /lib/libredirect\\\\.so$ | ${coreutils}/bin/tr '\n' ':')"

        export XDG_DATA_DIRS=$XDG_ICON_DIRS:$GSETTINGS_SCHEMAS_PATH\''${XDG_DATA_DIRS:+:}\$XDG_DATA_DIRS

      ''
      + lib.optionalString (!xdg-utils.meta.broken) ''
        # Mainly for xdg-open but also other xdg-* tools (this is only a fallback; \$PATH is suffixed so that other implementations can be used):
        export PATH="\$PATH\''${PATH:+:}${xdg-utils}/bin"
      ''
      + ''

        .
        w
        EOF

        ln -sv "${browser.sandbox}" "$sandbox"

        mkdir -p "$out/share"
        for f in '${heliumWV}'/share/*; do
          ln -s -t "$out/share/" "$f"
        done
      '';

    inherit packageName;
    # Not marked unfree with enableWideVine (unlike nixpkgs): this derivation
    # is evaluated under helium-flake's nixpkgs config, which can't allow
    # unfree. Pass an allowUnfree `widevine-cdm` in the override instead.
    meta = browser.meta;
    passthru = {
      inherit (chromium) upstream-info browser ungoogled-chromium;
      inherit sandboxExecutableName patchCheck;
    };
  }
