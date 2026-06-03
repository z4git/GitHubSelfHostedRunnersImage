#!/bin/bash
set -e

# ────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────
# These values are passed as environment variables
# GITHUB_PAT    → Your GitHub Personal Access Token
# GITHUB_OWNER  → Your GitHub org or username
# GITHUB_REPO   → (Optional) Repository name for repo-level runners
# RUNNER_SCOPE  → "org" or "repo"
# RUNNER_LABELS → Comma-separated labels (e.g., "container-app,linux")
# RUNNER_GROUP  → Runner group name (org-level only, default: "Default")
#                  Set this to the runner group you created in Step 1 (e.g., "container-app-runners")
#                  If not set, runners register in GitHub's "Default" group — which means
#                  ANY repo in the org can use them and you lose access control.

RUNNER_SCOPE="${RUNNER_SCOPE:-org}"
RUNNER_LABELS="${RUNNER_LABELS:-container-app}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"

# ⚠️ IMPORTANT: Always set the RUNNER_GROUP environment variable on your Container App Job
#    to match the runner group you created on GitHub (e.g., "container-app-runners").
#    The "Default" fallback above is only a safety net — do NOT rely on it.

# ────────────────────────────────────────────
# GET REGISTRATION TOKEN
# ────────────────────────────────────────────
if [ "$RUNNER_SCOPE" == "org" ]; then
    echo "🔑 Requesting registration token for organization: $GITHUB_OWNER"
    REG_TOKEN=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token" \
        | jq -r .token)
    RUNNER_URL="https://github.com/${GITHUB_OWNER}"
else
    echo "🔑 Requesting registration token for repository: $GITHUB_OWNER/$GITHUB_REPO"
    REG_TOKEN=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token" \
        | jq -r .token)
    RUNNER_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
fi

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" == "null" ]; then
    echo "❌ Failed to get registration token. Check your GITHUB_PAT and permissions."
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