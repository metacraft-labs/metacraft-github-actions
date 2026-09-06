# metacraft-github-actions
Shared GitHub Actions for metacraft-labs projects

## `assert-workflow-triggers`

Fails when a workflow's `push` / `pull_request` branch filters do not name the
branch the repository actually merges into.

A filter naming a branch the repository does not have is not an error. It
produces no run, silently and permanently, and an empty check list on a
mainline commit looks exactly like a clean one. This repository's own
`test.yml` said `branches: [main]` while its mainline was `dev`; a sweep
afterwards found the same defect in 33 workflows across 22 repositories.

Add it to any workflow that already checks the repository out:

```yaml
      - uses: metacraft-labs/metacraft-github-actions/assert-workflow-triggers@dev
```

The mainline is detected from the branches that exist on `origin`, in
[branching-policy](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/branching-policy.md)
order — `dev`, then `latest`, then `live`. Detection has no `main` fallback: a
repository that has not migrated has nothing to enforce, and guessing `main`
would be the very assumption the guard exists to catch. Product-adapted forks,
whose mainline is a product name, state it:

```yaml
      - uses: metacraft-labs/metacraft-github-actions/assert-workflow-triggers@dev
        with:
          mainline: codetracer
```

Workflows filtered only by `tags:` are release triggers, not branch triggers,
and pass unchanged. A workflow that genuinely must not run on the mainline —
a deploy belonging to one environment branch — says so in the file, with a
reason, which is checked for and cannot be left blank:

```yaml
# ci-mainline-exempt: deploys the hosted app; `cloud` is the deploy branch
```
