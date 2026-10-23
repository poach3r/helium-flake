#!/usr/bin/env bash
# Spindle job: bump Helium (+ nixpkgs) on top of main and force-push to `next`
# for Sulu to build. Re-running while `next` holds an unbuilt bump simply
# replaces it, so a failed week is retried automatically.
set -euo pipefail

CACHE_URL="https://cache.poacher.dev/helium"

rc=0
summary_file="$(mktemp)"
python3 scripts/update.py > "$summary_file" || rc=$?
if [ "$rc" -eq 3 ]; then
  # No new Helium, but main itself may still be unbuilt (first run, or a
  # packaging change without a version bump): hand main to Sulu as is.
  out="$(nix eval --raw .#helium.outPath)"
  if curl -sfo /dev/null "$CACHE_URL/$(basename "$out" | cut -d- -f1).narinfo"; then
    echo "nothing to bump"
    exit 0
  fi
  echo "$out is not in $CACHE_URL; pointing next at main"
  . scripts/ci/git-setup.sh
  git push -o skip-ci --force "$PUSH_URL" HEAD:refs/heads/next
  exit 0
fi
[ "$rc" -eq 0 ] || exit "$rc"
summary="$(cat "$summary_file")"

# Make sure the result evaluates before handing it to Sulu.
nix eval --raw .#helium.drvPath
echo

. scripts/ci/git-setup.sh
git add flake.lock pkgs/helium/info.json
git commit -S -m "chore(helium): update to $summary"
git push -o skip-ci --force "$PUSH_URL" HEAD:refs/heads/next
