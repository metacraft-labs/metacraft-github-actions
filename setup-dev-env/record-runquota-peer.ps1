# Observe one existing endpoint; never start, retire, repair or reconfigure it.
# Kernel identity and an on-disk file hash do not attest loaded memory or leases.
$ErrorActionPreference = 'Stop'
if (-not ('RunQuotaPeerReceipt' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class RunQuotaPeerReceipt {
    // https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32", SetLastError=true)]
    static extern bool GetNamedPipeServerProcessId(SafeFileHandle pipe, out uint pid);
    [DllImport("kernel32", SetLastError=true)]
    static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32", SetLastError=true)]
    static extern bool GetProcessTimes(SafeProcessHandle process, out long creation,
        out long exit, out long kernel, out long user);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool QueryFullProcessImageNameW(SafeProcessHandle process,
        uint flags, StringBuilder image, ref uint length);
    [DllImport("kernel32", SetLastError=true)]
    static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint code);

    static void Require(bool ok) {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    static void Alive(SafeProcessHandle process) {
        uint code;
        Require(GetExitCodeProcess(process, out code));
        if (code != 259) throw new InvalidOperationException("endpoint server exited");
    }

    public static string Endpoint(string socket) {
        if (String.IsNullOrEmpty(socket)) return @"\\.\pipe\runquota\runquotad";
        if (socket.StartsWith(@"\\.\pipe\", StringComparison.Ordinal) ||
            socket.StartsWith(@"\\?\pipe\", StringComparison.Ordinal)) return socket;
        // Match runquota_ipc.endpointForPath: UTF-8 bytes, ASCII folding only,
        // FNV-1a uint64 wrap and uppercase hex; no slash normalization.
        ulong token = 0xcbf29ce484222325UL;
        foreach (byte raw in Encoding.UTF8.GetBytes(socket)) {
            byte folded = raw >= 65 && raw <= 90 ? (byte)(raw + 32) : raw;
            token = unchecked((token ^ folded) * 0x100000001b3UL);
        }
        return @"\\.\pipe\runquota-" + token.ToString("X16");
    }

    public sealed class Identity {
        public string state = "observed";
        public string endpoint;
        public uint serverPID;
        public long creationFILETIME;
        public string imagePath;
        public string imageFileSHA256;
    }

    public static Identity Observe(string endpoint) {
        // Open existing pipe once, without waiting/retrying or protocol traffic.
        // Both handles stay alive across hashing and the final identity checks.
        using (var pipe = CreateFileW(endpoint, 0xc0000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (pipe.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint pid;
            Require(GetNamedPipeServerProcessId(pipe, out pid));
            using (var process = OpenProcess(0x1000, false, pid)) {
                if (process.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                Alive(process);
                long birth, exit, kernel, user;
                Require(GetProcessTimes(process, out birth, out exit, out kernel, out user));
                uint length = 32768;
                var image = new StringBuilder((int)length);
                Require(QueryFullProcessImageNameW(process, 0, image, ref length));
                string path = image.ToString();
                string digest;
                // A retained file handle excludes writes/replacement during this
                // file observation. It is still not a mapped-memory hash.
                using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (var hash = SHA256.Create()) {
                    digest = BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
                    uint finalPid;
                    Require(GetNamedPipeServerProcessId(pipe, out finalPid));
                    Alive(process);
                    long finalBirth;
                    Require(GetProcessTimes(process, out finalBirth, out exit, out kernel, out user));
                    var finalImage = new StringBuilder(32768);
                    length = 32768;
                    Require(QueryFullProcessImageNameW(process, 0, finalImage, ref length));
                    if (finalPid != pid || finalBirth != birth || finalImage.ToString() != path)
                        throw new InvalidOperationException("endpoint server identity changed");
                }
                return new Identity { endpoint=endpoint, serverPID=pid,
                    creationFILETIME=birth, imagePath=path, imageFileSHA256=digest };
            }
        }
    }
}
'@
}

function Get-RunQuotaEndpointReceipt([string] $Socket) {
    $endpoint = [RunQuotaPeerReceipt]::Endpoint($Socket)
    try {
        [RunQuotaPeerReceipt]::Observe($endpoint)
    } catch {
        $cause = $_.Exception.GetBaseException()
        # A failed query is missing evidence, never permission to repair or to
        # attribute an installed candidate to the endpoint.
        [pscustomobject]@{
            state = 'unknown'
            endpoint = $endpoint
            errorType = $cause.GetType().Name
            nativeError = $(if ($cause -is [ComponentModel.Win32Exception]) { $cause.NativeErrorCode } else { $null })
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $receipt = Get-RunQuotaEndpointReceipt $env:RUNQUOTA_SOCKET
    'setup-dev-env: runquota-endpoint-receipt v1 ' + ($receipt | ConvertTo-Json -Compress)
}
