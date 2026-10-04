$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = $PWD.Path
$hooks = Join-Path $root '.hooks'
$evidence = Join-Path $root 'test-logs/hook-pages'
New-Item -ItemType Directory -Force $evidence | Out-Null
$candidate = '10ed82a4bc5bd8c5fccbbe3f3aaaed53ef7d6485'
$baseline = 'b19728194e9f6a939e761befa3b9d7b1b638b962'
if ((& git -C $hooks rev-parse HEAD).Trim() -ne $candidate) { throw 'Unexpected hook candidate' }
$relative = 'src/stackable_hooks/inline_hook/windows/install_windows.c'
$installer = Join-Path $hooks $relative
$original = [IO.File]::ReadAllBytes($installer)
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'No Visual C++ toolchain found' }
$vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvarsall.bat'
"Runner $env:RUNNER_OS $env:RUNNER_ARCH; candidate $candidate; baseline $baseline; workflow $(& git rev-parse HEAD)" > "$evidence/source.txt"
try {
    foreach ($variant in @('baseline', 'candidate')) {
        if ($variant -eq 'baseline') {
            & python -c 'import pathlib,subprocess,sys; pathlib.Path(sys.argv[1],sys.argv[3]).write_bytes(subprocess.check_output(["git","-C",sys.argv[1],"show",sys.argv[2]+":"+sys.argv[3]]))' $hooks $baseline $relative
            if ($LASTEXITCODE -ne 0) { throw 'Cannot recover baseline installer' }
        } else { [IO.File]::WriteAllBytes($installer, $original) }
        foreach ($arch in @('x64', 'x86')) {
            $out = Join-Path $evidence "$variant-$arch"
            New-Item -ItemType Directory -Force $out | Out-Null
            $binary = Join-Path $out 'hook-pages.exe'
            $batch = Join-Path $out 'compile.cmd'
            $backend = Join-Path $hooks 'src/stackable_hooks/inline_hook/windows'
            $fixture = Join-Path $hooks 'tests/fixtures/windows_hook_page_preparation.c'
            Get-FileHash $installer, $fixture, "$backend/length_decoder.c", "$backend/rel32_fixup.c" -Algorithm SHA256 | Format-List > "$out/sources-sha256.txt"
            @"
@echo off
call "$vcvars" $arch
if errorlevel 1 exit /b 1
cl /nologo /std:c11 /W3 /DCT_TEST_STANDALONE /D_CRT_SECURE_NO_WARNINGS /I"$backend" "$fixture" "$backend/length_decoder.c" "$backend/rel32_fixup.c" /Fe:"$binary" /Fo:"$out/" /link kernel32.lib
exit /b %errorlevel%
"@ | Set-Content $batch -Encoding ascii
            & cmd /d /c $batch *> "$out/build.log"
            if ($LASTEXITCODE -ne 0) { Get-Content "$out/build.log"; throw "$variant $arch did not compile" }
            Get-FileHash $binary -Algorithm SHA256 | Format-List > "$out/binary-sha256.txt"
            $process = Start-Process $binary -ArgumentList $env:RUNNER_ARCH -PassThru -NoNewWindow -RedirectStandardOutput "$out/stdout.log" -RedirectStandardError "$out/stderr.log"
            if (-not $process.WaitForExit(30000)) {
                $process.Kill()
                $process.WaitForExit()
                throw "$variant $arch exceeded the unchanged 30-second fixture bound"
            }
            $process.WaitForExit()
            $output = Get-Content "$out/stdout.log" -Raw
            $output
            Get-Content "$out/stderr.log"
            $expectedExit = if ($variant -eq 'baseline') { 71 } else { 0 }
            $code = $process.ExitCode
            "exit=$code expected=$expectedExit" > "$out/result.txt"
            if ($code -ne $expectedExit -or $output -notmatch 'real target, trampoline, peer and protection checks passed') {
                throw "$variant $arch failed the real functional checks: exit $code"
            }
            $rounds = [regex]::Matches($output, 'round=([01]) real-protection-calls=(\d+) expected=72')
            if ($rounds.Count -ne 2 -or $rounds[0].Groups[1].Value -ne '0' -or $rounds[1].Groups[1].Value -ne '1') { throw 'Missing repeated-transaction evidence' }
            foreach ($round in $rounds) {
                $calls = [int]$round.Groups[2].Value
                if (($variant -eq 'baseline' -and $calls -le 72) -or ($variant -eq 'candidate' -and $calls -ne 72)) { throw 'Page preparation control did not discriminate the candidate' }
            }
        }
    }
} finally { [IO.File]::WriteAllBytes($installer, $original) }
