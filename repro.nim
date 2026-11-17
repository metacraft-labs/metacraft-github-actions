## Reprobuild project file for `metacraft-github-actions`.
##
## Shared reusable GitHub Actions. Consumers (codetracer's `ci/test/sibling-provisioning-test.sh`) read a checkout at `../metacraft-github-actions` to verify that their pinned action commits exist and carry the action.
##
## This recipe builds nothing and declares only its package: that is what
## lets a consumer name it in `uses:` (by its directory name, `"metacraft-github-actions"`)
## and lets `repro lock refresh` pin it in the consumer's `repro.lock`,
## which is the one record of a repo's dependencies. It declares no `uses:`
## of its own.

import repro_project_dsl

package metacraft_github_actions:
  defaultToolProvisioning "path"
