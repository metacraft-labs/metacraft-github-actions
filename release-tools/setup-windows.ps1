# Shared, checksum-pinned Nim and LLVM-MinGW environment for release builds.
# Nim's x64 compiler also runs under Windows ARM64 emulation; the C compiler
# and the resulting PE machine type are selected explicitly for the target.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$target = $env:RELEASE_TARGET
if ($target -notin @('windows-x86_64', 'windows-aarch64')) { throw "Invalid Windows target $target" }
$hostArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($target -eq 'windows-aarch64' -and $hostArch -ne 'Arm64') { throw 'ARM64 releases must be tested on an ARM64 host' }
$arch = if ($target -eq 'windows-aarch64') { 'aarch64' } else { 'x86_64' }
$llvmHash = if ($arch -eq 'aarch64') {
  'a317514a7a63badd692032c0c2b8e165f630bbaebbe7a3254348051f43a64949'
} else {
  'e3ad77d117a4bea19a7a3b333341824d79a5a371004a10e25b8504e7b3047666'
}
$root = Join-Path $env:RUNNER_TEMP 'release-toolchain'
New-Item -ItemType Directory -Force $root | Out-Null
function Get-VerifiedZip([string]$Name, [string]$Url, [string]$Hash) {
  $archive = Join-Path $root "$Name.zip"
  Invoke-WebRequest -Uri $Url -OutFile $archive
  if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
    throw "Checksum mismatch: $Name"
  }
  Expand-Archive -LiteralPath $archive -DestinationPath $root -Force
}
Get-VerifiedZip 'nim' 'https://nim-lang.org/download/nim-2.2.8_x64.zip' '11fe2415a64a791b899cc78e2eeacdde93b5f122f2fabc447db36d38002bfb8c'
Get-VerifiedZip 'llvm' "https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-$arch.zip" $llvmHash
$nim = Join-Path $root 'nim-2.2.8/bin'
$llvm = Join-Path $root "llvm-mingw-20260922-ucrt-$arch/bin"
foreach ($dir in @($nim, $llvm)) {
  if (-not (Test-Path -LiteralPath $dir)) { throw "Missing toolchain directory $dir" }
  Add-Content -LiteralPath $env:GITHUB_PATH -Value $dir
}
$compiler = Join-Path $llvm "$arch-w64-mingw32-clang.exe"
if (-not (Test-Path -LiteralPath $compiler)) { throw "Missing target compiler $compiler" }
Add-Content -LiteralPath $env:GITHUB_ENV -Value "RELEASE_CC=$compiler"
Add-Content -LiteralPath $env:GITHUB_ENV -Value "RELEASE_NIM=$(Join-Path $nim 'nim.exe')"
Add-Content -LiteralPath $env:GITHUB_ENV -Value "RELEASE_NIM_CPU=$(if ($arch -eq 'aarch64') { 'arm64' } else { 'amd64' })"
