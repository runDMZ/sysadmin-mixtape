# Shared helpers for the Pester tests. No Azure connection is used: every Az cmdlet
# the scripts call is mocked. The Az modules must still be installed, because
# Pester can only mock commands that exist.

$script:Root = Split-Path -Parent $PSScriptRoot

function Get-ScriptPath {
    param([string] $RelativePath)
    Join-Path $script:Root $RelativePath
}

function Set-AzConnectionMock {
    # A connected context and one enabled subscription
    Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
    Mock Get-AzSubscription { [pscustomobject]@{ Name = 'Lab'; Id = 'sub-1'; State = 'Enabled' } }
    # -Context expects a real PSAzureContext: accept the fake one
    Mock Set-AzContext {} -RemoveParameterType Context
}
