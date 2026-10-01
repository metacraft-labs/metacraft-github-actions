# Read actual Windows ACLs independently of RunQuota. No mocked security data.
param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$OutputFile
)
$ErrorActionPreference = 'Stop'
# This script runs in the explicitly selected Windows PowerShell, while its
# caller can supply PowerShell 7's module path. Use this host's own modules for
# JSON conversion and read the DACL directly through the .NET Framework API.
$env:PSModulePath = [System.IO.Path]::Combine($PSHOME, 'Modules')
$acl = [System.IO.Directory]::GetAccessControl($Directory)
$rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
    [ordered]@{
        sid = $_.IdentityReference.Value
        type = $_.AccessControlType.ToString()
        rights = $_.FileSystemRights.ToString()
        inherited = $_.IsInherited
        inheritanceFlags = $_.InheritanceFlags.ToString()
    }
})
$result = [ordered]@{
    directory = $Directory
    owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    account = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    protected = $acl.AreAccessRulesProtected
    sddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
    entries = $rules
}
[System.IO.File]::WriteAllText($OutputFile, ($result | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
