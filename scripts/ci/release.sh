#!/usr/bin/env bash
# Called by promote.sh once a build of main is in the cache: tag it with its
# Helium version and publish the release on Tangled (a signed annotated tag)
# and GitHub (the tag plus a release). Every step skips what already exists,
# so a run that failed halfway is finished by the next promote.
#
#   release.sh <sha> <out-path>
set -euo pipefail

GITHUB_REPO="poach3r/helium-flake"
GITHUB_API="https://api.github.com/repos/$GITHUB_REPO"
CACHE_URL="https://cache.poacher.dev/helium"

sha="$1"
out="$2"

read -r version chromium nixpkgs < <(python3 - \
  "$(git show "$sha:pkgs/helium/info.json")" "$(git show "$sha:flake.lock")" <<'EOF'
import json, sys
info, lock = (json.loads(arg) for arg in sys.argv[1:])
print(info["helium"]["version"], info["version"], lock["nodes"]["nixpkgs"]["locked"]["rev"])
EOF
)
tag="$version"

git fetch -q origin '+refs/tags/*:refs/tags/*'
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
  tagged="$(git rev-parse "refs/tags/$tag^{commit}")"
  if [ "$tagged" != "$sha" ]; then
    # A packaging-only change on top of an already released Helium version.
    echo "tag $tag already exists at ${tagged:0:7}, not releasing ${sha:0:7}"
    exit 0
  fi
  echo "tag $tag already on the knot"
else
  notes="$(mktemp)"
  cat > "$notes" <<EOF
Helium $version (Chromium $chromium)

Upstream release: https://github.com/imputnet/helium-linux/releases/tag/$version
nixpkgs: https://github.com/NixOS/nixpkgs/commit/$nixpkgs
Cached at $CACHE_URL:
  $out
EOF
  . scripts/ci/git-setup.sh
  git tag -s "$tag" "$sha" -F "$notes"
  git push -o skip-ci "$PUSH_URL" "refs/tags/$tag"
  echo "tagged $tag at ${sha:0:7}"
fi

git push -q "https://x-access-token:${GITHUB_TOKEN}@github.com/$GITHUB_REPO.git" "refs/tags/$tag"

gh_api() {
  curl -sSf -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "$@"
}

if gh_api -o /dev/null "$GITHUB_API/releases/tags/$tag" 2> /dev/null; then
  echo "GitHub release $tag already exists"
  exit 0
fi

# Reuse the tag message (minus its signature) as the release notes.
git tag -l --format='%(contents:subject)%0a%0a%(contents:body)' "$tag" \
  | python3 -c 'import json, sys; print(json.dumps({
      "tag_name": sys.argv[1], "name": sys.argv[2],
      "body": sys.stdin.read().strip(), "make_latest": "true"}))' \
    "$tag" "Helium $version" \
  | gh_api -o /dev/null -X POST "$GITHUB_API/releases" -d @-
echo "created GitHub release $tag"
