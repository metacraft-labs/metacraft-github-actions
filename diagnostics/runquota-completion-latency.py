"""Measure real lease operations and reject a real synchronous-store regression.

No mocks. The complete fixture keeps its 2 ms ceiling, paired comparison,
publication checks and 600-second action bound. Only the measured interval
differs between the two fixture variants. The final disposable daemon restores
a synchronous SQLite flush on the keyed completion path as a positive control.
"""
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
evidence = root / 'build/windows-completion-latency'
evidence.mkdir(parents=True, exist_ok=True)
fixture = root / 'tests/integration/t_completion_report_does_not_wait_on_the_store.nim'
daemon = root / 'libs/runquota_daemon/src/runquota_daemon.nim'
recipe = root / 'repro.nim'
original = fixture.read_text()
original_daemon = daemon.read_text()
original_recipe = recipe.read_text()

start = original.index('proc timeOneCompletion(')
end = original.index('\nproc median(', start)
timed = '''type CompletionParts = array[6, float]
var completionParts: array[2, seq[CompletionParts]]

proc timeOneCompletion(session: var RunQuotaSession; statsKey: string;
                       peakBytes: uint64): float =
  var request = resourceRequest("completion-latency", milliCpu(100),
    bytes(1'u64 * MiB))
  request.commandStatsId = statsKey
  let started = getMonoTime()
  var lease = session.requestLease(request)
  doAssert lease.active
  let admitted = getMonoTime()
  lease.markStarting()
  let starting = getMonoTime()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  let running = getMonoTime()
  lease.finish(outcome = succeeded(), peakMemoryBytes = peakBytes,
    processCount = 1'u32)
  let finished = getMonoTime()
  lease.release()
  let released = getMonoTime()
  template millis(first, last: untyped): float =
    float((last - first).inNanoseconds) / 1_000_000.0
  let parts: CompletionParts = [millis(started, admitted),
    millis(admitted, starting), millis(starting, running),
    millis(running, finished), millis(finished, released),
    millis(started, released)]
  completionParts[ord(statsKey.len > 0)].add(parts)
  result = parts[5]
'''
whole = original[:start] + timed + original[end:]
anchor = '      var keyed: seq[float] = @[]'
assert whole.count(anchor) == 1
whole = whole.replace(anchor, '''      completionParts[0].setLen(0)
      completionParts[1].setLen(0)
''' + anchor)
anchor = '      check keyedMedian <= keylessMedian + LatencySlackMillis'
assert whole.count(anchor) == 1
whole = whole.replace(anchor, '''      for arm in 0 .. 1:
        for part, name in ["admission", "starting", "running", "finish",
                           "release", "lifecycle"]:
          var samples: seq[float] = @[]
          for sample in completionParts[arm]: samples.add(sample[part])
          echo "COMPLETION-PART arm=", arm, " operation=", name,
            " samples=", samples.len, " medianMs=", median(samples)
''' + anchor)
assert whole.count('  result = parts[5]') == 1
finish = whole.replace('  result = parts[5]', '  result = parts[3]')

anchor = '''  if not daemon.observationCaptureEnabled: return
  notePendingKey(statsKey)'''
assert original_daemon.count(anchor) == 1
synchronous = original_daemon.replace(anchor, '''  if not daemon.observationCaptureEnabled: return
  # Positive control: restore actual store IO in the keyed completion handler.
  flushObservationWriter()
  notePendingKey(statsKey)''')
variants = [('whole', whole, original_daemon),
            ('finish', finish, original_daemon),
            ('synchronous', finish, synchronous)]
for name, contents, daemon_contents in variants:
    (evidence / ('completion_' + name + '.nim')).write_text(contents)
    if name == 'synchronous':
        (evidence / 'runquota_daemon_synchronous.nim').write_text(daemon_contents)
if '--prepare-only' in sys.argv:
    raise SystemExit(0)

anchor = '    testSources.sort()'
assert original_recipe.count(anchor) == 1
focused = original_recipe.replace(anchor, '''    testSources.sort()
    var focusedSources: seq[string] = @[]
    for source in testSources:
      if source.extractFilename == "t_completion_report_does_not_wait_on_the_store.nim":
        focusedSources.add(source)
    testSources = focusedSources''')
results = []
try:
    recipe.write_text(focused)
    for name, contents, daemon_contents in variants:
        fixture.write_text(contents)
        # The fixture refuses a daemon older than its source files. Rewriting
        # identical source would change mtime without invalidating Reprobuild's
        # content cache, manufacturing a stale-binary failure in the next arm.
        if daemon.read_text() != daemon_contents:
            daemon.write_text(daemon_contents)
        report = evidence / (name + '.json')
        log = evidence / (name + '.log')
        command = ['repro', 'test', '--daemon=off', '--tool-provisioning=tarball',
                   '--write-report=' + str(report)]
        with log.open('w') as output:
            code = subprocess.run(command, stdout=output,
                                  stderr=subprocess.STDOUT).returncode
        result = {'name': name, 'exitCode': code}
        executions = []
        if report.exists():
            executions = [a for a in json.loads(report.read_text())['actions']
                          if a['id'].startswith('runquota.test_execute.')]
        result['executions'] = [
            {k: a.get(k) for k in ('id', 'status', 'exitCode', 'launched')}
            for a in executions]
        results.append(result)
        (evidence / 'results.json').write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
        if len(executions) != 1 or not executions[0].get('launched'):
            raise SystemExit('Control did not execute the real completion fixture')
        output = executions[0].get('stdout', '')
        (evidence / (name + '-stdout.log')).write_text(output)
        parts = [line for line in output.splitlines() if line.startswith('COMPLETION-PART ')]
        if len(parts) != 12 or not all(' samples=40 ' in line for line in parts):
            raise SystemExit('Control did not measure all six operations in both arms')
        for line in output.splitlines():
            if ('COMPLETION-PART' in line or ' p50 ' in line or
                    'drains:' in line or 'Check failed:' in line):
                print(line[:1000], flush=True)
        if name == 'finish' and (code or executions[0].get('exitCode') != 0):
            raise SystemExit('Completion-only fixture failed')
        if name == 'synchronous':
            expected = ['Check failed: drains < Completions div 2',
                        'Check failed: keyedMedian <= keylessMedian + LatencySlackMillis']
            if executions[0].get('exitCode') != 1 or not all(s in output for s in expected):
                raise SystemExit('Positive control did not fail both store-drain and latency checks')
finally:
    fixture.write_text(original)
    if daemon.read_text() != original_daemon:
        daemon.write_text(original_daemon)
    recipe.write_text(original_recipe)
