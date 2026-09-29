"""Real daemon/UID/SQLite controls; the wrapper delays execution, never results."""
import os
from pathlib import Path
import shutil
import subprocess

evidence = Path("build/diagnostics/capture-readiness")
evidence.mkdir(parents=True, exist_ok=True)
real_sqlite = shutil.which("sqlite3")
assert real_sqlite and real_sqlite.startswith("/nix/store/")
# Nix build users must traverse the wrapper's path. Put it under shared /tmp,
# rather than a checkout whose parent may be private to the runner account.
wrapper_dir = Path("/tmp") / ("runquota-capture-readiness-" + str(os.getpid()))
wrapper_dir.mkdir(mode=0o755)
wrapper = wrapper_dir / "sqlite3"
wrapper.write_text('''#!/bin/sh
# Scheduling control: run the real pinned SQLite with unchanged arguments and
# streams, after delaying its first invocation for this fixture's database.
for arg in "$@"; do
  case "$arg" in
    /tmp/rqsu*/rv/state/obs.sqlite)
      if /bin/mkdir "$arg.start-delayed" 2>/dev/null; then /bin/sleep 3; fi
      ;;
  esac
done
exec ''' + real_sqlite + ''' "$@"
''')
wrapper.chmod(0o755)
slow_env = dict(os.environ, PATH=str(wrapper_dir) + os.pathsep + os.environ["PATH"])


def run(name, argv, env=None):
    with (evidence / (name + ".log")).open("w") as output:
        result = subprocess.run(argv, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=300)
    print(name, result.returncode, flush=True)
    if result.returncode:
        print((evidence / (name + ".log")).read_text()[-5000:], flush=True)
    return result.returncode


def compile_test(source, output):
    subprocess.run(["nim", "c", "--path:tests/support",
                    "--nimcache:build/nimcache/" + output.name,
                    "--out:" + str(output), str(source)], check=True)


try:
    subprocess.run(["bash", "scripts/build_apps.sh"], check=True)
    source = Path("tests/integration/t_shared_endpoint_second_uid.nim")
    after = evidence / "second_uid_after"
    compile_test(source, after)
    assert run("normal-startup", [str(after.resolve())]) == 0
    assert run("delayed-sqlite", [str(after.resolve())], slow_env) == 0

    # Restore only the former readiness predicate in a private source copy.
    # The real daemon, users, permissions and persisted-owner assertions stay.
    text = source.read_text()
    start = text.index("          var captureReady = false\n")
    end = text.index("          if fileExists(readyFlag):\n", start)
    text = text[:start] + '''          for _ in 0 ..< 1200:
            if fileExists(readyFlag): break
            sleep(50)
          check fileExists(readyFlag)
''' + text[end:]
    before_source = evidence / "second_uid_before.nim"
    before_source.write_text(text)
    before = evidence / "second_uid_before"
    compile_test(before_source, before)
    code = run("socket-only-negative", [str(before.resolve())], slow_env)
    negative = (evidence / "socket-only-negative.log").read_text()
    assert code != 0 and "owners.len was 0" in negative and "[FAILED]" in negative
finally:
    shutil.rmtree(wrapper_dir)
