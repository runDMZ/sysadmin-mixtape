#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Stops (deallocates) the running VMs that carry a given tag, e.g. every evening.

.DESCRIPTION
    Finds running VMs whose tag -TagName equals -TagValue (default: AutoShutdown=true)
    and deallocates them. A deallocated VM stops paying for compute; its disks are
    still billed. This is the simplest way to cut the cost of lab and test VMs.

    This script CHANGES things. Always start with -WhatIf to see what it would stop.
    It asks for confirmation for each VM unless -Confirm:$false is given (scheduled runs).

    Required role: Virtual Machine Contributor on the targeted VMs (Reader is enough
    for -WhatIf).

.PARAMETER TagName
    Tag to look for. Default: AutoShutdown. Compared without case.

.PARAMETER TagValue
    Value the tag must have. Default: true. Compared without case.

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: every enabled subscription of the current tenant.

.PARAMETER NoWait
    Send the stop requests without waiting for each VM to finish deallocating.

.EXAMPLE
    ./Stop-AzVmByTag.ps1 -WhatIf

    Shows the VMs that would be stopped, changes nothing.

.EXAMPLE
    ./Stop-AzVmByTag.ps1 -TagName Environment -TagValue lab -Confirm:$false -NoWait

    Stops every running VM tagged Environment=lab, without prompting (scheduled use).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $TagName = 'AutoShutdown',
    [string] $TagValue = 'true',
    [string[]] $SubscriptionId,
    [switch] $NoWait
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

function Get-TagValue {
    # VM tags are a case-sensitive dictionary: look the key up without case
    param($Tags, [string] $Name)
    if (-not $Tags) { return $null }
    foreach ($key in $Tags.Keys) {
        if ($key -eq $Name) { return $Tags[$key] }
    }
    return $null
}

$originalContext = Get-AzContext
try {
    foreach ($sub in Get-TargetSubscription -Id $SubscriptionId) {
        Write-Verbose "Subscription $($sub.Name) ($($sub.Id))"
        # Set-AzContext honours -WhatIf too: force it, or a -WhatIf run would keep
        # reading the previous subscription. Switching context changes nothing in Azure.
        $null = Set-AzContext -Subscription $sub.Id -WhatIf:$false -Confirm:$false

        foreach ($vm in Get-AzVM -Status) {
            if ((Get-TagValue -Tags $vm.Tags -Name $TagName) -ne $TagValue) { continue }
            if ($vm.PowerState -notmatch 'running') {
                Write-Verbose "$($vm.Name): $($vm.PowerState), nothing to do"
                continue
            }

            $action = 'WhatIf'
            if ($PSCmdlet.ShouldProcess("$($vm.ResourceGroupName)/$($vm.Name)", 'Stop and deallocate VM')) {
                $null = Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -NoWait:$NoWait
                $action = if ($NoWait) { 'StopRequested' } else { 'Stopped' }
            }
            [pscustomobject]@{
                SubscriptionName = $sub.Name
                VM               = $vm.Name
                ResourceGroup    = $vm.ResourceGroupName
                PreviousState    = $vm.PowerState
                Action           = $action
            }
        }
    }
} finally {
    if ($originalContext) { $null = Set-AzContext -Context $originalContext -WhatIf:$false -Confirm:$false }
}
