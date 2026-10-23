# Adapted from nixpkgs' pkgs/applications/networking/browsers/chromium/browser.nix,
# plus the Helium-specific source steps from helium-linux/scripts/shared.sh
# that ungoogled-chromium doesn't have.
{
  lib,
  fetchurl,
  unzip,
  mkChromiumDerivation,
  upstream-info,
  ungoogled-chromium,
  chromiumExprs,
}: let
  helium = ungoogled-chromium {
    inherit (upstream-info.deps.ungoogled-patches) rev hash;
  };

  # deps.ini: downloads Helium unpacks into the Chromium tree
  # (search engine data, onboarding page, bundled uBlock Origin).
  extraDeps =
    lib.mapAttrsToList (name: dep: {
      inherit (dep) outputPath stripLeadingDirs;
      src = fetchurl {
        inherit (dep) url sha256;
        name = "helium-${name}-${baseNameOf dep.url}";
      };
    })
    upstream-info.helium.extraDeps;

  unpackExtraDeps =
    lib.concatMapStrings (dep: ''
      rm -rf "$NIX_BUILD_TOP/extra-dep"
      mkdir -p "$NIX_BUILD_TOP/extra-dep" "src/${dep.outputPath}"
      (cd "$NIX_BUILD_TOP/extra-dep" && unpackFile ${dep.src})
      cp -r "$NIX_BUILD_TOP/extra-dep/${
        if dep.stripLeadingDirs != null
        then dep.stripLeadingDirs
        else "."
      }/." "src/${dep.outputPath}/"
      chmod -R u+w "src/${dep.outputPath}"
    '')
    extraDeps;
in
  mkChromiumDerivation (base: rec {
    name = "helium-browser";
    pname = "helium-unwrapped";
    version = upstream-info.helium.version;
    packageName = "helium";
    buildTargets = [
      "chrome_sandbox"
      "chrome"
    ];

    outputs = [
      "out"
      "sandbox"
    ];

    sandboxExecutableName = "__chromium-suid-sandbox";

    nativeBuildInputs = base.nativeBuildInputs ++ [unzip];

    postUnpack = ''
      ${unpackExtraDeps}
    '';

    patches =
      # Helium's use-system-python3.patch makes the same .gn change (and
      # patches siso's platform.star too), so this one would make it fail.
      lib.filter
      (p: !lib.hasInfix "revert-DEPS-use-DEPS-provided-python" (toString p))
      base.patches
      ++ [
        # common.nix only applies this for packageName == "chromium". It lets
        # the enableWideVine wrapper bundle the CDM next to the binary instead
        # of downloading it at runtime.
        "${chromiumExprs}/patches/chromium-150-widevine-disable-auto-download-allow-bundle.patch"
      ];

    # common.nix already pruned, applied Helium's patches (via
    # helium-src.nix's patches.py wrapper) and domain substitution.
    postPatch =
      base.postPatch
      + ''
        python3 ${helium}/utils/name_substitution.py --sub -t . --backup-path "$NIX_BUILD_TOP/namesubs.tar"
        python3 ${helium}/utils/i18n_apply.py -t .
        python3 ${helium}/utils/helium_version.py --tree ${helium} --platform-tree ${helium}/platform --chromium-tree .
        python3 ${helium}/utils/replace_resources.py ${helium}/resources/helium_resources.txt ${helium}/resources .
      '';

    # Helium's flags.gn + flags.linux.gn, minus the toolchain flags that
    # conflict with nixpkgs (see GN_DENYLIST in scripts/update.py).
    gnFlags = upstream-info.helium.gnFlags;

    installPhase = ''
      mkdir -p "$libExecPath"
      cp -v "$buildPath/"*.so "$buildPath/"*.pak "$buildPath/"*.bin "$libExecPath/"
      cp -v "$buildPath/libvulkan.so.1" "$libExecPath/"
      cp -v "$buildPath/vk_swiftshader_icd.json" "$libExecPath/"
      cp -v "$buildPath/icudtl.dat" "$libExecPath/"
      cp -vLR "$buildPath/locales" "$buildPath/resources" "$libExecPath/"
      cp -v "$buildPath/helium_crashpad_handler" "$libExecPath/"
      cp -v "$buildPath/helium" "$libExecPath/$packageName"

      # Swiftshader
      # See https://stackoverflow.com/a/4264351/263061 for the find invocation.
      if [ -n "$(find "$buildPath/swiftshader/" -maxdepth 1 -name '*.so' -print -quit)" ]; then
        echo "Swiftshader files found; installing"
        mkdir -p "$libExecPath/swiftshader"
        cp -v "$buildPath/swiftshader/"*.so "$libExecPath/swiftshader/"
      else
        echo "Swiftshader files not found"
      fi

      mkdir -p "$sandbox/bin"
      cp -v "$buildPath/chrome_sandbox" "$sandbox/bin/${sandboxExecutableName}"

      mkdir -vp "$out/share/man/man1"
      cp -v "$buildPath/chrome.1" "$out/share/man/man1/$packageName.1"

      for icon_file in chrome/app/theme/chromium/product_logo_*[0-9].png; do
        num_and_suffix="''${icon_file##*logo_}"
        icon_size="''${num_and_suffix%.*}"
        expr "$icon_size" : "^[0-9][0-9]*$" || continue
        logo_output_prefix="$out/share/icons/hicolor"
        logo_output_path="$logo_output_prefix/''${icon_size}x''${icon_size}/apps"
        mkdir -vp "$logo_output_path"
        cp -v "$icon_file" "$logo_output_path/$packageName.png"
      done

      # Helium looks for helium.desktop (see change-chromium-branding.patch)
      install -Dm644 ${helium}/platform/package/helium.desktop \
        $out/share/applications/helium.desktop
    '';

    passthru = {inherit sandboxExecutableName helium;};

    requiredSystemFeatures = ["big-parallel"];

    meta = {
      description = "Private, fast, and honest web browser based on ungoogled-chromium";
      homepage = "https://helium.computer";
      license = with lib.licenses; [gpl3Only bsd3];
      platforms = ["x86_64-linux"];
      mainProgram = "helium";
    };
  })
