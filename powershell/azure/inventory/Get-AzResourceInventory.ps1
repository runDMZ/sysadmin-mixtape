#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Lists every Azure resource of one or more subscriptions, with its tags.

.DESCRIPTION
    Read-only. For each subscription, returns one object per resource: subscription,
    resource group, name, type, location, tags and resource ID. Useful as a starting
    point for an audit, a migration or a cost review.

    Required role: Reader on the subscriptions.

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: every enabled subscription of the current tenant.

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    ./Get-AzResourceInventory.ps1 | Group-Object Type | Sort-Object Count -Descending

    Counts resources by type across all subscriptions.

.EXAMPLE
    ./Get-AzResourceInventory.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -OutputPath ./inventory.csv
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionId,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TargetSubscription {
    param([string[]] $Id)
    $context = Get-AzContext
    if (-not $context) { throw 'Not connected to Azure. Run Connect-AzAccount first.' }
    if ($Id) {
        foreach ($subId in $Id) { Get-AzSubscription -SubscriptionId $subId -TenantId $context.Tenant.Id }
    } else {
        Get-AzSubscription -TenantId $context.Tenant.Id | Where-Object State -EQ 'Enabled'
    }
}

function Format-Tag {
    param($Tags)
    if (-not $Tags -or $Tags.Count -eq 0) { return '' }
    ($Tags.GetEnumerator() | Sort-Object Key | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; '
}

$originalContext = Get-AzContext
$results = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($sub in Get-TargetSubscription -Id $SubscriptionId) {
        Write-Verbose "Subscription $($sub.Name) ($($sub.Id))"
        $null = Set-AzContext -Subscription $sub.Id
        foreach ($res in Get-AzResource) {
            $results.Add([pscustomobject]@{
                    SubscriptionName = $sub.Name
                    SubscriptionId   = $sub.Id
                    ResourceGroup    = $res.ResourceGroupName
                    Name             = $res.Name
                    Type             = $res.ResourceType
                    Location         = $res.Location
                    Tags             = Format-Tag $res.Tags
                    ResourceId       = $res.ResourceId
                })
        }
    }
} finally {
    if ($originalContext) { $null = Set-AzContext -Context $originalContext }
}

if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Written to $OutputPath"
}
$results
