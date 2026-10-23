#!/usr/bin/env python3
"""Bump Helium and nixpkgs together.

nixpkgs' chromium expressions (common.nix) only support the Chromium version
that nixpkgs revision packages, so we only ever pick a Helium release whose
Chromium version *exactly* matches the locked nixos-unstable `chromium`.
That also lets us reuse nixpkgs' verified DEPS lock instead of prefetching.

Steps:
  1. `nix flake update nixpkgs` (reverted if nothing ends up changing)
  2. find the newest stable helium-linux release built on that Chromium
  3. write pkgs/helium/info.json

Exit status: 0 = updated, 3 = nothing to do, other = error.
Requires: nix, network access. Optional: GITHUB_TOKEN for API rate limits.
"""

import argparse
import configparser
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INFO = ROOT / "pkgs" / "helium" / "info.json"
LOCK = ROOT / "flake.lock"
CHROMIUM_DIR = "pkgs/applications/networking/browsers/chromium"

LINUX_REPO = "imputnet/helium-linux"
CORE_REPO = "imputnet/helium"

# Helium GN args that conflict with the nixpkgs toolchain setup in common.nix.
# Everything else from flags.gn + flags.linux.gn is passed through.
GN_DENYLIST = {
    "is_clang",
    "use_sysroot",
    "use_siso",
    "symbol_level",
    "blink_symbol_level",
    "use_system_libffi",
    "chrome_pgo_phase",
    "clang_use_chrome_plugins",
}

NOTHING_TO_DO = 3


def log(msg):
    print(f"[update] {msg}", file=sys.stderr)


def http_get(url):
    headers = {"User-Agent": "helium-flake-updater"}
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as resp:
        return resp.read().decode()


def gh_api(path):
    return json.loads(http_get(f"https://api.github.com/{path}"))


def raw(repo, rev, path):
    return http_get(f"https://raw.githubusercontent.com/{repo}/{rev}/{path}")


def nix(*args):
    return subprocess.run(
        ["nix", "--extra-experimental-features", "nix-command flakes", *args],
        check=True,
        capture_output=True,
        text=True,
        cwd=ROOT,
    ).stdout


def nixpkgs_chromium_info():
    path = nix(
        "eval",
        "--raw",
        "--impure",
        "--expr",
        f'(builtins.getFlake "path:{ROOT}").inputs.nixpkgs.outPath',
    )
    return json.loads((Path(path) / CHROMIUM_DIR / "info.json").read_text())


def prefetch_github(repo, rev):
    out = json.loads(nix("flake", "prefetch", "--json", f"github:{repo}/{rev}"))
    return out["hash"]


def stable_releases(limit):
    releases = gh_api(f"repos/{LINUX_REPO}/releases?per_page={limit}")
    return [r["tag_name"] for r in releases if not r["draft"] and not r["prerelease"]]


def resolve_release(tag):
    linux_rev = gh_api(f"repos/{LINUX_REPO}/commits/{tag}")["sha"]
    core_rev = gh_api(f"repos/{LINUX_REPO}/contents/helium-chromium?ref={linux_rev}")["sha"]
    chromium = raw(CORE_REPO, core_rev, "chromium_version.txt").strip()
    return {"tag": tag, "linuxRev": linux_rev, "coreRev": core_rev, "chromium": chromium}


def parse_gn_args(text):
    args = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if value in ("true", "false"):
            args[key] = value == "true"
        else:
            # ints, "strings" and [lists] are all valid JSON
            args[key] = json.loads(value)
    return args


def parse_deps_ini(text):
    """Extra downloads Helium unpacks into the tree (deps.ini)."""
    ini = configparser.ConfigParser()
    ini.read_string(text)
    deps = {}
    for name in ini.sections():
        sec = ini[name]
        deps[name] = {
            "url": sec["url"],
            "sha256": sec["sha256"],
            "outputPath": sec["output_path"].removeprefix("./"),
            "stripLeadingDirs": sec.get("strip_leading_dirs"),
        }
    return deps


def build_info(release, chromium_entry):
    core, linux = release["coreRev"], release["linuxRev"]
    gn_args = parse_gn_args(raw(CORE_REPO, core, "flags.gn"))
    gn_args.update(parse_gn_args(raw(LINUX_REPO, linux, "flags.linux.gn")))
    for key in GN_DENYLIST:
        gn_args.pop(key, None)

    deps = dict(chromium_entry["deps"])
    deps["ungoogled-patches"] = {"rev": core, "hash": prefetch_github(CORE_REPO, core)}

    return {
        "version": chromium_entry["version"],
        "DEPS": chromium_entry["DEPS"],
        "deps": deps,
        "helium": {
            "version": release["tag"],
            "linux": {"rev": linux, "hash": prefetch_github(LINUX_REPO, linux)},
            "gnFlags": dict(sorted(gn_args.items())),
            "extraDeps": parse_deps_ini(raw(CORE_REPO, core, "deps.ini")),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-nixpkgs-update", action="store_true",
                        help="keep the currently locked nixpkgs")
    parser.add_argument("--release", help="force a specific helium-linux tag")
    parser.add_argument("--scan", type=int, default=15,
                        help="how many recent releases to consider")
    args = parser.parse_args()

    current = json.loads(INFO.read_text()) if INFO.exists() else None
    lock_backup = LOCK.read_bytes() if LOCK.exists() else None

    def revert_lock():
        if lock_backup is not None:
            LOCK.write_bytes(lock_backup)

    if not args.no_nixpkgs_update:
        log("updating nixpkgs input")
        nix("flake", "update", "nixpkgs")

    nixpkgs_info = nixpkgs_chromium_info()
    # Same Chromium source either way; prefer the ungoogled entry when it
    # matches since its deps were validated against an ungoogled build.
    candidates = {e["version"]: e for e in (nixpkgs_info["chromium"],
                                           nixpkgs_info["ungoogled-chromium"])}
    log(f"nixpkgs chromium versions: {', '.join(candidates)}")

    tags = [args.release] if args.release else stable_releases(args.scan)
    release = None
    for tag in tags:
        info = resolve_release(tag)
        log(f"helium {tag} -> chromium {info['chromium']}")
        if info["chromium"] in candidates:
            release = info
            break

    if release is None:
        log("no stable Helium release matches nixpkgs' chromium; keeping current lock")
        revert_lock()
        return NOTHING_TO_DO

    if current and current["helium"]["version"] == release["tag"] \
            and current["helium"]["linux"]["rev"] == release["linuxRev"]:
        log(f"already at helium {release['tag']}; not bumping nixpkgs on its own")
        revert_lock()
        return NOTHING_TO_DO

    new = build_info(release, candidates[release["chromium"]])
    INFO.write_text(json.dumps(new, indent=2) + "\n")
    log(f"updated to helium {release['tag']} (chromium {new['version']})")
    print(f"helium {release['tag']} (chromium {new['version']})")
    return 0


if __name__ == "__main__":
    if not shutil.which("nix"):
        sys.exit("nix not found in PATH")
    sys.exit(main())
