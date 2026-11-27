#!/usr/bin/env python3
"""The sibling names reveal-sibling-pin-ancestry.sh deepens are the ones the
pinned Reprobuild engine judges against a pin.

WHY
---
reveal-sibling-pin-ancestry.sh deepens a shallow workspace sibling only when
its directory name is in JUDGED_SIBLINGS: the names the source-built engine
(and the source checkout's `config.nims`) compare with the revision the
source pins, by `git merge-base --is-ancestor <pin> HEAD`. That list is a copy
of the engine's own candidate lists, and a copy goes stale silently: when a
pin bump brings an engine that judges one more sibling, the step leaves that
sibling shallow and the engine refuses it in some consumer's CI, after the
bump has landed. This check reads the names from the pinned source instead
and fails when the two differ, so the `pins` workflow catches the drift
before the bump merges.

The list is not derived at run time instead: the step runs before any
toolchain exists, with bash and git only (no grep or sed on the self-hosted
macOS runners), and parsing the engine's Nim source there would turn a format
change into a silent no-op in every consumer job. Here, a format change fails
one CI job of this repository, naming what moved.

WHAT IS READ (reprobuild 37a109c4 and later)
-------------------------------------------
Every judgement goes through one of the JUDGING_PRIMITIVES. Each call of one
must sit in a routine this check knows how to read (KNOWN_JUDGING_SITES);
anything else fails as "a site this check does not read", because the names
it judges cannot be derived here. From the known sites:

  * `libs/repro_interface_artifacts/.../repro_interface_artifacts.nim`:
    every call of `resolveSiblingFirstPackagePath` / `pinCheckedSiblingRoot`
    must be in `bootstrapSiblingPackagePathFlagsFor`. A call over
    `spec.candidates` judges each `specs` entry; any other call judges the
    candidates of the `resolve...Root` routine it passes (runquota).
  * `config.nims`: `addSiblingFirstPackagePath(<sibling>, ...)` at the top
    level, and a top-level statement (the io-mon block) that judges a
    `".." / "<name>"` sibling itself.

A candidate names a judged sibling only when it is a checkout directly in a
workspace root, as `isWorkspaceSiblingCheckout` requires: `".." / "<name>"`
or `".." / "<name>" / "src"`, or `<root> / "<name>"` in a `resolve...Root`
routine. `../codetracer/libs/<pkg>` is nested in another checkout, and
`libs/<pkg>` is inside the source tree; neither is judged.

USAGE
-----
  check-judged-siblings.py --source DIR   read a Reprobuild source tree
  check-judged-siblings.py --fetch [--rev REV] [--work DIR]
      fetch config.nims and the non-test *.nim files of libs/ and apps/ at
      REV (default: pins/reprobuild.json's rev) with a blobless, sparse,
      depth-1 fetch, and read that
  --script PATH   the step script to compare (default: beside this file)

Exit status 0 when the names agree, 1 when they differ or the source cannot
be read as described above, 2 on a usage error or a failed fetch.
Standard library only, like tools/check-pins.py.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
DEFAULT_SCRIPT = HERE / 'reveal-sibling-pin-ancestry.sh'
PIN_FILE = HERE.parent / 'pins' / 'reprobuild.json'

ENGINE = 'libs/repro_interface_artifacts/src/repro_interface_artifacts.nim'
CONFIG = 'config.nims'
TOP_LEVEL = '<top level>'

# The routines that read a pin and probe a sibling checkout with it
# (reprobuild `repro_core/sibling_source_policy`, `observeSiblingCheckout`,
# and `config.nims`'s `observeSibling`).
JUDGING_PRIMITIVES = ('chooseSiblingSource', 'observeSiblingCheckout', 'observeSibling')
# Where they are called at 37a109c4, and so the sites this check reads.
KNOWN_JUDGING_SITES = {
    (CONFIG, TOP_LEVEL),
    (CONFIG, 'addSiblingFirstPackagePath'),
    (ENGINE, 'resolveSiblingFirstPackagePath'),
    (ENGINE, 'pinCheckedSiblingRoot'),
}
ENGINE_JUDGES = ('resolveSiblingFirstPackagePath', 'pinCheckedSiblingRoot')
ENGINE_ENTRY = 'bootstrapSiblingPackagePathFlagsFor'

ROUTINE = re.compile(r'^(?:proc|func|template|iterator|method|macro|converter)\s+`?(\w+)')
# A path expression of string literals joined by `/`: `".." / "io-mon" / "src"`.
LITERAL_PATH = re.compile(r'"[^"\n]*"(?:\s*/\s*"[^"\n]*")*')
# `<root> / "<name>"` with exactly one segment, as `resolveRunquotaRoot`
# spells its candidates (`anchorRoot.parentDir / "runquota"`).
ROOTED_NAME = re.compile(r'\b\w+(?:\.parentDir(?:\(\))?)?\s*/\s*"([^"/\n]+)"\s*(?=[,\]\)])')


class SourceError(Exception):
    """The source does not have the shape this check reads."""


def strip_comment(line):
    """`line` without a `#` comment, ignoring `#` inside a string literal."""
    out, quoted = [], False
    for ch in line:
        if ch == '"':
            quoted = not quoted
        elif ch == '#' and not quoted:
            break
        out.append(ch)
    return ''.join(out)


def code_lines(text):
    """The lines of `text` with comments removed, numbered from 0."""
    return [strip_comment(line) for line in text.splitlines()]


def enclosing_routines(lines):
    """For each line, the top-level routine it lies in, or TOP_LEVEL. A
    column-0 statement that is not a routine definition ends the routine
    above it."""
    owners, current = [], TOP_LEVEL
    for line in lines:
        if line and not line[0].isspace():
            match = ROUTINE.match(line)
            current = match.group(1) if match else TOP_LEVEL
        owners.append(current)
    return owners


def routine_body(lines, name):
    """The lines of the top-level routine `name` (definition included)."""
    owners = enclosing_routines(lines)
    body = [line for line, owner in zip(lines, owners) if owner == name]
    if not body:
        raise SourceError('no top-level routine %s' % name)
    return body


def calls(lines, callee):
    """The line numbers that call `callee` (not its definition)."""
    pattern = re.compile(r'\b%s\s*\(' % re.escape(callee))
    return [i for i, line in enumerate(lines)
            if pattern.search(line) and not ROUTINE.match(line)]


def statement_at(lines, start):
    """The call statement beginning at line `start`, up to its balanced `)`."""
    depth, text = 0, []
    for line in lines[start:]:
        text.append(line)
        depth += line.count('(') - line.count(')')
        if depth <= 0 and '(' in ''.join(text):
            break
    return '\n'.join(text)


def top_level_statement(lines, index):
    """The column-0 statement containing line `index`, with its indented
    continuation."""
    start = index
    while start > 0 and not (lines[start] and not lines[start][0].isspace()):
        start -= 1
    end = index + 1
    while end < len(lines) and not (lines[end] and not lines[end][0].isspace()):
        end += 1
    return '\n'.join(lines[start:end])


def sibling_names(text):
    """The workspace-sibling checkouts named by the `".." / ...` literal path
    expressions in `text`: `".." / "<name>"` and `".." / "<name>" / "src"`."""
    names = set()
    for expression in LITERAL_PATH.findall(text):
        parts = re.findall(r'"([^"\n]*)"', expression)
        if parts[:1] == ['..'] and (len(parts) == 2 or (len(parts) == 3 and parts[2] == 'src')):
            names.add(parts[1])
    return names


def specs_block(lines):
    """The `let specs` list of `bootstrapSiblingPackagePathFlagsFor`."""
    body = routine_body(lines, ENGINE_ENTRY)
    start = next((i for i, line in enumerate(body)
                  if re.match(r'\s*let\s+specs\b', line)), None)
    if start is None:
        raise SourceError('%s has no `let specs` list' % ENGINE_ENTRY)
    indent = len(body[start]) - len(body[start].lstrip())
    end = next((i for i in range(start + 1, len(body))
                if body[i].strip() == ']' and len(body[i]) - len(body[i].lstrip()) == indent), None)
    if end is None:
        raise SourceError('%s: the `specs` list does not close' % ENGINE_ENTRY)
    return '\n'.join(body[start:end + 1])


def engine_names(lines):
    """The siblings `bootstrapSiblingPackagePathFlagsFor` judges."""
    owners = enclosing_routines(lines)
    routines = {owner for owner in owners if owner != TOP_LEVEL}
    names = set()
    for judge in ENGINE_JUDGES:
        sites = calls(lines, judge)
        if not sites:
            raise SourceError('%s is never called in %s' % (judge, ENGINE))
        for index in sites:
            if owners[index] != ENGINE_ENTRY:
                raise SourceError('%s is called from %s, a site this check does not read'
                                  % (judge, owners[index]))
            statement = statement_at(lines, index)
            if 'spec.candidates' in statement:
                found = sibling_names(specs_block(lines))
            else:
                found = set()
                for helper in re.findall(r'\b(\w+)\s*\(', statement):
                    if helper in routines and helper not in ENGINE_JUDGES and re.match(r'resolve\w*Root$', helper):
                        body = '\n'.join(routine_body(lines, helper))
                        found |= sibling_names(body) | set(ROOTED_NAME.findall(body))
            if not found:
                raise SourceError('the %s call at %s:%d judges no sibling this check can name'
                                  % (judge, ENGINE, index + 1))
            names |= found
    return names


def config_names(lines):
    """The siblings `config.nims` judges when the source is built."""
    owners = enclosing_routines(lines)
    names = set()
    sites = [i for i in calls(lines, 'addSiblingFirstPackagePath') if owners[i] == TOP_LEVEL]
    if not sites:
        raise SourceError('%s never calls addSiblingFirstPackagePath' % CONFIG)
    for index in sites:
        found = sibling_names(statement_at(lines, index))
        if len(found) != 1:
            raise SourceError('%s:%d: cannot name the sibling of this addSiblingFirstPackagePath call'
                              % (CONFIG, index + 1))
        names |= found
    for primitive in JUDGING_PRIMITIVES:
        for index in calls(lines, primitive):
            if owners[index] == TOP_LEVEL:
                found = sibling_names(top_level_statement(lines, index))
                if not found:
                    raise SourceError('%s:%d: a top-level %s call judges no sibling this check can name'
                                      % (CONFIG, index + 1, primitive))
                names |= found
    return names


def source_files(source):
    """config.nims and every non-test *.nim of libs/ and apps/."""
    files = [source / CONFIG]
    for top in ('libs', 'apps'):
        if (source / top).is_dir():
            for path in sorted((source / top).rglob('*.nim')):
                if 'tests' not in path.relative_to(source).parts:
                    files.append(path)
    return files


def judged_names(source):
    """The sibling directory names the Reprobuild source at `source` judges
    against its pins. Raises SourceError when its shape is not the one
    described in this file's header."""
    source = Path(source)
    for required in (CONFIG, ENGINE):
        if not (source / required).is_file():
            raise SourceError('%s is missing from %s' % (required, source))
    # Every judging call must be at a known site.
    for path in source_files(source):
        relative = path.relative_to(source).as_posix()
        lines = code_lines(path.read_text(encoding='utf-8', errors='replace'))
        owners = enclosing_routines(lines)
        for primitive in JUDGING_PRIMITIVES:
            for index in calls(lines, primitive):
                site = (relative, owners[index])
                if site not in KNOWN_JUDGING_SITES:
                    raise SourceError('%s:%d calls %s in %s, a site this check does not read'
                                      % (relative, index + 1, primitive, owners[index]))
    engine = code_lines((source / ENGINE).read_text(encoding='utf-8'))
    config = code_lines((source / CONFIG).read_text(encoding='utf-8'))
    return engine_names(engine) | config_names(config)


def listed_names(script):
    """JUDGED_SIBLINGS of the step script."""
    match = re.search(r'^JUDGED_SIBLINGS="([^"]*)"', Path(script).read_text(), re.M)
    if not match:
        raise SourceError('%s has no JUDGED_SIBLINGS="..." assignment' % script)
    return set(match.group(1).split())


def fetch(rev, work, url):
    """A sparse, blobless, depth-1 checkout of `rev` holding what
    judged_names reads."""
    def git(*args):
        env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
        subprocess.run(['git', '-C', str(work), *args], check=True, env=env)
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', 'init', '-q', str(work)], check=True)
    git('remote', 'add', 'origin', url)
    git('sparse-checkout', 'set', '--no-cone', '/' + CONFIG, '/libs/**/*.nim', '/apps/**/*.nim')
    git('-c', 'protocol.version=2', 'fetch', '-q', '--no-tags', '--depth', '1',
        '--filter=blob:none', 'origin', rev)
    git('-c', 'advice.detachedHead=false', 'checkout', '-q', '--detach', 'FETCH_HEAD')
    head = subprocess.run(['git', '-C', str(work), 'rev-parse', 'HEAD'], check=True,
                          capture_output=True, text=True).stdout.strip()
    if head != rev:
        raise subprocess.CalledProcessError(1, 'fetch', 'fetched %s, not %s' % (head, rev))
    return work


def compare(source, script):
    """0 and a report when the names agree, else 1 and the differences."""
    try:
        judged = judged_names(source)
        listed = listed_names(script)
    except SourceError as err:
        return 1, '\n'.join([
            'cannot read the judged siblings: %s.' % err,
            "The engine's sibling resolution changed shape; review JUDGED_SIBLINGS in %s"
            ' against it and update this check.' % Path(script).name,
        ])
    if judged == listed:
        return 0, 'JUDGED_SIBLINGS matches the %d siblings the source judges: %s' % (
            len(judged), ' '.join(sorted(judged)))
    lines = ['JUDGED_SIBLINGS in %s differs from the siblings the source judges.' % Path(script).name]
    if judged - listed:
        lines.append('  judged by the source, missing from the list: ' + ' '.join(sorted(judged - listed)))
    if listed - judged:
        lines.append('  in the list, not judged by the source: ' + ' '.join(sorted(listed - judged)))
    lines.append('Update JUDGED_SIBLINGS (and its comment) to the source\'s set.')
    return 1, '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument('--source', type=Path)
    where.add_argument('--fetch', action='store_true')
    parser.add_argument('--rev')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--script', type=Path, default=DEFAULT_SCRIPT)
    args = parser.parse_args(argv)
    source = args.source
    if args.fetch:
        pin = json.loads(PIN_FILE.read_text())
        rev = args.rev or pin['rev']
        url = 'https://github.com/%s/%s.git' % (pin['owner'], pin['repo'])
        work = args.work or Path(tempfile.mkdtemp(prefix='judged-siblings-'))
        try:
            source = fetch(rev, work, url)
        except (OSError, subprocess.CalledProcessError) as err:
            print('error: could not fetch %s at %s: %s' % (url, rev, err), file=sys.stderr)
            return 2
        print('read %s at %s' % (url, rev))
    elif args.rev or args.work:
        parser.error('--rev and --work go with --fetch')
    status, report = compare(source, args.script)
    print(report, file=sys.stdout if status == 0 else sys.stderr)
    return status


if __name__ == '__main__':
    sys.exit(main())
