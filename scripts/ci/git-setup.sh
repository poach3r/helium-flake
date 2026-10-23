# shellcheck shell=bash
# Sourced by the spindle jobs: SSH + git identity for the bot account.
# Sets PUSH_URL. Same knot/port convention as nixos-config's update.yml.

mkdir -p ~/.ssh
chmod 700 ~/.ssh
printf '%s\n' "$BOT_SSH_KEY" > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519

KNOT="${TANGLED_REPO_KNOT:-tngl.poacher.dev}"
KNOT_SSH_PORT=2222
ssh-keyscan -p "$KNOT_SSH_PORT" -H "$KNOT" >> ~/.ssh/known_hosts 2>/dev/null

PUSH_URL="$(printf '%s' "$TANGLED_REPO_URL" | sed -E "s#^https?://([^/]+)#ssh://git@\1:$KNOT_SSH_PORT#")"
export PUSH_URL

git config user.name "$BOT_HANDLE"
git config user.email "$BOT_EMAIL"
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519
