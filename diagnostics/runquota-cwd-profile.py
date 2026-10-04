"""Record real M5 child phases and completion without changing assertions.

Temporary diagnostic only. The caller retains the diff and restores the file.
No mocks, replacement processes, altered deadlines or reduced workloads.
"""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()


def replace_once(before, after):
    global source
    assert source.count(before) == 1, before
    source = source.replace(before, after)


replace_once("strutils, tempfiles, unittest]", "strutils, tempfiles, times, unittest]")
replace_once(
    'if commandLineParams().len == 1 and commandLineParams()[0] == FixtureCwdEnv:\n',
    'if commandLineParams().len == 1 and commandLineParams()[0] == FixtureCwdEnv:\n'
    '  stderr.writeLine("cwd-profile phase=child-entry pid=" & $getCurrentProcessId() &\n'
    '    " time=" & $epochTime())\n'
    '  stderr.flushFile()\n',
)
replace_once(
    '    try:\n      var child = launchProcess(commandSpec(\n',
    '    try:\n'
    '      echo "cwd-profile phase=launch-begin time=", epochTime(), " cwd=", cwdDir\n'
    '      var child = launchProcess(commandSpec(\n',
)
replace_once(
    '      let completion = child.waitForCompletion(3000)\n      child.close()\n',
    '      echo "cwd-profile phase=launch-end time=", epochTime(), " pid=", child.pid\n'
    '      let completion = child.waitForCompletion(3000)\n'
    '      echo "cwd-profile phase=wait-end time=", epochTime(), " completion=", completion\n'
    '      child.close()\n'
    '      echo "cwd-profile phase=close-end time=", epochTime()\n',
)
path.write_text(source)
