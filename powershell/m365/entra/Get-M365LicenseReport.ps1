#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Shows, for each licence the tenant subscribes to, how many are bought, assigned and left.

.DESCRIPTION
    Read-only. One row per subscription (SKU): purchased, assigned, available, plus a status
    that says what to look at:
      - Unused: paid licences not assigned to anyone, money spent for nothing;
      - Full: none left, the next arrival will not get a licence;
      - OverAssigned: more assigned than active, usually after a subscription expired;
      - Expiring: subscription in warning or suspended state (not renewed);
      - Free: free or trial SKU with a very large number of units, ignore.
    Pair it with Get-M365InactiveUser.ps1 to find who holds licences they no longer use.

    Required: Connect-MgGraph -Scopes Organization.Read.All

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    Connect-MgGraph -Scopes Organization.Read.All
    ./Get-M365LicenseReport.ps1 | Format-Table Product, Purchased, Assigned, Available, Status
#>
[CmdletBinding()]
param(
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    throw 'Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes Organization.Read.All first.'
}

# Readable names for common SKUs. The full list is Microsoft's "Product names and service plan
# identifiers for licensing" page; unknown SKUs keep their part number.
$friendly = @{
    O365_BUSINESS_ESSENTIALS = 'Microsoft 365 Business Basic'
    O365_BUSINESS_PREMIUM    = 'Microsoft 365 Business Standard'
    SPB                      = 'Microsoft 365 Business Premium'
    SPE_E3                   = 'Microsoft 365 E3'
    SPE_E5                   = 'Microsoft 365 E5'
    ENTERPRISEPACK           = 'Office 365 E3'
    EXCHANGESTANDARD         = 'Exchange Online (Plan 1)'
    EMS                      = 'Enterprise Mobility + Security E3'
    AAD_PREMIUM              = 'Microsoft Entra ID P1'
    INTUNE_A                 = 'Microsoft Intune Plan 1'
    POWER_BI_STANDARD        = 'Power BI (free)'
    FLOW_FREE                = 'Power Automate (free)'
}

$results = foreach ($sku in Get-MgSubscribedSku -All) {
    $enabled = [int]$sku.PrepaidUnits.Enabled
    $warning = [int]$sku.PrepaidUnits.Warning
    $suspended = [int]$sku.PrepaidUnits.Suspended
    $assigned = [int]$sku.ConsumedUnits
    $available = $enabled - $assigned

    $status =
    if ($enabled -ge 10000) { 'Free' }
    elseif ($sku.CapabilityStatus -ne 'Enabled' -or $warning -gt 0 -or $suspended -gt 0) { 'Expiring' }
    elseif ($available -lt 0) { 'OverAssigned' }
    elseif ($available -eq 0) { 'Full' }
    else { 'Unused' }

    [pscustomobject]@{
        Product       = if ($friendly.ContainsKey($sku.SkuPartNumber)) { $friendly[$sku.SkuPartNumber] } else { $sku.SkuPartNumber }
        SkuPartNumber = $sku.SkuPartNumber
        Purchased     = $enabled
        Assigned      = $assigned
        Available     = $available
        InWarning     = $warning
        Suspended     = $suspended
        Status        = $status
        SkuId         = $sku.SkuId
    }
}
$results = @($results | Sort-Object @{ Expression = { $_.Status -eq 'Free' } }, Product)

if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Written to $OutputPath"
}
$results
