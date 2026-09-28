#!/usr/bin/env bash
# Fulcio's signer identity is the reusable workflow; bind the caller separately.
# See https://github.com/sigstore/fulcio/blob/main/docs/oid-info.md
set -euo pipefail
: "${RELEASE_TOOLING_REF:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REF:?}" "${GITHUB_SHA:?}"
if [ "${1:-}" = sign ]; then
  cosign sign-blob --yes --bundle dist/SHA256SUMS.sigstore.json dist/SHA256SUMS
fi
cosign verify-blob --bundle dist/SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/metacraft-labs/metacraft-github-actions/.github/workflows/release-tools.yml@$RELEASE_TOOLING_REF" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository "$GITHUB_REPOSITORY" \
  --certificate-github-workflow-ref "$GITHUB_REF" \
  --certificate-github-workflow-sha "$GITHUB_SHA" dist/SHA256SUMS
