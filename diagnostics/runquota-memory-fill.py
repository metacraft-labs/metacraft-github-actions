"""Compare complete real ambient fixtures without changing their 600s bound.

No mocks. Both variants allocate all nine 4-GiB mappings and retain every
assertion. Only diagnostic recipe selection and memory population differ.
"""
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
evidence = root / 'build/windows-memory-fill'
evidence.mkdir(parents=True, exist_ok=True)
fixture = root / 'tests/integration/t_ambient_load_attribution.nim'
source = fixture.read_text()
source = source.replace('import std/[algorithm,',
                        'import std/[monotimes, sysrand]\n\nimport std/[algorithm,', 1)
anchor = '        memory = takeMemory(int(knownBytes), random)\n'
assert source.count(anchor) == 1
source = source.replace(anchor, '''        let fillStarted = getMonoTime()
        echo "MEM-FILL begin cycle=", fullWindows.len + 1
        flushFile(stdout)
''' + anchor + '''        echo "MEM-FILL complete cycle=", fullWindows.len + 1,
          " elapsedMs=", (getMonoTime() - fillStarted).inMilliseconds
        flushFile(stdout)
''')
old_fill = '''  doAssert size mod sizeof(uint64) == 0
  let words = cast[ptr UncheckedArray[uint64]](base)
  for index in 0 ..< size div sizeof(uint64):
    words[index] = next(random)
'''
assert source.count(old_fill) == 1
bulk = source.replace(old_fill, '''  let bytes = cast[ptr UncheckedArray[byte]](base)
  var offset = 0
  while offset < size:
    let count = min(4 * 1024 * 1024, size - offset)
    doAssert urandom(bytes.toOpenArray(offset, offset + count - 1)),
      "could not populate the real memory load"
    offset += count
''')
variants = [('original', source), ('bulk', bulk)]
for name, contents in variants:
    (evidence / ('ambient_' + name + '.nim')).write_text(contents)
if '--prepare-only' in sys.argv:
    raise SystemExit(0)

recipe = root / 'repro.nim'
original_recipe = recipe.read_text()
anchor = '    testSources.sort()'
assert original_recipe.count(anchor) == 1
focused = original_recipe.replace(anchor, '''    testSources.sort()
    var focusedSources: seq[string] = @[]
    for source in testSources:
      if source.extractFilename == "t_ambient_load_attribution.nim":
        focusedSources.add(source)
    testSources = focusedSources''')
original_source = fixture.read_text()
results = []
try:
    recipe.write_text(focused)
    for name, contents in variants:
        fixture.write_text(contents)
        report = evidence / (name + '.json')
        log = evidence / (name + '.log')
        command = ['repro', 'test', '--daemon=off', '--tool-provisioning=tarball',
                   '--write-report=' + str(report)]
        with log.open('w') as output:
            code = subprocess.run(command, stdout=output,
                                  stderr=subprocess.STDOUT).returncode
        result = {'name': name, 'exitCode': code}
        if report.exists():
            actions = json.loads(report.read_text())['actions']
            result['executions'] = [
                {k: action.get(k) for k in ('id', 'status', 'exitCode', 'launched')}
                for action in actions if action['id'].startswith('runquota.test_execute.')]
        results.append(result)
        (evidence / 'results.json').write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
        executions = result.get('executions', [])
        if len(executions) != 1 or not executions[0].get('launched'):
            raise SystemExit('Control did not execute the actual ambient fixture')
        for line in log.read_text(errors='replace').splitlines():
            if 'MEM-FILL' in line or 'm11 mem:' in line or '[FAILED]' in line:
                print(line[:1000], flush=True)
        if name == 'bulk' and (code or executions[0].get('exitCode') != 0):
            raise SystemExit('Bulk-filled complete ambient fixture failed')
finally:
    fixture.write_text(original_source)
    recipe.write_text(original_recipe)
