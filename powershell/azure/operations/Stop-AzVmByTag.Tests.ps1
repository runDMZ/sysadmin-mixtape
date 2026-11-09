BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    $script:Path = $PSCommandPath -replace '\.Tests\.ps1$', '.ps1'
}

Describe 'Stop-AzVmByTag' {
    BeforeAll {
        Initialize-AzConnectionMock
        Mock Get-AzVM {
            $tags = [System.Collections.Generic.Dictionary[string, string]]::new()
            $tags['autoshutdown'] = 'TRUE'
            [pscustomobject]@{ Name = 'vm-lab'; ResourceGroupName = 'rg-a'; PowerState = 'VM running'; Tags = $tags }
            [pscustomobject]@{ Name = 'vm-lab-off'; ResourceGroupName = 'rg-a'; PowerState = 'VM deallocated'; Tags = $tags }
            [pscustomobject]@{ Name = 'vm-prod'; ResourceGroupName = 'rg-a'; PowerState = 'VM running'
                Tags = [System.Collections.Generic.Dictionary[string, string]]::new() }
        }
        Mock Stop-AzVM {}
    }

    It 'changes nothing with -WhatIf' {
        $result = & $script:Path -WhatIf
        Should -Invoke Stop-AzVM -Times 0 -Exactly
        $result.VM | Should -Be @('vm-lab')
        $result.Action | Should -Be @('WhatIf')
    }
    It 'switches subscription for real even with -WhatIf' {
        $null = & $script:Path -WhatIf
        # -WhatIf must be passed explicitly as $false, not just left out
        Should -Invoke Set-AzContext -ParameterFilter {
            $Subscription -eq 'sub-1' -and $PSBoundParameters.ContainsKey('WhatIf') -and -not $WhatIf
        }
    }
    It 'stops only the running VM carrying the tag, matching the tag without case' {
        $result = & $script:Path -Confirm:$false
        Should -Invoke Stop-AzVM -Times 1 -Exactly -ParameterFilter { $Name -eq 'vm-lab' -and $Force }
        $result.Action | Should -Be @('Stopped')
    }
    It 'reports StopRequested with -NoWait' {
        (& $script:Path -Confirm:$false -NoWait).Action | Should -Be @('StopRequested')
    }
}
