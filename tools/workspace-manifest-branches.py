#!/usr/bin/env python3
"""Which metacraft-labs/repro-workspace branches section 0b checks.

usage: git ls-remote --heads <repro-workspace> | tools/workspace-manifest-branches.py

Section 0b of metacraft-pm how-to-distribute-new-reprobuild-versions-internally.md
requires the pinned `repro` to read the workspace manifests people actually
use. Those live on the workspace root's branches, and the workspace root is
migrating from the `dev`/`agents` pair to a single mainline `latest`
(repro-workspace AGENTS.md, "Repository Classes"; metacraft-dev-guidelines
policies/branching-policy.md). While the migration runs, people still work
from whichever of the three exists, so every one that exists is checked. When
`dev` and `agents` are retired they drop out of the set and the check keeps
working on `latest` alone; a check that names a deleted branch fails before it
checks anything, which is what happened when `agents` was retired.

`latest` is the root's declared mainline, so its absence is an error, not a
reason to check less: a check that quietly passes on `dev` alone would stop
covering the manifests the policy says are current.

Reads `git ls-remote --heads` output on stdin (or from --heads FILE). Prints
GITHUB_OUTPUT lines on stdout: `branches=<space-separated, latest first>` and
`<branch>=true|false` for each candidate. Logs what is checked and what is
absent on stderr.

Exit status 0 when `latest` exists, 1 when it does not (including when none of
the candidates exists), 2 when the input is not `git ls-remote` output.
"""
import argparse
import re
import sys

# The root's policy-defined branches, mainline first. Order is the check order.
CANDIDATES = ('latest', 'dev', 'agents')
MAINLINE = 'latest'
LINE = re.compile(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?\t(refs/\S+)$')


def heads(text):
    names = set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        match = LINE.match(line)
        if not match:
            raise ValueError(f'line {number} is not `git ls-remote` output: {line!r}')
        ref = match.group(1)
        if ref.startswith('refs/heads/'):
            names.add(ref[len('refs/heads/'):])
    return names


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--heads', default='-',
                        help='`git ls-remote --heads` output (default: stdin)')
    args = parser.parse_args(argv)
    text = sys.stdin.read() if args.heads == '-' else open(args.heads).read()
    try:
        present = heads(text)
    except ValueError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    checked = [name for name in CANDIDATES if name in present]
    absent = [name for name in CANDIDATES if name not in present]
    print(f"repro-workspace branches checked: {' '.join(checked) or '(none)'}", file=sys.stderr)
    print(f"repro-workspace branches absent:  {' '.join(absent) or '(none)'}", file=sys.stderr)
    if not checked:
        print(f"error: none of {', '.join(CANDIDATES)} exists in repro-workspace;"
              ' section 0b would check nothing', file=sys.stderr)
        return 1
    if MAINLINE not in present:
        print(f'error: repro-workspace has no `{MAINLINE}`, the workspace root\'s mainline;'
              ' section 0b would not check the current manifests', file=sys.stderr)
        return 1
    print(f"branches={' '.join(checked)}")
    for name in CANDIDATES:
        print(f"{name}={'true' if name in present else 'false'}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
