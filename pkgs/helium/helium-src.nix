# Stand-in for nixpkgs' chromium/ungoogled.nix: common.nix calls it with the
# helium-chromium rev/hash from info.json (deps.ungoogled-patches) and runs
# utils/prune_binaries.py, utils/patches.py and utils/domain_substitution.py
# from the result, so the first two are wrapped to match helium-linux's
# apply_patches(). helium-linux is placed at $out/platform.
{
  lib,
  stdenv,
  fetchFromGitHub,
  python3,
  patch,
  heliumInfo,
}: {
  rev,
  hash,
}: let
  linux = fetchFromGitHub {
    owner = "imputnet";
    repo = "helium-linux";
    inherit (heliumInfo.linux) rev hash;
  };
in
  stdenv.mkDerivation {
    pname = "helium-src";
    inherit (heliumInfo) version;

    src = fetchFromGitHub {
      owner = "imputnet";
      repo = "helium";
      inherit rev hash;
    };

    nativeBuildInputs = [
      (python3.withPackages (ps: [ps.pillow]))
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      python3 utils/generate_resources.py resources/generate_resources.txt resources
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      cp -R . $out
      cp -R ${linux} $out/platform
      chmod -R u+w $out

      # common.nix runs `utils/patches.py . <patches>`; mirror helium-linux's
      # apply_patches(), which applies the core and the Linux patch trees.
      mv $out/utils/patches.py $out/utils/patches_real.py
      cat > $out/utils/patches.py <<EOF
      #!${stdenv.shell}
      export PATH="${lib.makeBinPath [patch]}:\$PATH"
      exec ${python3.interpreter} $out/utils/patches_real.py apply "\$@" $out/platform/patches
      EOF
      # helium-linux prunes with --keep-build-dependencies; without it the
      # whole of third_party/typescript/ goes, including the patch that
      # common.nix applies to nixpkgs' typescript.
      mv $out/utils/prune_binaries.py $out/utils/prune_binaries_real.py
      cat > $out/utils/prune_binaries.py <<EOF
      #!${stdenv.shell}
      exec ${python3.interpreter} $out/utils/prune_binaries_real.py --keep-build-dependencies "\$@"
      EOF
      chmod +x $out/utils/*.py

      patchShebangs --build $out/utils

      runHook postInstall
    '';
  }
