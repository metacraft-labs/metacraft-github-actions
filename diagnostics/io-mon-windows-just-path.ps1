# No mocks: exercise the native Justfile, compiler, shim, and source checkouts.
# The old-recipe arm must fail while the repaired recipe builds real payloads.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-just-path'
New-Item -ItemType Directory -Force $evidence | Out-Null
$dependency = @()
foreach ($name in @('STACKABLE_HOOKS_SRC','SHM_QUEUE_SRC','SHM_GSET_SRC')) {
    $source = [Environment]::GetEnvironmentVariable($name)
    $revision = if ($source -and (Test-Path $source)) { (& git -C $source rev-parse HEAD).Trim() } else { 'missing' }
    $dependency += @{variable=$name; path=$source; revision=$revision}
}
$dependency | ConvertTo-Json | Set-Content "$evidence/source-roots.json"
Get-Content "$evidence/source-roots.json"
$oldRecipe = Join-Path $PWD 'Justfile.before-path-quoting'
& git show 9529c44cc18c4f86135ec450fd1fbac35d1d6356:Justfile | Set-Content $oldRecipe
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the old Justfile' }
& dev-exec just --justfile $oldRecipe --working-directory $PWD build-shim *> "$evidence/old.log"
$oldCode = $LASTEXITCODE
if ($oldCode -eq 0) { throw 'Old Windows backslash-path control unexpectedly passed' }
Write-Host "Old Windows recipe exit=$oldCode"
Get-Content "$evidence/old.log" -Tail 10
& dev-exec just build *> "$evidence/fixed.log"
$fixedCode = $LASTEXITCODE
Write-Host "Repaired Windows recipe exit=$fixedCode"
Get-Content "$evidence/fixed.log" -Tail 15
@{oldExit=$oldCode; fixedExit=$fixedCode} | ConvertTo-Json | Set-Content "$evidence/results.json"
if ($fixedCode -ne 0) { throw 'Repaired native build failed' }
