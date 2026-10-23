#!/usr/bin/env bash
# Weekly Helium build on Sulu (run from cron, Saturday 00:30).
#
# Builds the `next` branch, smoke-tests it, pushes it to the attic cache and
# garbage-collects the scratch store. The spindle on poacher.dev promotes
# `next` to `main` once the build shows up in the cache, and opens an issue
# pointing at the log here if it doesn't.
#
#   build.sh                 the weekly build (refuses to run on weekday daytime)
#   build.sh --patch-check   only fetch + unpack + patch the source (cheap, any time)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=SCRIPTDIR/env.sh
. "$REPO_DIR/scripts/sulu/env.sh"

mode="build"
[ "${1:-}" = "--patch-check" ] && mode="patch-check"

mkdir -p "$SCRATCH"/{logs,gcroots,tmp}
exec 9> "$SCRATCH/build.lock"
flock -n 9 || die "another build is running"

# Off-peak only: weekends, or weekday nights 22:00-05:30. The build is killed
# at the end of the window, leaving 30 minutes for the push and cleanup.
deadline() {
  local dow hour
  dow="$(TZ=$TZ_LOCAL date +%u)"
  hour="$((10#$(TZ=$TZ_LOCAL date +%H)))"
  if [ "$dow" -ge 6 ] || { [ "$dow" -eq 5 ] && [ "$hour" -ge 22 ]; }; then
    TZ=$TZ_LOCAL date -d 'next monday 05:30' +%s
  elif [ "$hour" -ge 22 ]; then
    TZ=$TZ_LOCAL date -d 'tomorrow 05:30' +%s
  elif [ "$hour" -lt 6 ]; then
    TZ=$TZ_LOCAL date -d 'today 05:30' +%s
  else
    return 1
  fi
}

cleanup_store() {
  log "garbage-collecting the scratch store"
  rm -f "$SCRATCH"/gcroots/result*
  nix store gc
  find "$SCRATCH/logs" -name '*.log' -mtime +28 -delete
  df -h "$SCRATCH" | tail -1
}

rev="$(git ls-remote "$REPO_URL" "refs/heads/$BRANCH" | cut -f1)"
[ -n "$rev" ] || die "branch $BRANCH not found at $REPO_URL"
flake="git+$REPO_URL?ref=$BRANCH&rev=$rev"
logfile="$SCRATCH/logs/$rev.log"
log "$mode of $BRANCH@$rev (log: $logfile)"

if [ "$mode" = "patch-check" ]; then
  nice -n 19 ionice -c3 nix build --no-link --print-build-logs \
    "$flake#helium.patchCheck" > "$logfile" 2>&1 \
    || die "patch check failed, see $logfile"
  log "patches apply cleanly"
  cleanup_store
  exit 0
fi

end="$(deadline)" || die "refusing to build on a weekday during the day"
budget="$(( end - $(date +%s) - 1800 ))"
[ "$budget" -gt 3600 ] || die "less than an hour left in the build window"

out="$(nix eval --raw "$flake#helium.outPath")"
if curl -sfo /dev/null "$CACHE_URL/$(basename "$out" | cut -d- -f1).narinfo"; then
  log "$out is already in $CACHE_URL, nothing to do"
  exit 0
fi

log "building $out (time budget $((budget / 3600))h)"
if ! timeout --kill-after=10m "$budget" \
    nice -n 19 ionice -c3 \
    nix build --print-build-logs --print-out-paths \
      --out-link "$SCRATCH/gcroots/result" "$flake#helium^*" \
    > "$SCRATCH/tmp/outputs" 2> "$logfile"; then
  log "build failed or ran out of time, see $logfile"
  cleanup_store
  exit 1
fi
mapfile -t outputs < "$SCRATCH/tmp/outputs"

log "smoke test"
profile="$(mktemp -d "$SCRATCH/tmp/smoke.XXXXXX")"
if ! timeout 120 nix shell "$out" --command helium \
    --headless=new --no-sandbox --disable-gpu --no-first-run \
    --user-data-dir="$profile" \
    --dump-dom 'data:text/html,<p id="smoke">helium-smoke-ok</p>' \
    2>> "$logfile" | grep -q helium-smoke-ok; then
  rm -rf "$profile"
  log "smoke test failed, not pushing (see $logfile)"
  cleanup_store
  exit 1
fi
rm -rf "$profile"

log "pushing ${outputs[*]} to $CACHE_NAME"
nix run --inputs-from "$flake" nixpkgs#attic-client -- push "$CACHE_NAME" "${outputs[@]}" >> "$logfile" 2>&1 \
  || { log "attic push failed, see $logfile"; cleanup_store; exit 1; }

curl -sfo /dev/null "$CACHE_URL/$(basename "$out" | cut -d- -f1).narinfo" \
  || { log "push finished but $out is not in the cache"; cleanup_store; exit 1; }

log "pushed $out"
cleanup_store
