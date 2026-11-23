#!/usr/bin/env python3
"""Solve and check CodeTracer's aarch64-darwin lock for a pinned revision.

CodeTracer commits two solves: `repro.lock` (amd64-linux) and
`locks/arm64-macosx.lock` (Apple Silicon). Reprobuild solves a lock only for
the host's own platform, so the second one can be produced only on an arm64
Mac. The `codetracer-mac-lock` workflow runs this tool on a GitHub-hosted arm64
macOS runner whenever `pins/codetracer.json` moves, so a pin that does not
solve on macOS fails before it merges.

Subcommands (every one but `solve` runs on any host and is covered by
tools/test-codetracer-mac-lock.py):

  resolve   Read the pin (or take an explicit --rev) and print `key=value`
            lines for $GITHUB_OUTPUT. Refuses a malformed pin or revision.
  fetch     Shallow-fetch exactly one revision of the pinned repository into
            a fresh directory. Exit 3 when the revision does not exist there.
  inspect   Print the Reprobuild engine and catalog revisions CodeTracer's own
            flake.lock pins (its independent cohort, guide section 2).
  inject-unsatisfiable
            Negative control: add a `uses:` constraint that contradicts one
            CodeTracer already declares, so the solve itself must be UNSAT.
  engine    Build the `repro` CodeTracer's flake.lock pins (macOS host; any
            host with Nix that can build packages.aarch64-darwin).
  check     The post-solve checks, and the classification of the solve
            against the committed lock (`confirmed` or `produced`).
  solve     The whole run on the macOS host: obtain the engine CodeTracer's
            flake.lock pins, provision the siblings at repro.lock's revisions,
            re-solve the darwin lock, and check it.

Exit status: 0 success; 1 a check or the solve failed; 2 a usage error or a
malformed input; 3 the revision does not exist in the repository.
"""

import argparse
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys

NATIVE_LOCK = "locks/arm64-macosx.lock"
CANONICAL_LOCK = "repro.lock"
NATIVE_PLATFORM = "arm64-macosx"
NIX_SYSTEM = "aarch64-darwin"
REV_RE = re.compile(r"^[0-9a-f]{40}$")
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
# The negative control must make the SOLVE fail, not the recipe compile or the
# provisioning before it. A floor alone cannot: the solver grounds a constraint
# that is unbounded above at the highest floor declared, so `"bash >=99999"`
# SOLVES, to bash 99999.0.0 (CodeTracer repro.nim, the comment above its
# `nim` pin; reprobuild libs/repro_dsl_stdlib/tests/
# t_unsatisfiable_lock_reports_conflict.nim, where `>=1.5` solves to 1.5.0).
# So the control contradicts the `"bash >=4"` CodeTracer already declares:
# no version satisfies both, and the solver must answer UNSAT.
UNSATISFIABLE = '    "bash <4"  # codetracer-mac-lock negative control, contradicts "bash >=4"\n'
CONTRADICTED = '"bash >=4"'
# How the engine says the constraints cannot hold together. `repro lock
# refresh` exits 3 printing "solver UNSAT" when its own solve is UNSAT
# (reprobuild repro_cli_support.nim, runLockGeneration). When the recipe's
# interface extraction runs the solve first, as it does for CodeTracer, the
# solver's exception surfaces there instead, and the refresh exits 1 with
# "no satisfying assignment exists ... [EUnsatisfiable]" (hosted macOS run
# 45206671911, engine reprobuild b90c910c). Either is the solver's own
# answer; a bare exit status, or any other failure, is not.
UNSAT_EXIT = 3
# `repro develop --all` reports each sibling it leaves alone because a recipe
# pins it: "skipped <name> — pinned by recipe at <file>:<line>: ...".
RECIPE_PINNED_SKIP = re.compile(r"\bskipped ([A-Za-z0-9._-]+) \S+ pinned by recipe at ")
UNSAT_TEXT = "solver UNSAT"
UNSAT_EXCEPTION = "[EUnsatisfiable]"


def is_unsat(status, output):
    if status == 0:
        return False
    if status == UNSAT_EXIT and any(UNSAT_TEXT in line for line in output):
        return True
    return any(UNSAT_EXCEPTION in line for line in output)
HERE = pathlib.Path(__file__).resolve().parent
SCOPED_GIT_AUTH = HERE.parent / "git-auth" / "scoped-git-auth.sh"


class Refusal(Exception):
    """An input this tool will not act on. Carries the exit status."""

    def __init__(self, message, status=2):
        super().__init__(message)
        self.status = status


def log(message):
    print(f"codetracer-mac-lock: {message}", file=sys.stderr, flush=True)


# ── pin ──────────────────────────────────────────────────────────────────────


def read_pin(path):
    try:
        pin = json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError) as err:
        raise Refusal(f"cannot read the pin {path}: {err}")
    if not isinstance(pin, dict):
        raise Refusal(f"{path}: the pin is not a JSON object")
    if pin.get("schema") != 1:
        raise Refusal(f"{path}: schema must be 1, not {pin.get('schema')!r}")
    if pin.get("tool") != "codetracer":
        raise Refusal(f"{path}: tool must be 'codetracer', not {pin.get('tool')!r}")
    for key in ("owner", "repo"):
        if not isinstance(pin.get(key), str) or not NAME_RE.fullmatch(pin[key]):
            raise Refusal(f"{path}: {key} {pin.get(key)!r} is not a GitHub name")
    if not isinstance(pin.get("rev"), str) or not REV_RE.fullmatch(pin["rev"]):
        raise Refusal(f"{path}: rev {pin.get('rev')!r} is not a full lowercase commit SHA")
    return pin


def cmd_resolve(args):
    pin = read_pin(args.pin)
    rev, source = pin["rev"], "pin"
    if args.rev:
        if not REV_RE.fullmatch(args.rev):
            raise Refusal(f"--rev {args.rev!r} is not a full lowercase commit SHA "
                          "(a branch or tag would make the result unreproducible)")
        rev, source = args.rev, "input"
    print(f"owner={pin['owner']}")
    print(f"repo={pin['repo']}")
    print(f"rev={rev}")
    print(f"source={source}")
    print(f"pinned-rev={pin['rev']}")
    return 0


# ── fetch ────────────────────────────────────────────────────────────────────


def git(*argv, cwd=None, check=True):
    res = subprocess.run(["git", *argv], cwd=cwd, capture_output=True, text=True, check=False)
    if check and res.returncode != 0:
        raise Refusal(f"git {' '.join(argv)} failed: {res.stderr.strip()[-500:]}", 1)
    return res


def fetch(url, rev, dest):
    if not REV_RE.fullmatch(rev):
        raise Refusal(f"revision {rev!r} is not a full lowercase commit SHA")
    dest = pathlib.Path(dest)
    if dest.exists() and any(dest.iterdir()):
        raise Refusal(f"{dest} exists and is not empty; refusing to fetch into it")
    dest.mkdir(parents=True, exist_ok=True)
    git("init", "--quiet", str(dest))
    git("remote", "add", "origin", url, cwd=dest)
    got = git("fetch", "--quiet", "--depth=1", "--no-tags", "origin", rev, cwd=dest, check=False)
    if got.returncode != 0:
        raise Refusal(f"revision {rev} does not exist in {url} (or is not fetchable): "
                      f"{got.stderr.strip()[-300:]}", 3)
    git("checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=dest)
    head = git("rev-parse", "HEAD", cwd=dest).stdout.strip()
    if head != rev:
        raise Refusal(f"fetched {head}, not the requested {rev}", 1)
    return dest


def cmd_fetch(args):
    url = args.url or f"https://github.com/{args.owner}/{args.repo}.git"
    fetch(url, args.rev, args.dest)
    log(f"fetched {args.rev} into {args.dest}")
    return 0


# ── lock files ───────────────────────────────────────────────────────────────


def parse_lock(path):
    """The fields this tool compares, from a solved-graph lock.

    The lock is TOML whose `deps` and `packages` arrays are each written on one
    line of inline tables; CodeTracer's own checks read it the same way
    (scripts/test-build-once-platform-lock.sh), with no TOML library.
    """
    try:
        text = pathlib.Path(path).read_text()
    except OSError as err:
        raise Refusal(f"cannot read lock {path}: {err}")
    plat = re.search(r'^platform = "([^"]*)"$', text, re.M)
    schema = re.search(r'^schema = "([^"]*)"$', text, re.M)
    deps_line = re.search(r"^deps\s*=\s*\[(.*)\]\s*$", text, re.M)
    deps, self_entry = {}, None
    if deps_line:
        for entry in re.findall(r"\{([^{}]*)\}", deps_line.group(1)):
            fields = dict(re.findall(r'(\w+)\s*=\s*"([^"\\]*)"', entry))
            if "name" not in fields:
                continue
            if fields.get("self") == "true":
                self_entry = fields
                continue
            deps[fields["name"]] = fields.get("revision", "")
    # Everything but the deps line, for the classification. The self entry is
    # excluded on purpose: it records the commit the lock was refreshed on, so
    # it moves with every refresh and says nothing about the solve.
    other = [line for line in text.splitlines() if not re.match(r"^deps\s*=", line)]
    return {
        "text": text,
        "schema": schema.group(1) if schema else None,
        "platform": plat.group(1) if plat else None,
        "has_deps": bool(deps_line),
        "deps": deps,
        "self": self_entry,
        "other": other,
    }


def flake_revisions(checkout):
    path = pathlib.Path(checkout) / "flake.lock"
    try:
        flake = json.loads(path.read_text())
        root_inputs = flake["nodes"][flake["root"]]["inputs"]
        out = {}
        for name in ("reprobuild", "reprobuild-packages"):
            node = root_inputs[name]
            if isinstance(node, list):
                raise Refusal(f"{path}: input {name} is a follows edge, not a locked node")
            out[name] = flake["nodes"][node]["locked"]["rev"]
    except Refusal:
        raise
    except (OSError, ValueError, KeyError, TypeError) as err:
        raise Refusal(f"cannot read the reprobuild inputs from {path}: {err!r}")
    for name, rev in out.items():
        if not isinstance(rev, str) or not REV_RE.fullmatch(rev):
            raise Refusal(f"{path}: {name} is locked at {rev!r}, not a commit SHA")
    return out


def require_files(checkout):
    root = pathlib.Path(checkout)
    for rel in (CANONICAL_LOCK, NATIVE_LOCK, "flake.lock", "repro.nim"):
        if not (root / rel).is_file():
            raise Refusal(f"{root} has no {rel}; this CodeTracer revision has no "
                          "Apple Silicon lock to solve")


def cmd_inspect(args):
    require_files(args.checkout)
    revs = flake_revisions(args.checkout)
    print(f"engine-rev={revs['reprobuild']}")
    print(f"catalog-rev={revs['reprobuild-packages']}")
    return 0


def inject_unsatisfiable(checkout):
    path = pathlib.Path(checkout) / "repro.nim"
    lines = path.read_text().splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.rstrip("\n") != "  uses:":
            continue
        # The block's entries, up to the next line indented no deeper than it.
        block = []
        for entry in lines[index + 1:]:
            if entry.strip() and not entry.startswith("   "):
                break
            block.append(entry.split("#", 1)[0].strip())
        if CONTRADICTED not in block:
            raise Refusal(f"{path}'s `uses:` block does not declare {CONTRADICTED}, so "
                          f"{UNSATISFIABLE.split('#')[0].strip()} would not contradict anything")
        lines.insert(index + 1, UNSATISFIABLE)
        path.write_text("".join(lines))
        return
    raise Refusal(f"{path} has no top-level `  uses:` block to add the negative control to")


def cmd_inject(args):
    inject_unsatisfiable(args.checkout)
    log(f"added {UNSATISFIABLE.strip()} to {args.checkout}/repro.nim")
    return 0


# ── checks and classification ────────────────────────────────────────────────


def post_solve_problems(produced, canonical, flake_revs):
    """Problems with a freshly solved darwin lock. Empty means it passes."""
    problems = []
    if produced["platform"] != NATIVE_PLATFORM:
        problems.append(f"the solved lock's platform is {produced['platform']!r}, "
                        f"not {NATIVE_PLATFORM!r}")
    if not produced["has_deps"]:
        problems.append("the solved lock has no dependency pins")
    if canonical["platform"] != "amd64-linux":
        problems.append(f"{CANONICAL_LOCK} is solved for {canonical['platform']!r}, "
                        "not 'amd64-linux'")
    # A revision is a source fact, not a platform fact: the two solves must
    # name the same source (CodeTracer scripts/check-platform-lock-pins.sh).
    for name in sorted(set(produced["deps"]) | set(canonical["deps"])):
        mine, theirs = produced["deps"].get(name), canonical["deps"].get(name)
        if mine != theirs:
            problems.append(f"dependency {name}: solved lock pins {mine or '(absent)'}, "
                            f"{CANONICAL_LOCK} pins {theirs or '(absent)'}")
    # The engine and catalog the lock records are the ones flake.lock pins
    # (CodeTracer scripts/test-build-once-platform-lock.sh).
    for name, rev in sorted(flake_revs.items()):
        if produced["deps"].get(name) != rev:
            problems.append(f"the solved lock pins {name} at "
                            f"{produced['deps'].get(name) or '(absent)'}, flake.lock at {rev}")
    return problems


def classify(produced, committed):
    """`confirmed` when the solve equals the committed lock (self entry
    aside), otherwise `produced`, with the differences named."""
    differences = []
    if committed is None:
        return "produced", ["no committed lock to compare with"]
    if produced["other"] != committed["other"]:
        keys = set()
        for line in set(produced["other"]) ^ set(committed["other"]):
            match = re.match(r"^(\w+)\s*=", line)
            keys.add(match.group(1) if match else line.strip()[:40])
        differences.append("fields that differ: " + ", ".join(sorted(keys)))
    for name in sorted(set(produced["deps"]) | set(committed["deps"])):
        new, old = produced["deps"].get(name), committed["deps"].get(name)
        if new != old:
            differences.append(f"{name}: {old or '(absent)'} -> {new or '(absent)'}")
    return ("confirmed" if not differences else "produced"), differences


def check(checkout, produced_path, committed_path):
    canonical = parse_lock(pathlib.Path(checkout) / CANONICAL_LOCK)
    produced = parse_lock(produced_path)
    committed = parse_lock(committed_path) if committed_path and pathlib.Path(committed_path).is_file() else None
    problems = post_solve_problems(produced, canonical, flake_revisions(checkout))
    outcome, differences = classify(produced, committed)
    return problems, outcome, differences


def cmd_check(args):
    problems, outcome, differences = check(args.checkout, args.produced, args.committed)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        return 1
    print(f"outcome={outcome}")
    for line in differences:
        print(f"  {line}")
    return 0


# ── solve (the macOS host) ───────────────────────────────────────────────────


def run_logged(argv, cwd, env, log_path, capture=None):
    """Run, streaming to stdout and to log_path (and to the list `capture`,
    when given). Returns the exit status."""
    log(f"$ {' '.join(argv)}   (in {cwd})")
    with open(log_path, "a", encoding="utf-8") as sink:
        try:
            proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
        except OSError as err:
            sink.write(f"cannot start {argv[0]}: {err}\n")
            log(f"cannot start {argv[0]}: {err}")
            return 127
        for line in proc.stdout:
            sys.stdout.write(line)
            sink.write(line)
            if capture is not None:
                capture.append(line)
        return proc.wait()


def nix_capture(argv, env):
    res = subprocess.run(argv, env=env, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise Refusal(f"{' '.join(argv[:3])} failed: {res.stderr.strip()[-1500:]}", 1)
    return res.stdout.strip()


def provision_engine(owner, repo, rev, env):
    """The `repro` CodeTracer's flake.lock pins, built by Nix as CodeTracer's
    own dev shell builds it (its `reprobuild` input, with CodeTracer's input
    overrides), plus the catalog and the bootstrap tools that shell exports."""
    flake = f'builtins.getFlake "github:{owner}/{repo}/{rev}"'
    nix = ["nix", "--extra-experimental-features", "nix-command flakes"]

    def build(attr):
        out = nix_capture(
            nix + ["build", "--no-link", "--print-out-paths", "--expr", f"({flake}).{attr}"], env)
        return out.splitlines()[-1]

    engine = build(f"inputs.reprobuild.packages.{NIX_SYSTEM}.reprobuild")
    cc = build(f"inputs.nixpkgs.legacyPackages.{NIX_SYSTEM}.stdenv.cc")
    bash = build(f"inputs.nixpkgs.legacyPackages.{NIX_SYSTEM}.bashInteractive")
    catalog = nix_capture(
        nix + ["eval", "--raw", "--expr", f"({flake}).inputs.reprobuild-packages.outPath"], env)
    if not os.path.isdir(catalog):
        raise Refusal(f"the reprobuild-packages catalog {catalog!r} is not a directory", 1)
    repro = pathlib.Path(engine) / "bin" / "repro"
    if not os.access(repro, os.X_OK):
        raise Refusal(f"{engine} has no bin/repro", 1)
    compiler = pathlib.Path(cc) / "bin" / "clang"
    if not compiler.exists():
        compiler = pathlib.Path(cc) / "bin" / "cc"
    extra = {
        # Exactly what CodeTracer's dev shell exports (nix/shells/ci-base.nix):
        # this catalog, and no sibling checkout, is where `uses:` names resolve.
        "REPROBUILD_PACKAGES_ROOT": catalog,
        # A wrapped Nix compiler and a bash >= 4: /usr/bin/cc and /bin/bash are
        # SIP binaries the macOS monitor cannot follow, and bash 3.2 cannot
        # parse nixpkgs' setup scripts (workspace AGENTS.md, macOS variables).
        "REPRO_BOOTSTRAP_CC": str(compiler),
        "REPRO_FOREIGN_ENV_BASH": str(pathlib.Path(bash) / "bin" / "bash"),
    }
    return str(repro), extra


def read_engine_file(path):
    try:
        engine = json.loads(pathlib.Path(path).read_text())
        repro, extra = engine["repro"], engine["env"]
    except (OSError, ValueError, KeyError, TypeError) as err:
        raise Refusal(f"cannot read the engine file {path}: {err!r}", 1)
    if not isinstance(repro, str) or not isinstance(extra, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in extra.items()):
        raise Refusal(f"{path} is not an engine file written by `engine`", 1)
    return {"repro": repro, "env": extra}


def cmd_engine(args):
    """Build the engine and write where it is, so the solve can run in a later
    step with a freshly minted token (installation tokens last one hour, and
    a cold engine build on a hosted Mac can take most of that)."""
    if not REV_RE.fullmatch(args.rev):
        raise Refusal(f"--rev {args.rev!r} is not a full lowercase commit SHA")
    repro, extra = provision_engine(args.owner, args.repo, args.rev, dict(os.environ))
    pathlib.Path(args.out).write_text(json.dumps({"repro": repro, "env": extra}, indent=2) + "\n")
    print(f"repro={repro}")
    return 0


def cmd_solve(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    solve_log = out / "solve.log"
    checkout = pathlib.Path(args.checkout).resolve()
    result = {"owner": args.owner, "repo": args.repo, "rev": args.rev,
              "expect": args.expect, "negative_control": args.negative_control,
              "stage": "setup", "outcome": None, "problems": [], "differences": []}

    def finish(status, message):
        result["message"] = message
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        write_summary(result)
        print(f"outcome={result['outcome']}")
        log(message)
        return status

    if not args.any_host and (platform.system() != "Darwin" or platform.machine() != "arm64"):
        raise Refusal(f"solve needs an arm64 macOS host, this is {platform.system()} "
                      f"{platform.machine()}: Reprobuild solves a lock only for the "
                      "host's own platform")
    require_files(checkout)
    result["engine_rev"] = flake_revisions(checkout)["reprobuild"]
    shutil.copyfile(checkout / NATIVE_LOCK, out / "committed-arm64-macosx.lock")
    try:
        return solve_stages(args, checkout, out, solve_log, result, finish)
    except Refusal as err:
        result["outcome"] = "failed"
        return finish(err.status or 1, f"stage {result['stage']}: {err}")


def solve_stages(args, checkout, out, solve_log, result, finish):
    env = dict(os.environ)
    env.pop("CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT", None)
    if args.repro:
        repro = args.repro
    elif args.engine_file:
        engine = read_engine_file(args.engine_file)
        repro = engine["repro"]
        env.update(engine["env"])
        result["engine"] = repro
    else:
        result["stage"] = "engine"
        repro, extra = provision_engine(args.owner, args.repo, args.rev, env)
        env.update(extra)
        result["engine"] = repro
    status = run_logged([repro, "--version"], str(checkout), env, solve_log)
    if status != 0:
        result["outcome"] = "failed"
        return finish(1, f"the engine does not run (exit {status})")

    # Every sibling at repro.lock's revisions, next to the checkout, the way a
    # developer's workspace has them. Repro scrubs numbered git configuration,
    # so the credential reaches its clones only as a private GIT_CONFIG_GLOBAL
    # file (git-auth/scoped-git-auth.sh, scoped_git_auth_with_global).
    result["stage"] = "develop"

    def develop(*selection, capture=None):
        return run_logged(
            [
                "bash", "-c", '. "$0" && scoped_git_auth_with_global "$@"', str(SCOPED_GIT_AUTH),
                repro, "develop", "--all", *selection, "--reset", f"--into={checkout.parent}",
            ],
            str(checkout), env, solve_log, capture=capture)

    output = []
    status = develop(capture=output)
    if status != 0:
        result["outcome"] = "failed"
        return finish(1, f"provisioning the siblings at repro.lock's revisions failed (exit {status})")
    # A bulk selection skips every sibling whose recipe pins an exact revision
    # (reprobuild docs/user-guide/workspace-locking.md, "A bulk selection skips
    # an exact pin"), yet `lock refresh` refuses (exit 5) while a develop-set
    # sibling is not checked out: hosted run 45206671911 refused for
    # test-certificates-tools and nim-shm-queue. Repro names each one it
    # skipped; select exactly those explicitly, which places them at the
    # revision the lock and the recipe pin agree on.
    found = (RECIPE_PINNED_SKIP.search(line) for line in output)
    pinned = sorted({match.group(1) for match in found if match})
    result["recipe_pinned"] = pinned
    if pinned:
        status = develop(f"--only={','.join(pinned)}")
        if status != 0:
            result["outcome"] = "failed"
            return finish(
                1, f"provisioning the recipe-pinned siblings {', '.join(pinned)} failed "
                f"(exit {status})")

    # After provisioning, so that only the solve can be what rejects it.
    if args.negative_control:
        inject_unsatisfiable(checkout)

    result["stage"] = "solve"
    refresh = [repro, "lock", "refresh", ".", "--lock", NATIVE_LOCK, f"--platform={NATIVE_PLATFORM}"]
    output = []
    status = run_logged(refresh, str(checkout), env, solve_log, capture=output)
    if status != 0:
        unsat = is_unsat(status, output)
        result["refresh_exit"] = status
        result["outcome"] = "unsolvable" if unsat else "failed"
        if args.expect == "fail":
            if unsat:
                return finish(
                    0, f"the solver rejected the constraints as UNSAT, as expected (exit {status})")
            # Only the solver's own UNSAT is the expected failure. A pin
            # regression (4), an incomplete solve (5), a crash or a network
            # error would pass a control that accepted any failure.
            return finish(
                1, f"the solve failed, but not as UNSAT (exit {status}, neither {UNSAT_TEXT!r} "
                f"nor {UNSAT_EXCEPTION!r}): this is not the failure the run expected")
        what = "does not solve (UNSAT)" if unsat else "could not be re-solved"
        return finish(1, f"the aarch64-darwin lock {what} at {args.rev} (exit {status})")
    if args.expect == "fail":
        result["outcome"] = "solved-unexpectedly"
        return finish(1, "the lock solved although this run expected the solve to fail")

    result["stage"] = "check"
    shutil.copyfile(checkout / NATIVE_LOCK, out / "arm64-macosx.lock")
    problems, outcome, differences = check(
        checkout, out / "arm64-macosx.lock", out / "committed-arm64-macosx.lock")
    # CodeTracer's own check, when this revision carries it, as a second
    # opinion that moves with CodeTracer rather than with this repository.
    own = checkout / "scripts" / "check-platform-lock-pins.sh"
    if own.is_file():
        own_check = ["bash", str(own), str(checkout / NATIVE_LOCK), str(checkout / CANONICAL_LOCK)]
        status = run_logged(own_check, str(checkout), env, solve_log)
        if status != 0:
            problems.append(f"CodeTracer's scripts/check-platform-lock-pins.sh exited {status}")
    result["problems"], result["differences"] = problems, differences
    if problems:
        result["outcome"] = "failed-checks"
        return finish(1, "the solved lock fails its checks: " + "; ".join(problems))
    result["outcome"] = outcome
    return finish(0, f"{outcome}: the aarch64-darwin lock solves at {args.rev}")


def write_summary(result):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    lines = [
        "### CodeTracer aarch64-darwin lock",
        "",
        f"- revision: `{result['owner']}/{result['repo']}@{result['rev']}`",
        f"- engine (CodeTracer flake.lock reprobuild): `{result.get('engine_rev')}`",
        f"- expected: `{result['expect']}`; negative control: `{result['negative_control']}`",
        f"- outcome: **{result['outcome']}** (stage `{result['stage']}`)",
        f"- {result.get('message', '')}",
    ]
    lines += [f"  - problem: {p}" for p in result["problems"]]
    lines += [f"  - difference: {d}" for d in result["differences"]]
    with open(path, "a", encoding="utf-8") as sink:
        sink.write("\n".join(lines) + "\n")


# ── command line ─────────────────────────────────────────────────────────────


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("resolve")
    p.add_argument("--pin", default=str(HERE.parent / "pins" / "codetracer.json"))
    p.add_argument("--rev", default="")
    p.set_defaults(func=cmd_resolve)

    p = sub.add_parser("fetch")
    p.add_argument("--owner", default="metacraft-labs")
    p.add_argument("--repo", default="codetracer")
    p.add_argument("--rev", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--url", default="", help="override the clone URL (tests)")
    p.set_defaults(func=cmd_fetch)

    p = sub.add_parser("inspect")
    p.add_argument("--checkout", required=True)
    p.set_defaults(func=cmd_inspect)

    p = sub.add_parser("inject-unsatisfiable")
    p.add_argument("--checkout", required=True)
    p.set_defaults(func=cmd_inject)

    p = sub.add_parser("check")
    p.add_argument("--checkout", required=True)
    p.add_argument("--produced", required=True)
    p.add_argument("--committed", default="")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("engine")
    p.add_argument("--owner", default="metacraft-labs")
    p.add_argument("--repo", default="codetracer")
    p.add_argument("--rev", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_engine)

    p = sub.add_parser("solve")
    p.add_argument("--owner", default="metacraft-labs")
    p.add_argument("--repo", default="codetracer")
    p.add_argument("--rev", required=True)
    p.add_argument("--checkout", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--expect", choices=("solve", "fail"), default="solve")
    p.add_argument("--negative-control", action="store_true")
    p.add_argument("--engine-file", default="", help="the engine `engine` built")
    p.add_argument("--repro", default="", help="use this engine instead of building it (tests)")
    p.add_argument("--any-host", action="store_true", help="skip the arm64 macOS host check (tests)")
    p.set_defaults(func=cmd_solve)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Refusal as err:
        log(f"error: {err}")
        return err.status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
