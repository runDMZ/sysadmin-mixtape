#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network

<#
.SYNOPSIS
    Finds resources that cost money (or clutter) without being used.

.DESCRIPTION
    Read-only: nothing is deleted. Reports:
      - UnattachedDisk     managed disks attached to no VM (billed for their full size)
      - UnusedPublicIp     public IPs bound to nothing (Standard SKU IPs are billed)
      - UnattachedNic      network interfaces attached to no VM or private endpoint
      - OldSnapshot        snapshots older than -SnapshotAgeDays
      - EmptyResourceGroup resource groups without any resource (no cost, but clutter)

    Check each finding before deleting: a disk can be kept on purpose (VM rebuilt
    later), and a public IP can be reserved for a DNS record or an allow-list.

    Required role: Reader on the subscriptions.

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: every enabled subscription of the current tenant.

.PARAMETER SnapshotAgeDays
    Snapshots older than this many days are reported. Default: 90.

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    ./Find-AzOrphanedResource.ps1 | Format-Table Category, Name, ResourceGroup, Details

.EXAMPLE
    ./Find-AzOrphanedResource.ps1 -SnapshotAgeDays 30 -OutputPath ./orphans.csv
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionId,
    [ValidateRange(1, 3650)]
    [int] $SnapshotAgeDays = 90,
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

function ConvertTo-Finding {
    param($Subscription, [string] $Category, $Resource, [string] $Details)
    [pscustomobject]@{
        SubscriptionName = $Subscription.Name
        Category         = $Category
        Name             = $Resource.Name
        ResourceGroup    = $Resource.ResourceGroupName
        Location         = $Resource.Location
        Details          = $Details
        ResourceId       = $Resource.Id
    }
}

$cutoff = (Get-Date).AddDays(-$SnapshotAgeDays)
$originalContext = Get-AzContext
$results = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($sub in Get-TargetSubscription -Id $SubscriptionId) {
        Write-Verbose "Subscription $($sub.Name) ($($sub.Id))"
        $null = Set-AzContext -Subscription $sub.Id

        # Managed disks attached to nothing
        foreach ($disk in Get-AzDisk) {
            $unattached = $disk.DiskState -eq 'Unattached' -or (-not $disk.DiskState -and -not $disk.ManagedBy)
            if ($unattached) {
                $results.Add((ConvertTo-Finding -Subscription $sub -Category 'UnattachedDisk' -Resource $disk -Details ('{0} GB, {1}, created {2:yyyy-MM-dd}' -f $disk.DiskSizeGB, $disk.Sku.Name, $disk.TimeCreated)))
            }
        }

        # Public IPs: bound to nothing, and not used by a NAT gateway
        # (a NAT gateway references its IPs from its own side, not through IpConfiguration)
        $natIpIds = @(Get-AzNatGateway | ForEach-Object { $_.PublicIpAddresses } | ForEach-Object { $_.Id })
        foreach ($ip in Get-AzPublicIpAddress) {
            if (-not $ip.IpConfiguration -and $ip.Id -notin $natIpIds) {
                $results.Add((ConvertTo-Finding -Subscription $sub -Category 'UnusedPublicIp' -Resource $ip -Details ('{0} ({1}, {2})' -f $ip.IpAddress, $ip.Sku.Name, $ip.PublicIpAllocationMethod)))
            }
        }

        # Network interfaces attached to no VM and no private endpoint
        foreach ($nic in Get-AzNetworkInterface) {
            if (-not $nic.VirtualMachine -and -not $nic.PrivateEndpoint) {
                $results.Add((ConvertTo-Finding -Subscription $sub -Category 'UnattachedNic' -Resource $nic -Details 'No VM, no private endpoint'))
            }
        }

        # Old snapshots
        foreach ($snap in Get-AzSnapshot) {
            if ($snap.TimeCreated -and $snap.TimeCreated -lt $cutoff) {
                $results.Add((ConvertTo-Finding -Subscription $sub -Category 'OldSnapshot' -Resource $snap -Details ('{0} GB, created {1:yyyy-MM-dd}' -f $snap.DiskSizeGB, $snap.TimeCreated)))
            }
        }

        # Resource groups without resources
        $usedGroups = @(Get-AzResource | ForEach-Object { $_.ResourceGroupName.ToLowerInvariant() } | Sort-Object -Unique)
        foreach ($rg in Get-AzResourceGroup) {
            if ($rg.ResourceGroupName.ToLowerInvariant() -notin $usedGroups) {
                $results.Add([pscustomobject]@{
                        SubscriptionName = $sub.Name
                        Category         = 'EmptyResourceGroup'
                        Name             = $rg.ResourceGroupName
                        ResourceGroup    = $rg.ResourceGroupName
                        Location         = $rg.Location
                        Details          = 'No resources'
                        ResourceId       = $rg.ResourceId
                    })
            }
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
