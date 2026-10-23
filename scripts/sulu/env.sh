# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts sourcing this
# Shared environment for the Sulu scripts. Everything heavy lives on
# /scratch (local disk); the NFS home only holds ~/bin/nix and this repo.

SCRATCH="${SCRATCH:-/scratch/HMatonis068}"
TZ_LOCAL="America/New_York"

REPO_URL="https://tangled.org/poacher.dev/helium-flake"
BRANCH="${BRANCH:-next}"
CACHE_NAME="helium"
CACHE_URL="https://cache.poacher.dev/${CACHE_NAME}"

export PATH="$HOME/bin:/usr/local/bin:/usr/bin:/bin"
export NIX_USER_CONF_FILES="$SCRATCH/nix.conf"
export XDG_CACHE_HOME="$SCRATCH/.cache"
export XDG_CONFIG_HOME="$SCRATCH/.config"
export TMPDIR="$SCRATCH/tmp"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "error: $*" >&2
  exit 1
}
