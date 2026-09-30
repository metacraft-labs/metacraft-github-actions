"""Real ambient controls; preserve assertions and print samples after measurement."""
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / 'build/macos-ambient-boundaries'
evidence.mkdir(parents=True, exist_ok=True)
results = []


def run(name, args, *, cwd=root, env=None, required=True):
    with (evidence / (name + '.log')).open('w') as output:
        try:
            code = subprocess.run(args, cwd=cwd, env=env, stdout=output,
                                  stderr=subprocess.STDOUT, timeout=1200).returncode
        except subprocess.TimeoutExpired:
            code = 124
    results.append({'name': name, 'exitCode': code})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    if required and code:
        raise SystemExit(name + ' failed')


source = (root / 'tests/integration/t_ambient_load_attribution.nim').read_text()
anchor = '      let reportingRows = inWindows(rows, [reporting])\n'
assert source.count(anchor) == 1
source = source.replace(anchor, '''      echo "DIAGNOSTIC reporting=", reporting.fromMillis, "..", reporting.toMillis,
        " clamped=", clamped.fromMillis, "..", clamped.toMillis,
        " released=", released.fromMillis, "..", released.toMillis
      for row in rows:
        echo "DIAGNOSTIC sample=", row.sampledAtUnixMillis,
          " selfCpu=", row.selfCpuPct, " selfRss=", row.selfRssBytes,
          " foreignCpu=", row.foreignCpuPct
''' + anchor)
old_touch = '''  let bytes = cast[ptr UncheckedArray[byte]](base)
  var offset = 0
  while offset < size:
    bytes[offset] = byte(random.rand(255))
    offset += 4096
'''
assert source.count(old_touch) == 1
corrected = source.replace(old_touch, '''  doAssert size mod sizeof(uint64) == 0
  let words = cast[ptr UncheckedArray[uint64]](base)
  for index in 0 ..< size div sizeof(uint64):
    words[index] = next(random)
''').replace('row.sampledAtUnixMillis >= window.fromMillis and',
            'row.sampledAtUnixMillis > window.fromMillis and').replace(
            'row.sampledAtUnixMillis <= window.toMillis:',
            'row.sampledAtUnixMillis < window.toMillis:')
run('apps-build', ['nix', 'develop', '--command', 'bash', 'scripts/build_apps.sh'])
for name, contents in [('original', source), ('corrected', corrected)]:
    fixture = root / 'build/diagnostics' / ('ambient_' + name + '.nim')
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(contents)
    run(name + '-compile', ['nix', 'develop', '--command', 'nim', 'c',
        '--hints:off', '--cc:clang', '--threads:on',
        '--out:' + str(evidence / name), str(fixture)])
clean = {k: v for k, v in os.environ.items()
         if not k.startswith('REPRO_MONITOR_') and k != 'DYLD_INSERT_LIBRARIES'}
for repetition in range(1, 3):
    for name in ['original', 'corrected']:
        run(f'{name}-{repetition}', ['nix', 'develop', '--command',
            str(evidence / name)], env=clean, required=(name == 'corrected'))
