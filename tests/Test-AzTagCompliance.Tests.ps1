BeforeAll {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $script:Path = Get-ScriptPath 'powershell/azure/governance/Test-AzTagCompliance.ps1'
}

Describe 'Test-AzTagCompliance' {
    BeforeAll {
        Set-AzConnectionMock
        Mock Get-AzResource {
            [pscustomobject]@{ Name = 'vm-ok'; ResourceType = 'Microsoft.Compute/virtualMachines'; ResourceGroupName = 'rg-a'; ResourceId = 'r1'
                Tags = @{ owner = 'alice'; ENVIRONMENT = 'prod' } }
            [pscustomobject]@{ Name = 'vm-empty-owner'; ResourceType = 'Microsoft.Compute/virtualMachines'; ResourceGroupName = 'rg-a'; ResourceId = 'r2'
                Tags = @{ Owner = ' '; Environment = 'lab' } }
            [pscustomobject]@{ Name = 'vm-untagged'; ResourceType = 'Microsoft.Compute/virtualMachines'; ResourceGroupName = 'rg-a'; ResourceId = 'r3'; Tags = $null }
            [pscustomobject]@{ Name = 'watcher'; ResourceType = 'Microsoft.Network/networkWatchers'; ResourceGroupName = 'rg-a'; ResourceId = 'r4'; Tags = $null }
        }
        Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = 'rg-a'; ResourceId = '/rg-a'; Tags = @{} } }
    }

    It 'accepts tags whatever their case' {
        $result = & $script:Path -RequiredTag Owner, Environment
        $result.Name | Should -Not -Contain 'vm-ok'
    }
    It 'counts an empty tag value as missing' {
        $result = & $script:Path -RequiredTag Owner, Environment
        ($result | Where-Object Name -EQ 'vm-empty-owner').MissingTags | Should -Be 'Owner'
    }
    It 'lists every missing tag of an untagged resource' {
        $result = & $script:Path -RequiredTag Owner, Environment
        ($result | Where-Object Name -EQ 'vm-untagged').MissingTags | Should -Be 'Owner, Environment'
    }
    It 'skips excluded resource types' {
        $result = & $script:Path -RequiredTag Owner -ExcludeResourceType 'Microsoft.Network/networkWatchers'
        $result.Name | Should -Not -Contain 'watcher'
    }
    It 'checks resource groups only with -IncludeResourceGroup' {
        (& $script:Path -RequiredTag Owner).Kind | Should -Not -Contain 'ResourceGroup'
        (& $script:Path -RequiredTag Owner -IncludeResourceGroup).Kind | Should -Contain 'ResourceGroup'
    }
}
