# Add timestamp-only diagnostics to the real server. Caller saves/restores bytes.
param([string]$Server)
$source = [IO.File]::ReadAllText($Server).Replace("`r`n", "`n")
function Replace-Once([string]$Before, [string]$After) {
    if ([regex]::Matches($script:source, [regex]::Escape($Before)).Count -ne 1) {
        throw "Server profiling anchor changed: $Before"
    }
    $script:source = $script:source.Replace($Before, $After)
}
function Stamp([string]$Phase, [string]$Indent = '  ') {
    return $Indent + 'stderr.writeLine("serve-profile slot=" & $slot & " phase=' + $Phase + ' seconds=" & $(epochTime() - profileStart))'
}
Replace-Once "  var p: Process`n  try:" ("  let profileStart = epochTime()`n" + (Stamp 'before-spawn') + "`n  var p: Process`n  try:")
Replace-Once '                     options = WorkerSpawnOptions)' ('                     options = WorkerSpawnOptions)' + "`n" + (Stamp 'after-spawn' '    '))
Replace-Once '    while outStream.readLine(line):' ("    var profileFirstOutput = true`n    while outStream.readLine(line):`n      if profileFirstOutput:`n        profileFirstOutput = false`n" + (Stamp 'first-output' '        '))
Replace-Once '    code = p.waitForExit()' ((Stamp 'output-eof' '    ') + "`n    code = p.waitForExit()`n" + (Stamp 'reaped' '    '))
Replace-Once '    releaseWorkerStdio(p)' ('    releaseWorkerStdio(p)' + "`n" + (Stamp 'stdio-released' '    '))
Replace-Once '  # The worker is reaped and every one of its fds is closed: only now may the' ((Stamp 'before-terminal-event') + "`n  # The worker is reaped and every one of its fds is closed: only now may the")
[IO.File]::WriteAllText($Server, $source, (New-Object Text.UTF8Encoding($false)))
