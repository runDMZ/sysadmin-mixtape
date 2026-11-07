#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Lists resources and resource groups that miss required tags.

.DESCRIPTION
    Read-only. Tags are what makes costs attributable and owners findable: this script
    reports, for each resource (and each resource group with -IncludeResourceGroup),
    the required tags that are missing or empty. Tag names are compared without case,
    as Azure does.

    A summary (compliance percentage) is written to the verbose stream: add -Verbose.

    Required role: Reader on the subscriptions.

.PARAMETER RequiredTag
    Tag names every resource must carry, e.g. Owner, Environment, CostCenter.

.PARAMETER IncludeResourceGroup
    Also check the resource groups themselves.

.PARAMETER ExcludeResourceType
    Resource types to skip, e.g. Microsoft.Network/networkWatchers.

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: every enabled subscription of the current tenant.

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    ./Test-AzTagCompliance.ps1 -RequiredTag Owner, Environment -IncludeResourceGroup -Verbose
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $RequiredTag,
    [switch] $IncludeResourceGroup,
    [string[]] $ExcludeResourceType = @(),
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

function Get-MissingTag {
    # Required tag names absent or empty in a tag collection (case-insensitive)
    param($Tags, [string[]] $Required)
    $present = @{}
    if ($Tags) {
        foreach ($entry in $Tags.GetEnumerator()) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) { $present[$entry.Key.ToLowerInvariant()] = $true }
        }
    }
    @($Required | Where-Object { -not $present.ContainsKey($_.ToLowerInvariant()) })
}

$originalContext = Get-AzContext
$results = [System.Collections.Generic.List[object]]::new()
$checked = 0
try {
    foreach ($sub in Get-TargetSubscription -Id $SubscriptionId) {
        Write-Verbose "Subscription $($sub.Name) ($($sub.Id))"
        $null = Set-AzContext -Subscription $sub.Id

        $targets = @(Get-AzResource | Where-Object { $_.ResourceType -notin $ExcludeResourceType } | ForEach-Object {
                @{ Kind = 'Resource'; Name = $_.Name; Type = $_.ResourceType; Group = $_.ResourceGroupName; Tags = $_.Tags; Id = $_.ResourceId }
            })
        if ($IncludeResourceGroup) {
            $targets += @(Get-AzResourceGroup | ForEach-Object {
                    @{ Kind = 'ResourceGroup'; Name = $_.ResourceGroupName; Type = 'Microsoft.Resources/resourceGroups'; Group = $_.ResourceGroupName; Tags = $_.Tags; Id = $_.ResourceId }
                })
        }

        foreach ($target in $targets) {
            $checked++
            $missing = Get-MissingTag -Tags $target.Tags -Required $RequiredTag
            if ($missing.Count -eq 0) { continue }
            $results.Add([pscustomobject]@{
                    SubscriptionName = $sub.Name
                    Kind             = $target.Kind
                    Name             = $target.Name
                    Type             = $target.Type
                    ResourceGroup    = $target.Group
                    MissingTags      = $missing -join ', '
                    ResourceId       = $target.Id
                })
        }
    }
} finally {
    if ($originalContext) { $null = Set-AzContext -Context $originalContext }
}

if ($checked -gt 0) {
    $compliant = $checked - $results.Count
    Write-Verbose ('{0} of {1} checked items carry every required tag ({2:P0})' -f $compliant, $checked, ($compliant / $checked))
}
if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Written to $OutputPath"
}
$results
