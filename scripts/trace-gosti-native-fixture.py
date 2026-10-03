"""Add diagnostics to ae5cbfb without changing fixture assertions or execution."""
from pathlib import Path

helper = Path("tests/native_command_fixture.nim")
source = helper.read_text()
marker = 'const FixtureSuffix = ".vmh-command.json"\n'
assert source.count(marker) == 1
source = source.replace(marker, marker + r'''
proc fixtureTrace(event, path, data: string) =
  let target = getEnv("GOSTI_COMMAND_FIXTURE_TRACE")
  if target.len > 0:
    let output = open(target, fmAppend)
    output.writeLine($ %*{"pid": getCurrentProcessId(), "event": event,
      "app": getAppFilename(), "temp": getTempDir(), "path": path,
      "data": data})
    output.close()
''')
marker = '  writeFile(result & FixtureSuffix, $config)\n'
assert source.count(marker) == 1
source = source.replace(marker, marker +
    '  fixtureTrace("wrote", result & FixtureSuffix, readFile(result & FixtureSuffix))\n')
marker = '  let cfg = parseFile(fixtureConfigPath)\n'
assert source.count(marker) == 1
source = source.replace(marker, marker +
    '  fixtureTrace("read", fixtureConfigPath, $cfg)\n')
helper.write_text(source)

test = Path("tests/unit/t_linux_runner_recipe_pin.nim")
source = test.read_text()
marker = '  writeFile(file, script)\n'
assert source.count(marker) == 1
source = source.replace(marker, r'''  let trace = getEnv("GOSTI_COMMAND_FIXTURE_TRACE")
  let traceCommand = if trace.len > 0 and path.len > 0:
    "{ echo BASH_CURL_RESOLUTION; type -a curl; } >> " &
      quoteShell(trace.replace('\\', '/')) & " 2>&1\n"
    else: ""
  writeFile(file, traceCommand & script)
''')
test.write_text(source)
