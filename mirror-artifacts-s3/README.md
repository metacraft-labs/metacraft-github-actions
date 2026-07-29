# `mirror-artifacts-s3`

Non-blocking mirror of a CI artifact directory to the Metacraft **in-house S3
artifact store** (Garage on `high-mem-server`, reached over the NetBird VPN).
It moves the bulk of artifact bytes off GitHub's org-wide, quota-limited Actions
artifact storage — whose exhaustion (`Artifact storage quota has been hit`) fails
CI across *unrelated* repos.

Use it **alongside** `actions/upload-artifact` (keep that at `retention-days: 1`
for the immediate-run convenience copy); this action is the durable copy. See
[metacraft-dev-guidelines → CI Workflow Standards § In-house artifact store](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/ci-workflow-standards.md).

## Requirements

- The runner must be **self-hosted and NetBird-connected** (the store is not
  publicly routable). This is already required of Metacraft CI.
- The repo must be onboarded: registered in
  `infra/scripts/s3-artifact-store/repos.toml` and provisioned via
  `just configure-s3-artifact-store-github-repo <owner/name>` (sets the
  `MCL_S3_ARTIFACTS_*` variables/secrets). Until then this action **skips
  cleanly** — it never fails.

## Usage

```yaml
- name: Upload logs
  if: always()
  continue-on-error: true
  uses: actions/upload-artifact@v4
  with:
    name: test-logs-${{ matrix.runner }}
    path: test-logs/
    retention-days: 1          # short — the S3 mirror is the durable copy

- name: Mirror logs to S3 (non-blocking)
  if: always()
  continue-on-error: true
  uses: metacraft-labs/metacraft-github-actions/mirror-artifacts-s3@main
  with:
    path: test-logs/
    prefix: test-logs-${{ matrix.runner }}/${{ github.run_id }}
    endpoint: ${{ vars.MCL_S3_ARTIFACTS_ENDPOINT }}
    bucket: ${{ vars.MCL_S3_ARTIFACTS_BUCKET }}
    region: ${{ vars.MCL_S3_ARTIFACTS_REGION }}
    access-key-id: ${{ secrets.MCL_S3_ARTIFACTS_ACCESS_KEY_ID }}
    secret-access-key: ${{ secrets.MCL_S3_ARTIFACTS_SECRET_ACCESS_KEY }}
```

## Safety

The action never exits non-zero, and skips (with a `::warning`) when: the
credential is absent (un-onboarded repo), the path is missing, or no S3 client
(`aws` on `PATH`, or `nix` to borrow `awscli2`) is available on the runner —
e.g. a Windows runner without a usable shell/toolchain. Always pair the `uses:`
step with `if: always()` + `continue-on-error: true` so it runs on failed jobs
and can never gate the build.
