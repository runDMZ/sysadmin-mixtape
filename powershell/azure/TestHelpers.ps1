# Shared helpers for the Pester tests, which sit next to each script (Name.Tests.ps1).
# No Azure connection is used: every Az cmdlet the scripts call is mocked. The Az
# modules must still be installed, because Pester can only mock commands that exist.

function Initialize-AzConnectionMock {
    # A connected context and one enabled subscription
    Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-1' } } }
    Mock Get-AzSubscription { [pscustomobject]@{ Name = 'Lab'; Id = 'sub-1'; State = 'Enabled' } }
    # -Context expects a real PSAzureContext: accept the fake one
    Mock Set-AzContext {} -RemoveParameterType Context
}
