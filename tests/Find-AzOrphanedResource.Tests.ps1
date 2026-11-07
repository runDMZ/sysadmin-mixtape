BeforeAll {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $script:Path = Get-ScriptPath 'powershell/azure/cost/Find-AzOrphanedResource.ps1'
}

Describe 'Find-AzOrphanedResource' {
    BeforeAll {
        Set-AzConnectionMock
        Mock Get-AzDisk {
            [pscustomobject]@{ Name = 'disk-free'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'd1'
                DiskState = 'Unattached'; ManagedBy = $null; DiskSizeGB = 128; Sku = [pscustomobject]@{ Name = 'Premium_LRS' }; TimeCreated = (Get-Date) }
            [pscustomobject]@{ Name = 'disk-used'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'd2'
                DiskState = 'Attached'; ManagedBy = '/vm/1'; DiskSizeGB = 64; Sku = [pscustomobject]@{ Name = 'Standard_LRS' }; TimeCreated = (Get-Date) }
        }
        Mock Get-AzNatGateway { [pscustomobject]@{ PublicIpAddresses = @([pscustomobject]@{ Id = 'ip-nat' }) } }
        Mock Get-AzPublicIpAddress {
            [pscustomobject]@{ Name = 'ip-free'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'ip-free'; IpConfiguration = $null
                IpAddress = '20.0.0.1'; Sku = [pscustomobject]@{ Name = 'Standard' }; PublicIpAllocationMethod = 'Static' }
            [pscustomobject]@{ Name = 'ip-nat'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'ip-nat'; IpConfiguration = $null
                IpAddress = '20.0.0.2'; Sku = [pscustomobject]@{ Name = 'Standard' }; PublicIpAllocationMethod = 'Static' }
            [pscustomobject]@{ Name = 'ip-lb'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'ip-lb'; IpConfiguration = [pscustomobject]@{ Id = '/lb/fe' }
                IpAddress = '20.0.0.3'; Sku = [pscustomobject]@{ Name = 'Standard' }; PublicIpAllocationMethod = 'Static' }
        }
        Mock Get-AzNetworkInterface {
            [pscustomobject]@{ Name = 'nic-free'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'n1'; VirtualMachine = $null; PrivateEndpoint = $null }
            [pscustomobject]@{ Name = 'nic-pe'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 'n2'; VirtualMachine = $null; PrivateEndpoint = [pscustomobject]@{ Id = 'pe' } }
        }
        Mock Get-AzSnapshot {
            [pscustomobject]@{ Name = 'snap-old'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 's1'; DiskSizeGB = 32; TimeCreated = (Get-Date).AddDays(-200) }
            [pscustomobject]@{ Name = 'snap-new'; ResourceGroupName = 'rg-a'; Location = 'westeurope'; Id = 's2'; DiskSizeGB = 32; TimeCreated = (Get-Date).AddDays(-5) }
        }
        Mock Get-AzResource { [pscustomobject]@{ ResourceGroupName = 'RG-A' } }
        Mock Get-AzResourceGroup {
            [pscustomobject]@{ ResourceGroupName = 'rg-a'; Location = 'westeurope'; ResourceId = '/rg-a' }
            [pscustomobject]@{ ResourceGroupName = 'rg-empty'; Location = 'westeurope'; ResourceId = '/rg-empty' }
        }

        $script:Result = & $script:Path
    }

    It 'reports the unattached disk only' {
        @($Result | Where-Object Category -EQ 'UnattachedDisk').Name | Should -Be @('disk-free')
    }
    It 'reports the unused public IP but not the one used by the NAT gateway or a load balancer' {
        @($Result | Where-Object Category -EQ 'UnusedPublicIp').Name | Should -Be @('ip-free')
    }
    It 'does not report a NIC used by a private endpoint' {
        @($Result | Where-Object Category -EQ 'UnattachedNic').Name | Should -Be @('nic-free')
    }
    It 'reports snapshots older than the threshold only' {
        @($Result | Where-Object Category -EQ 'OldSnapshot').Name | Should -Be @('snap-old')
    }
    It 'reports the empty resource group, comparing names without case' {
        @($Result | Where-Object Category -EQ 'EmptyResourceGroup').Name | Should -Be @('rg-empty')
    }
    It 'restores the original Azure context' {
        # The script ran in BeforeAll: count the calls at the Describe level
        Should -Invoke Set-AzContext -ParameterFilter { $null -ne $Context } -Times 1 -Exactly -Scope Describe
    }
}

Describe 'Find-AzOrphanedResource when not connected' {
    It 'stops with a clear message' {
        Mock Get-AzContext { $null }
        { & $script:Path } | Should -Throw '*Connect-AzAccount*'
    }
}
