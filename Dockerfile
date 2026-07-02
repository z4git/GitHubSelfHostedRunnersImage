# syntax=docker/dockerfile:1.7

# Multi-stage build for an ephemeral GitHub Actions self-hosted runner.
#
# Security hardening:
#   - ubuntu:24.04 (latest LTS) base
#   - multi-stage build keeps fetch tooling out of the final image
#   - Azure CLI from Microsoft's signed apt repo (signed-by= keyring),
#     not `curl https://aka.ms/... | bash`
#   - non-root user with fixed UID 1001 (`runner`)
#   - --no-install-recommends + apt cache purge everywhere
#   - optional supply-chain verification of the runner tarball via SHA256
#
# Build args:
#   RUNNER_VERSION  Pin a specific runner (e.g. 2.334.0). Empty (default)
#                   resolves the latest release from the GitHub API at build
#                   time.
#   RUNNER_SHA256   Optional sha256 of the runner tarball; when set, the
#                   download is verified before extraction. Recommended when
#                   RUNNER_VERSION is pinned.

ARG UBUNTU_TAG=24.04
ARG RUNNER_VERSION=
ARG RUNNER_SHA256=

# ─────────────────────────────────────────────────────────────
# Stage 1 — fetch and extract the runner tarball
# ─────────────────────────────────────────────────────────────
FROM ubuntu:${UBUNTU_TAG} AS runner-fetch

ARG RUNNER_VERSION
ARG RUNNER_SHA256

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/actions-runner

# Resolve the runner version dynamically when not pinned via --build-arg.
# Note: unauthenticated GitHub API requests are rate-limited to 60/hour per IP.
RUN set -eux; \
    CURL_RETRY="--retry 5 --retry-delay 3 --retry-all-errors"; \
    if [ -z "${RUNNER_VERSION}" ]; then \
        RUNNER_VERSION=$(curl -fsSL ${CURL_RETRY} https://api.github.com/repos/actions/runner/releases/latest \
            | jq -r .tag_name | sed 's/^v//'); \
        echo "Resolved latest actions/runner: ${RUNNER_VERSION}"; \
    fi; \
    [ -n "${RUNNER_VERSION}" ] || { echo "Failed to resolve runner version" >&2; exit 1; }; \
    curl -fsSL ${CURL_RETRY} -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    if [ -n "${RUNNER_SHA256}" ]; then \
        echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c -; \
    fi; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz

# ─────────────────────────────────────────────────────────────
# Stage 2 — runtime image
# ─────────────────────────────────────────────────────────────
FROM ubuntu:${UBUNTU_TAG}

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=0 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0

# Minimal runtime tooling + Azure CLI from Microsoft's signed apt repo.
# gnupg is installed only to dearmor the MS signing key, then purged.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        openssl; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    chmod 0644 /etc/apt/keyrings/microsoft.gpg; \
    . /etc/os-release; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/azure-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends azure-cli; \
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

RUN useradd --create-home --shell /bin/bash --uid 1001 runner

WORKDIR /home/runner/actions-runner

# Copy the pre-extracted runner from the fetch stage. Still root here because
# installdependencies.sh below needs apt; ownership is fixed up afterwards.
COPY --from=runner-fetch /opt/actions-runner/ ./

# The runner's own dependency installer is Ubuntu-version-aware (picks the
# right libicuXX/libsslX for the current distro), so we don't have to hard-
# code package names that drift between Ubuntu LTS releases.
RUN set -eux; \
    ./bin/installdependencies.sh; \
    # Expose the runner's bundled Node 20 on PATH. The real Runner.Listener
    # invokes Node by absolute path so this is inert in production, but it
    # lets local tooling (e.g. `act`) and any JS-action that shells out find
    # `node`, `npm`, `npx` without bundling a second Node into the image.
    for bin in node npm npx; do \
        ln -s /home/runner/actions-runner/externals/node20/bin/$bin /usr/local/bin/$bin; \
    done; \
    chown -R runner:runner /home/runner; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --chown=runner:runner start.sh ./
RUN chmod 0755 start.sh

# The runner is designed to be ephemeral, so it doesn't need to run as root.
USER runner

ENTRYPOINT ["./start.sh"]
