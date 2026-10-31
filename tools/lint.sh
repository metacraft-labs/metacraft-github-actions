#!/usr/bin/env bash
# Run the existing six workflow shellcheck inventories and real workflow lint.
set -eu
# Real-engine integration is explicit: CI's no-argument lint has no Repro
# dependency, and this script must not guess one from the ambient PATH.
repro=
if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--repro" ]; then
    echo "usage: tools/lint.sh [--repro /absolute/measured/repro]" >&2
    exit 2
  fi
  case "$2" in
    /*) ;;
    *) echo "--repro requires an absolute measured executable path" >&2; exit 2 ;;
  esac
  if [ ! -f "$2" ] || [ ! -x "$2" ]; then
    echo "--repro requires an existing executable" >&2
    exit 2
  fi
  repro=$2
fi
shellcheck -S warning clone-siblings/resolve-sibling-rev.sh clone-siblings/resolve-sibling-rev-test.sh clone-siblings/clone-siblings.sh clone-siblings/clone-siblings-step-test.sh setup-dev-env/decide-sibling-strategy.sh setup-dev-env/provision-siblings-from-lock.sh setup-dev-env/reconcile-locked-sibling.sh setup-dev-env/sibling-strategy-step-test.sh setup-dev-env/decide-store-root.sh setup-dev-env/store-root-step-test.sh setup-dev-env/ensure-host-decompressors.sh setup-dev-env/ensure-host-decompressors-step-test.sh .github/assert-no-persisted-credential.sh
shellcheck -S warning publish-workspace-lock/anchor-workspace-lock.sh publish-workspace-lock/publish-workspace-lock.sh publish-workspace-lock/anchor-workspace-lock-test.sh publish-workspace-lock/publish-workspace-lock-step-test.sh
shellcheck -S warning refresh-workspace-lock/refresh-workspace-lock.sh refresh-workspace-lock/refresh-workspace-lock-test.sh
shellcheck -S warning setup-nix/configure-git-auth.sh setup-nix/configure-git-auth-test.sh setup-nix/write-nix-netrc.sh setup-nix/nix-netrc-test.sh
shellcheck -S warning git-auth/scoped-git-auth.sh git-auth/authenticated-clone.sh git-auth/authenticated-clone-test.sh git-auth/longpaths-test.sh reprobuild-provision/provision-reprobuild-siblings.sh
shellcheck -S warning .github/assert-composite-run-size.sh .github/assert-no-url-embedded-credential.sh .github/assert-action-archive-size.sh .github/assert-action-archive-size-test.sh .github/assert-no-expression-in-manifest-prose.sh .github/assert-no-expression-in-manifest-prose-test.sh .github/assert-workflow-triggers-mainline.sh .github/assert-workflow-triggers-mainline-test.sh .github/assert-workflow-triggers-discovery-test.sh
shellcheck -S warning tools/lint.sh .envrc
shellcheck -S warning setup-dev-env/record-windows-sdk.sh
python3 - <<'PYTHON'
import pathlib, subprocess
files = set(subprocess.check_output(["git", "ls-files", "--", "*.py"], text=True).splitlines())
files.add("tools/install-canonical-hooks.py")
for name in sorted(files):
  path = pathlib.Path(name)
  compile(path.read_bytes(), name, "exec")
PYTHON
actionlint
python3 git-auth/test-private-global-config.py
python3 git-auth/test-cargo-acquisition.py
python3 setup-dev-env/test-locked-sibling-reconciliation.py
python3 setup-dev-env/test-windows-sdk-receipt.py
python3 setup-dev-env/test-frozen-sibling-source.py
python3 refresh-build-auth/test.py
node --check refresh-build-auth/nix-auth.cjs
node --check assert-workflow-triggers/index.cjs
node --check .github/enumerate-workflows.cjs
node --check .github/read-workflow.cjs
node --check .github/assert-workflow-triggers-action-test.cjs
node --test .github/assert-workflow-triggers-action-test.cjs

if [ -n "$repro" ]; then
  cwd_report="$(mktemp -d "${TMPDIR:-/tmp}/repro-wrapper-cwd.XXXXXX")"
  python3 setup-dev-env/test-repro-wrapper-cwd.py --repro "$repro" --report "$cwd_report/result.json"
  python3 tools/test-install-canonical-hooks.py --repro "$repro"
  python3 git-auth/test-private-global-config.py --repro "$repro"
  python3 git-auth/test-cargo-acquisition.py --repro "$repro"
fi
