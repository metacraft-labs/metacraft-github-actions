# Read actual Windows ACLs independently of RunQuota. No mocked security data.
param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$OutputFile
)
$ErrorActionPreference = 'Stop'
$acl = Get-Acl -LiteralPath $Directory
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
    sddl = $acl.Sddl
    entries = $rules
}
[System.IO.File]::WriteAllText($OutputFile, ($result | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
