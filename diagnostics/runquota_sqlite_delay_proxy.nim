## Real SQLite proxy: delay writes to a read-only file, preserve SQL/results.
import std/[os, strutils]
import runquota_core/child_process

let input = stdin.readAll()
let arguments = commandLineParams()
let realSqlite = getEnv("RUNQUOTA_REAL_SQLITE")
doAssert realSqlite.len > 0
if arguments.len > 0:
  let database = arguments[^1]
  if fileExists(database) and fpUserWrite notin getFilePermissions(database) and
      input.toLowerAscii().contains("insert"):
    let delay = parseInt(getEnv("RUNQUOTA_SQLITE_DELAY_MS", "0"))
    if delay > 0:
      let folder = getEnv("RUNQUOTA_SQLITE_DELAY_RECORDS")
      doAssert folder.len > 0
      writeFile(folder / ($getCurrentProcessId() & ".sql"), input)
      sleep(delay)
let captured = runCapturedProcess(realSqlite, args = arguments, input = input)
stdout.write(captured.output)
stderr.write(captured.error)
if captured.failure.len > 0:
  stderr.writeLine(captured.failure)
  quit 1
quit captured.exitCode
