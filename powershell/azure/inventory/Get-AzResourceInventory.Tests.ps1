BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    $script:Path = $PSCommandPath -replace '\.Tests\.ps1$', '.ps1'
}

Describe 'Get-AzResourceInventory' {
    BeforeAll {
        Initialize-AzConnectionMock
        Mock Get-AzResource {
            [pscustomobject]@{ Name = 'vm1'; ResourceType = 'Microsoft.Compute/virtualMachines'; ResourceGroupName = 'rg-a'
                Location = 'westeurope'; ResourceId = 'r1'; Tags = @{ Owner = 'alice'; Environment = 'lab' } }
            [pscustomobject]@{ Name = 'st1'; ResourceType = 'Microsoft.Storage/storageAccounts'; ResourceGroupName = 'rg-a'
                Location = 'westeurope'; ResourceId = 'r2'; Tags = $null }
        }
    }

    It 'returns one object per resource with its subscription' {
        $result = & $script:Path
        @($result).Count | Should -Be 2
        $result[0].SubscriptionName | Should -Be 'Lab'
    }
    It 'flattens tags into sorted key=value pairs' {
        (& $script:Path | Where-Object Name -EQ 'vm1').Tags | Should -Be 'Environment=lab; Owner=alice'
        (& $script:Path | Where-Object Name -EQ 'st1').Tags | Should -Be ''
    }
    It 'writes a CSV file when -OutputPath is given' {
        $csv = Join-Path $TestDrive 'inventory.csv'
        $null = & $script:Path -OutputPath $csv
        (Import-Csv $csv).Name | Should -Be @('vm1', 'st1')
    }
}
