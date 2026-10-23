#!/usr/bin/env bash
# Manually dispatch a spindle workflow.
#
#   scripts/ci/trigger.sh bump|promote [sha]
#
# Prompts for an app password (not echoed). Env overrides: HANDLE, REPO_DID,
# SPINDLE, REPO_URL.
set -euo pipefail

if ! command -v jq > /dev/null || ! command -v curl > /dev/null; then
  exec nix shell nixpkgs#jq nixpkgs#curl --command "$0" "$@"
fi

die() {
  echo "error: $*" >&2
  exit 1
}

[ $# -ge 1 ] || die "usage: $0 <workflow> [sha]"
workflow="$1"
# The spindle names workflows by their file name under .tangled/workflows/.
case "$workflow" in
  *.yml | *.yaml) ;;
  *) workflow="$workflow.yml" ;;
esac

HANDLE="${HANDLE:-poacher.dev}"
SPINDLE="${SPINDLE:-ci.poacher.dev}"
REPO_URL="${REPO_URL:-https://tangled.org/poacher.dev/helium-flake}"

# Workflows are read from this commit; promote.sh expects to run on main.
sha="${2:-$(git ls-remote "$REPO_URL" refs/heads/main | cut -f1)}"
[ "${#sha}" -eq 40 ] || die "need a full 40-character commit sha, got '$sha'"

if [ -z "${REPO_DID:-}" ]; then
  # The knot remote looks like git@tngl.poacher.dev:did:plc:...
  REPO_DID="$(git -C "$(dirname "$0")" remote get-url origin 2> /dev/null | grep -o 'did:[a-z]*:[a-zA-Z0-9._:-]*' || true)"
  [ -n "$REPO_DID" ] || die "set REPO_DID (the did:plc:... in the repo's knot URL)"
fi

did="$(curl -sf "https://$HANDLE/.well-known/atproto-did" || true)"
if [ -z "$did" ]; then
  did="$(curl -sfG https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle \
    --data-urlencode "handle=$HANDLE" | jq -r .did)"
fi
pds="$(curl -sf "https://plc.directory/$did" \
  | jq -r '.service[] | select(.id == "#atproto_pds") | .serviceEndpoint')"
[ -n "$pds" ] || die "could not find the PDS for $HANDLE ($did)"

read -rsp "app password for $HANDLE: " password
echo

jwt="$(jq -n --arg id "$HANDLE" --arg pw "$password" '{identifier: $id, password: $pw}' \
  | curl -sf -X POST "$pds/xrpc/com.atproto.server.createSession" \
    -H 'Content-Type: application/json' -d @- | jq -r .accessJwt)" \
  || die "login failed"
unset password

token="$(curl -sfG "$pds/xrpc/com.atproto.server.getServiceAuth" \
  -H "Authorization: Bearer $jwt" \
  --data-urlencode "aud=did:web:$SPINDLE" \
  --data-urlencode "lxm=sh.tangled.ci.triggerPipeline" | jq -r .token)" \
  || die "could not get a service auth token"

echo "dispatching $workflow at $sha on $SPINDLE"
jq -n --arg repo "$REPO_DID" --arg sha "$sha" --arg wf "$workflow" '{
    repo: $repo,
    trigger: {"$type": "sh.tangled.ci.trigger#manual", sha: $sha, ref: "refs/heads/main"},
    workflows: [$wf]
  }' \
  | curl -sS -X POST "https://$SPINDLE/xrpc/sh.tangled.ci.triggerPipeline" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d @- \
  | jq .
