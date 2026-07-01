#!/bin/bash
set -euo pipefail

# ────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────
# Required environment variables (injected by the Container App Job):
#   GITHUB_APP_ID              → GitHub App ID (numeric string)
#   GITHUB_APP_INSTALLATION_ID → Installation ID for the org/repo
#   GITHUB_APP_PRIVATE_KEY     → App private key (PEM, from Key Vault secret)
#   GITHUB_OWNER               → GitHub org or user that owns the runners
#   GITHUB_REPO                → (repo scope only) repository name
#   RUNNER_SCOPE               → "org" or "repo"
#   RUNNER_LABELS              → Comma-separated labels
#   RUNNER_GROUP               → Runner group name (org scope only)

RUNNER_SCOPE="${RUNNER_SCOPE:-org}"
RUNNER_LABELS="${RUNNER_LABELS:-container-app}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"

: "${GITHUB_APP_ID:?GITHUB_APP_ID is required}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
: "${GITHUB_APP_PRIVATE_KEY:?GITHUB_APP_PRIVATE_KEY is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"

# ────────────────────────────────────────────
# MINT A JWT FROM THE APP PRIVATE KEY
# ────────────────────────────────────────────
# GitHub App JWTs are RS256-signed with the App's private key. Max lifetime
# 10 min; we use 9 to leave slack for clock skew. iat backdated 60s for the
# same reason.
b64url() {
    openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))

header='{"alg":"RS256","typ":"JWT"}'
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GITHUB_APP_ID")

header_b64=$(printf '%s' "$header" | b64url)
payload_b64=$(printf '%s' "$payload" | b64url)
unsigned="${header_b64}.${payload_b64}"

signature=$(printf '%s' "$unsigned" \
    | openssl dgst -sha256 -sign <(printf '%s' "$GITHUB_APP_PRIVATE_KEY") -binary \
    | b64url)

jwt="${unsigned}.${signature}"

# ────────────────────────────────────────────
# EXCHANGE JWT FOR INSTALLATION ACCESS TOKEN
# ────────────────────────────────────────────
echo "🔐 Exchanging App JWT for installation token (installation $GITHUB_APP_INSTALLATION_ID)"
INSTALLATION_TOKEN=$(curl -sS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" \
    | jq -r .token)

if [ -z "$INSTALLATION_TOKEN" ] || [ "$INSTALLATION_TOKEN" = "null" ]; then
    echo "❌ Failed to obtain installation access token. Check GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and the private key."
    exit 1
fi

# ────────────────────────────────────────────
# GET REGISTRATION TOKEN
# ────────────────────────────────────────────
if [ "$RUNNER_SCOPE" = "org" ]; then
    echo "🔑 Requesting registration token for organization: $GITHUB_OWNER"
    REG_TOKEN=$(curl -sS -X POST \
        -H "Authorization: token $INSTALLATION_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token" \
        | jq -r .token)
    RUNNER_URL="https://github.com/${GITHUB_OWNER}"
else
    echo "🔑 Requesting registration token for repository: $GITHUB_OWNER/$GITHUB_REPO"
    REG_TOKEN=$(curl -sS -X POST \
        -H "Authorization: token $INSTALLATION_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token" \
        | jq -r .token)
    RUNNER_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
fi

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    echo "❌ Failed to get registration token. Check the App is installed on this org/repo with 'Self-hosted runners: Read & write' permission."
    exit 1
fi

echo "✅ Registration token obtained successfully"

# ────────────────────────────────────────────
# CONFIGURE RUNNER
# ────────────────────────────────────────────
echo "⚙️ Configuring runner..."
./config.sh --unattended \
    --name "runner-$(hostname)" \
    --url "$RUNNER_URL" \
    --token "$REG_TOKEN" \
    --runnergroup "$RUNNER_GROUP" \
    --ephemeral \
    --labels "$RUNNER_LABELS" \
    --replace

echo "🚀 Starting runner..."
./run.sh
