<#
.SYNOPSIS
    Disable / enable / delete Conditional Access policies by name pattern.

.DESCRIPTION
    Uses the Microsoft Graph PowerShell SDK, which (unlike the Azure CLI) can be granted
    the Policy.ReadWrite.ConditionalAccess delegated scope needed to modify CA policies.

    Requires the Microsoft.Graph.Identity.SignIns module:
        Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser

    Nothing is changed unless -Apply is supplied. Matched policies are always backed up
    to ./ca_policy_backups/ before any modification.

.EXAMPLE
    ./ca_policy_toggle.ps1 -Action list
    ./ca_policy_toggle.ps1 -Action disable            # dry run
    ./ca_policy_toggle.ps1 -Action disable -Apply
    ./ca_policy_toggle.ps1 -Action enable  -Apply
    ./ca_policy_toggle.ps1 -Action delete  -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('list', 'disable', 'enable', 'delete')]
    [string]$Action,

    # Name substrings matched case-insensitively against policy DisplayName.
    [string[]]$Pattern = @('security info registration', 'multifactor authentication'),

    [switch]$Apply,

    # Use device-code auth instead of the browser (for headless/remote sessions).
    [switch]$DeviceCode
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Identity.SignIns

# Read-only actions do not need the write scope, which keeps the consent prompt minimal.
$scopes = if ($Action -eq 'list') { @('Policy.Read.All') } else { @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess') }

$context = Get-MgContext
if (-not $context -or ($scopes | Where-Object { $_ -notin $context.Scopes })) {
    # Output must not be suppressed here or the device-code prompt is hidden.
    if ($DeviceCode) {
        Connect-MgGraph -Scopes $scopes -UseDeviceCode
    }
    else {
        Connect-MgGraph -Scopes $scopes
    }

    if (-not (Get-MgContext)) {
        throw "Sign-in did not complete - no Graph context established. Re-run and finish the prompt, or use -DeviceCode."
    }
}

$all = Get-MgIdentityConditionalAccessPolicy
$targets = $all | Where-Object {
    $name = $_.DisplayName
    $Pattern | Where-Object { $name -like "*$_*" }
}

if (-not $targets) {
    Write-Host "No policies matched: $($Pattern -join ', ')"
    return
}

Write-Host "Matched $(@($targets).Count) of $(@($all).Count) policies:"
foreach ($p in $targets) {
    Write-Host ("  - '{0}'  state={1}  id={2}" -f $p.DisplayName, $p.State, $p.Id)
}

if ($Action -eq 'list') { return }

if (-not $Apply) {
    Write-Host "`nDRY RUN - would $Action the policies above. Re-run with -Apply to execute."
    return
}

$backupDir = Join-Path $PSScriptRoot 'ca_policy_backups'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backupPath = Join-Path $backupDir ("ca_policies_{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
$targets | ConvertTo-Json -Depth 20 | Set-Content -Path $backupPath
Write-Host "`nBacked up current definitions to $backupPath"

$failures = 0
foreach ($p in $targets) {
    try {
        if ($Action -eq 'delete') {
            Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id
        }
        else {
            $state = if ($Action -eq 'disable') { 'disabled' } else { 'enabled' }
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State $state
        }
        Write-Host ("  OK   {0}d '{1}'" -f $Action, $p.DisplayName)
    }
    catch {
        $failures++
        Write-Warning ("  FAIL '{0}': {1}" -f $p.DisplayName, $_.Exception.Message)
    }
}

if ($failures) {
    Write-Warning "$failures operation(s) failed. Microsoft-managed policies often cannot be deleted - try 'disable' instead."
    exit 1
}
