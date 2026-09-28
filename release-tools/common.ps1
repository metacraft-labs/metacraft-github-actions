$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $env:RELEASE_TOOLS -or -not $env:RELEASE_CC -or -not $env:RELEASE_NIM) {
  throw 'Release compiler environment is missing; run setup-windows.ps1 first'
}
$ReleaseStage = Join-Path (Get-Location) "build/release/$Target"
if (Test-Path $ReleaseStage) { Remove-Item -Recurse -Force $ReleaseStage }
New-Item -ItemType Directory -Force "$ReleaseStage/bin", "$ReleaseStage/lib" | Out-Null
$ReleaseFlags = @('-d:release', '--threads:on', "--cpu:$env:RELEASE_NIM_CPU", '--cc:clang',
  "--clang.exe:$env:RELEASE_CC", "--clang.linkerexe:$env:RELEASE_CC")
function Get-ReleaseDependency([string]$InputName, [string]$Variable, [string]$Subdir = 'src') {
  $lock = Get-Content -Raw flake.lock | ConvertFrom-Json
  # Node keys are graph-internal: a transitive input can take the unsuffixed
  # name. Resolve the ROOT input edge before reading its locked revision.
  $nodeName = $lock.nodes.($lock.root).inputs.$InputName
  if ($nodeName -isnot [string]) { throw "Expected a directly pinned source input: $InputName" }
  $node = $lock.nodes.$nodeName.locked
  if (-not $node.rev -or $node.rev -notmatch '^[a-f0-9]{40}$') { throw "Unpinned dependency $InputName" }
  $destination = Join-Path (Get-Location) "build/release-deps/$InputName"
  if (Test-Path $destination) { Remove-Item -Recurse -Force $destination }
  $url = if ($node.type -eq 'github') { "https://github.com/$($node.owner)/$($node.repo).git" } else { $node.url }
  & git clone --quiet --no-checkout $url $destination
  if ($LASTEXITCODE -ne 0) { throw "Cannot fetch $InputName" }
  & git -C $destination checkout --quiet --detach $node.rev
  if ($LASTEXITCODE -ne 0) { throw "Cannot check out $InputName@$($node.rev)" }
  if ($node.PSObject.Properties['submodules'] -and $node.submodules) {
    & git -C $destination submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Cannot fetch submodules of $InputName" }
  }
  $source = if ($Subdir) { Join-Path $destination $Subdir } else { $destination }
  [Environment]::SetEnvironmentVariable($Variable, $source, 'Process')
}
function Invoke-ReleaseNim([string]$Module, [string]$Output, [string[]]$Extra = @()) {
  $cache = "build/nimcache/release-$Target-$([IO.Path]::GetFileNameWithoutExtension($Output))"
  & $env:RELEASE_NIM c @ReleaseFlags @Extra "--nimcache:$cache" "--out:$Output" $Module
  if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $Module" }
}
function Complete-Release {
  & $env:RELEASE_NODE "$env:RELEASE_TOOLS/payload.cjs" $ReleaseStage $Target
  if ($LASTEXITCODE -ne 0) { throw 'Payload verification failed' }
}
