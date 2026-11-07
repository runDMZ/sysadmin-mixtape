#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Finds accounts nobody uses any more: inactive, never signed in, or disabled but still licensed.

.DESCRIPTION
    Read-only. Three kinds of accounts cost money or widen the attack surface for nothing:
      - Inactive: no successful sign-in for -DaysInactive days (default 90);
      - NeverSignedIn: created more than -DaysInactive days ago and never used;
      - DisabledLicensed: disabled (often a departure) but still holding licences.
    Each row gives the reason, the last sign-in, the licences held and whether the account is
    synchronised from on-premises Active Directory (then fix it there, not in the cloud).

    The last sign-in is lastSuccessfulSignInDateTime when available, otherwise the most recent
    of the interactive and non-interactive sign-ins.

    Required: Connect-MgGraph -Scopes User.Read.All, AuditLog.Read.All, Organization.Read.All
    The tenant needs at least one Entra ID P1 licence (included in Microsoft 365 Business
    Premium, E3, E5) for Graph to return sign-in activity.

.PARAMETER DaysInactive
    Number of days without a successful sign-in after which an account is reported. Default 90.

.PARAMETER IncludeGuests
    Also report guest accounts (excluded by default: review them with access reviews).

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    Connect-MgGraph -Scopes User.Read.All, AuditLog.Read.All, Organization.Read.All
    ./Get-M365InactiveUser.ps1 | Format-Table Reason, UserPrincipalName, LastSignIn, DaysSinceSignIn, Licenses

.EXAMPLE
    # What could be freed today: licences held by disabled or long-inactive accounts
    ./Get-M365InactiveUser.ps1 -DaysInactive 180 | Where-Object Licenses | Group-Object Reason
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int] $DaysInactive = 90,
    [switch] $IncludeGuests,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    throw 'Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes User.Read.All, AuditLog.Read.All, Organization.Read.All first.'
}

$now = [datetime]::UtcNow
$cutoff = $now.AddDays(-$DaysInactive)

# SKU ID -> readable part number (e.g. SPB, O365_BUSINESS_PREMIUM)
$skuNames = @{}
foreach ($sku in Get-MgSubscribedSku -All) { $skuNames[[string]$sku.SkuId] = $sku.SkuPartNumber }

$properties = 'id', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType', 'createdDateTime',
'assignedLicenses', 'onPremisesSyncEnabled', 'signInActivity'
$users = @(Get-MgUser -All -Property $properties)
Write-Verbose "$($users.Count) account(s) read"

function Get-LastSignIn {
    param($Activity)
    if (-not $Activity) { return $null }
    if ($Activity.LastSuccessfulSignInDateTime) { return $Activity.LastSuccessfulSignInDateTime }
    $dates = @($Activity.LastSignInDateTime, $Activity.LastNonInteractiveSignInDateTime) | Where-Object { $_ }
    if ($dates) { return ($dates | Sort-Object -Descending)[0] }
    $null
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($user in $users) {
    if ($user.UserType -eq 'Guest' -and -not $IncludeGuests) { continue }

    $last = Get-LastSignIn $user.SignInActivity
    $licenses = @($user.AssignedLicenses | ForEach-Object {
            $id = [string]$_.SkuId
            if ($skuNames.ContainsKey($id)) { $skuNames[$id] } else { $id }
        })

    $reason = $null
    if (-not $user.AccountEnabled) {
        if ($licenses.Count) { $reason = 'DisabledLicensed' }
    }
    elseif (-not $last) {
        if ($user.CreatedDateTime -and $user.CreatedDateTime -lt $cutoff) { $reason = 'NeverSignedIn' }
    }
    elseif ($last -lt $cutoff) {
        $reason = 'Inactive'
    }
    if (-not $reason) { continue }

    $results.Add([pscustomobject]@{
            Reason            = $reason
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            UserType          = $user.UserType
            Enabled           = $user.AccountEnabled
            LastSignIn        = $last
            DaysSinceSignIn   = if ($last) { [int]($now - $last.ToUniversalTime()).TotalDays } else { $null }
            Created           = $user.CreatedDateTime
            Licenses          = $licenses -join ', '
            SyncedFromAD      = [bool]$user.OnPremisesSyncEnabled
            Id                = $user.Id
        })
}

if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Written to $OutputPath"
}
$results
