# Print the top-level fields of a tool pin (pins/pin.schema.json) that
# resolve-reprobuild-pin.sh uses, as key=value lines.
#
# The Windows reader for that script: the pin is parsed with ConvertFrom-Json
# rather than with Git Bash text matching. The caller validates the values.
param(
  [Parameter(Mandatory = $true)][string]$Path
)
$ErrorActionPreference = 'Stop'

$pin = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
if ($pin -isnot [System.Management.Automation.PSCustomObject]) {
  throw "${Path}: a pin is a JSON object"
}
foreach ($name in @('schema', 'owner', 'repo', 'rev', 'version', 'kind')) {
  $property = $pin.PSObject.Properties[$name]
  if ($null -eq $property) { continue }
  $value = $property.Value
  if ($name -eq 'schema') {
    if ($value -isnot [long] -and $value -isnot [int]) {
      throw "${Path}: field 'schema' is not an integer"
    }
  } elseif ($value -isnot [string]) {
    throw "${Path}: field '$name' is not a string"
  }
  if ("$value" -match "[`r`n]") {
    throw "${Path}: field '$name' spans lines"
  }
  Write-Output "$name=$value"
}
