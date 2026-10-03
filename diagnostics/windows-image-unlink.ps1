# Real kernel handles and image mappings; no mocks. Only remove private copies
# created by this probe. Never close another process's handles or change services.
$ErrorActionPreference = 'Stop'
$evidence = Join-Path $PWD 'unlink-evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ImageUnlinkProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetFileInformationByHandle(IntPtr file, int kind,
        ref uint flags, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CreateFileMappingW(IntPtr file, IntPtr security,
        uint protection, uint high, uint low, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr MapViewOfFile(IntPtr mapping, uint access,
        uint high, uint low, UIntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool UnmapViewOfFile(IntPtr view);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool DeleteFileW(string path);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@

function Invoke-PosixUnlink([string]$Path) {
    # DELETE, all sharing, OPEN_EXISTING, OPEN_REPARSE_POINT. Do not bypass ACLs.
    $handle = [ImageUnlinkProbe]::CreateFileW($Path, 0x10000, 7,
        [IntPtr]::Zero, 3, 0x200000, [IntPtr]::Zero)
    $openError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($handle -eq [IntPtr](-1)) {
        return @{opened=$false; error=$openError; removed=$false; exists=(Test-Path $Path)}
    }
    try {
        [uint32]$flags = 3 # FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS
        $removed = [ImageUnlinkProbe]::SetFileInformationByHandle($handle, 21, [ref]$flags, 4)
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    } finally {
        if (-not [ImageUnlinkProbe]::CloseHandle($handle)) { throw 'Delete handle did not close' }
    }
    return @{opened=$true; error=$(if ($removed) {0} else {$errorCode}); removed=$removed; exists=(Test-Path $Path)}
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('io-mon-unlink-' + [guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$results = @()
try {
    $plain = Join-Path $root 'plain.txt'
    [IO.File]::WriteAllText($plain, 'unlink-positive-control')
    $plainResult = Invoke-PosixUnlink $plain
    $results += @{case='plain-control'; result=$plainResult}
    if (-not $plainResult.removed -or $plainResult.exists) { throw 'Unlink positive control failed' }

    $denied = Join-Path $root 'deny-delete.txt'
    [IO.File]::WriteAllText($denied, 'unlink-denial-control')
    $held = [ImageUnlinkProbe]::CreateFileW($denied, 0x80000000, 1,
        [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($held -eq [IntPtr](-1)) { throw 'Cannot open denial control' }
    try {
        $deniedResult = Invoke-PosixUnlink $denied
        $results += @{case='deny-delete-control'; result=$deniedResult}
        if ($deniedResult.removed -or -not $deniedResult.exists) { throw 'Unlink bypassed sharing denial' }
    } finally { [void][ImageUnlinkProbe]::CloseHandle($held) }
    $releasedResult = Invoke-PosixUnlink $denied
    $results += @{case='closed-handle-control'; result=$releasedResult}
    if (-not $releasedResult.removed -or $releasedResult.exists) { throw 'Closed control remains' }

    # A real SEC_IMAGE mapping has the same filesystem deletion constraint as
    # a loaded image, without running or terminating a process.
    $image = Join-Path $root 'private-image.exe'
    Copy-Item $env:ComSpec $image
    $imageFile = [ImageUnlinkProbe]::CreateFileW($image, 0x80000000, 7,
        [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($imageFile -eq [IntPtr](-1)) { throw 'Cannot open private image' }
    $mapping = [IntPtr]::Zero
    $view = [IntPtr]::Zero
    try {
        $mapping = [ImageUnlinkProbe]::CreateFileMappingW($imageFile, [IntPtr]::Zero,
            0x1000002, 0, 0, $null) # SEC_IMAGE | PAGE_READONLY
        if ($mapping -eq [IntPtr]::Zero) { throw 'Cannot create real image section' }
        $view = [ImageUnlinkProbe]::MapViewOfFile($mapping, 4, 0, 0, [UIntPtr]::Zero)
        if ($view -eq [IntPtr]::Zero) { throw 'Cannot map real image section' }
        $ordinary = [ImageUnlinkProbe]::DeleteFileW($image)
        $ordinaryError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $results += @{case='mapped-image-DeleteFile'; removed=$ordinary; error=$ordinaryError; exists=(Test-Path $image)}
        if (-not $ordinary) {
            $results += @{case='mapped-image-posix'; result=(Invoke-PosixUnlink $image)}
        }
    } finally {
        if ($view -ne [IntPtr]::Zero) { [void][ImageUnlinkProbe]::UnmapViewOfFile($view) }
        if ($mapping -ne [IntPtr]::Zero) { [void][ImageUnlinkProbe]::CloseHandle($mapping) }
        [void][ImageUnlinkProbe]::CloseHandle($imageFile)
    }
    if (Test-Path $image) {
        $unmappedResult = Invoke-PosixUnlink $image
        $results += @{case='unmapped-image-control'; result=$unmappedResult}
        if (-not $unmappedResult.removed -or $unmappedResult.exists) { throw 'Unmapped image remains' }
    }
} finally {
    $results | ConvertTo-Json -Depth 6 | Set-Content "$evidence/results.json"
    $results | ConvertTo-Json -Depth 6 | Write-Output
    [Environment]::OSVersion | Format-List | Out-File "$evidence/host.txt"
    Remove-Item -LiteralPath $root -Recurse -Force
}
