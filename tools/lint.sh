#!/usr/bin/env bash
# Run the existing six workflow shellcheck inventories and real workflow lint.
set -eu
shellcheck -S warning clone-siblings/resolve-sibling-rev.sh clone-siblings/resolve-sibling-rev-test.sh clone-siblings/clone-siblings.sh clone-siblings/clone-siblings-step-test.sh setup-dev-env/decide-sibling-strategy.sh setup-dev-env/provision-siblings-from-lock.sh setup-dev-env/sibling-strategy-step-test.sh setup-dev-env/decide-store-root.sh setup-dev-env/store-root-step-test.sh setup-dev-env/ensure-host-decompressors.sh setup-dev-env/ensure-host-decompressors-step-test.sh .github/assert-no-persisted-credential.sh
shellcheck -S warning publish-workspace-lock/anchor-workspace-lock.sh publish-workspace-lock/publish-workspace-lock.sh publish-workspace-lock/anchor-workspace-lock-test.sh publish-workspace-lock/publish-workspace-lock-step-test.sh
shellcheck -S warning refresh-workspace-lock/refresh-workspace-lock.sh refresh-workspace-lock/refresh-workspace-lock-test.sh
shellcheck -S warning setup-nix/configure-git-auth.sh setup-nix/configure-git-auth-test.sh setup-nix/write-nix-netrc.sh setup-nix/nix-netrc-test.sh
shellcheck -S warning git-auth/scoped-git-auth.sh git-auth/authenticated-clone.sh git-auth/authenticated-clone-test.sh git-auth/longpaths-test.sh reprobuild-provision/provision-reprobuild-siblings.sh
shellcheck -S warning .github/assert-composite-run-size.sh .github/assert-no-url-embedded-credential.sh .github/assert-action-archive-size.sh .github/assert-action-archive-size-test.sh .github/assert-no-expression-in-manifest-prose.sh .github/assert-no-expression-in-manifest-prose-test.sh .github/assert-workflow-triggers-mainline.sh .github/assert-workflow-triggers-mainline-test.sh
shellcheck -S warning tools/lint.sh .envrc
python3 - <<'PYTHON'
import pathlib, subprocess
files = set(subprocess.check_output(["git", "ls-files", "--", "*.py"], text=True).splitlines())
files.add("tools/install-canonical-hooks.py")
for name in sorted(files):
  path = pathlib.Path(name)
  compile(path.read_bytes(), name, "exec")
PYTHON
actionlint
