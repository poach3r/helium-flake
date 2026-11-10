#!/usr/bin/env bash
# Spindle job: fast-forward main to next once Sulu's build of it is cached,
# open an issue if Sulu reports a failure or it's still missing after the
# build window
set -euo pipefail

CACHE_URL="https://cache.poacher.dev/helium"
SULU_LOGS="/scratch/HMatonis068/logs"
BUILD_PREFIX="Sulu build of next failed"
TOKEN_PREFIX="Rotate the Sulu attic push token"

issues() { python3 scripts/ci/tangled_issues.py "$@"; }

expiry="$(tr -d '[:space:]' < ci/attic-token-expiry)"
days_left="$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))"
token_title="$TOKEN_PREFIX (expires $expiry)"
if [ "$days_left" -le 14 ]; then
  issues open --title "$token_title" --body "The push-only attic token on Sulu expires on $expiry ($days_left days).

1. On the server: \`atticd-atticadm make-token --sub sulu-helium --validity '180 days' --push helium --pull helium\`
2. On Sulu: \`~/helium-flake/scripts/sulu/setup.sh attic-login\`
3. Update \`ci/attic-token-expiry\` to the new date."
else
  issues close --title-prefix "$TOKEN_PREFIX"
fi

git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
main="$(git rev-parse origin/main)"
next="$(git rev-parse -q --verify origin/next || true)"

if [ -z "$next" ]; then
  echo "no next branch, nothing to promote"
  exit 0
fi
# next == main happens when bump.sh hands an unbuilt main to Sulu; there is
# nothing to promote, but the build is still watched below.
if [ "$next" != "$main" ]; then
  git merge-base --is-ancestor "$main" "$next" || {
    issues open --title "next@${next:0:7} is not a fast-forward of main" \
      --body "Promotion skipped: \`next\` ($next) does not contain \`main\` ($main)."
    exit 1
  }
fi

git checkout -q "$next"
out="$(nix eval --raw .#helium.outPath)"
version="$(nix eval --raw .#helium.version)"
narinfo="$CACHE_URL/$(basename "$out" | cut -d- -f1).narinfo"

if curl -sfo /dev/null "$narinfo"; then
  if [ "$next" != "$main" ]; then
    echo "$out is cached, promoting next@$next to main"
    . scripts/ci/git-setup.sh
    # No skip-ci: the push to main triggers the GitHub mirror.
    git push "$PUSH_URL" "$next:refs/heads/main"
  else
    echo "$out is cached, main is up to date"
  fi
  issues close --title-prefix "$BUILD_PREFIX"
  scripts/ci/release.sh "$next" "$out"
  exit 0
fi

echo "$out is not cached yet"
# Sulu pushes this when its build fails
marker="$(nix eval --raw --file ci/failure-marker.nix --apply "f: f {rev = \"$next\";}")"
if curl -sfo /dev/null "$CACHE_URL/$(basename "$marker" | cut -d- -f1).narinfo"; then
  reason="Sulu's weekend build failed."
elif [ "$(TZ=America/New_York date +%u)" -eq 1 ] && [ "$((10#$(TZ=America/New_York date +%H%M)))" -ge 600 ]; then
  reason="Sulu's weekend build did not reach the cache."
else
  exit 0
fi
issues open --title "$BUILD_PREFIX: Helium $version" --body "$reason

- next: \`$next\`
- Helium: $version
- expected: \`$out\`
- log on Sulu: \`$SULU_LOGS/$next.log\` (and \`$SULU_LOGS/cron.log\`)

\`next\` stays unpromoted; Friday's bump will retry. This issue closes automatically once a build is promoted."
