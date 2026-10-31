# Prepare selected Repro environments

Run this immediately after the job's input guard and before a long build. It
activates each later project's normal Repro environment, so recipe compiler
provisioning and foreign environment inputs are ready while credentials work.
It reports a bootstrap or activation refusal as infrastructure and preserves
the underlying diagnostic and status. Later builds and artifact checks still
run normally.

```yaml
- uses: metacraft-labs/metacraft-github-actions/prepare-repro-envs@<commit>
  with:
    working-directory: /workspace/product
    nix-shell: .?submodules=1#ci
    projects: |
      /workspace/product
      /workspace/trace-tools
      /workspace/recorder
```

`working-directory` is the later build's directory; `nix-shell` is its exact existing shell that supplies the later build's SDK;
`projects` contains one absolute root per line. Spaces are preserved. The action enters
that shell with a job-lifetime Nix profile and executes `repro exec <root> --`
with a checked command witness for every root. Repro owns its normal input and
tool stores and GC roots. No SDK source file is parsed and no compiler,
provisioning mode, package revision, mirror or retry is selected. The SDK's
normal partial-tool developer-shell diagnostics are preserved; preparation
does not turn optional unavailable platform tools into build gates.

Run `python3 prepare-repro-envs/test.py` for argument/status/witness controls.
Run `python3 prepare-repro-envs/test-real.py --repro /absolute/selected/repro
--report-directory /tmp/preparation-evidence` for real SDK provisioning,
activation, an owned HTTP credential-expiry barrier, late tool execution with
no refetch, and a real fatal C bootstrap refusal. This needs the SDK's normal
compiler prerequisites and runs no product build. Reports retain process
streams and the owned HTTP request/status journal.
`--legacy-workflow <old-launcher-recorder-e2e.yml>` replays the old input guard
and fails at late use after the real HTTP 401; it is an explicit regression
reproduction, not a passing test mode.
