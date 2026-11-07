#Requires -Version 7.4
#Requires -Modules PnP.PowerShell

<#
.SYNOPSIS
    Temporarily makes the signed-in admin site collection admin of SharePoint sites, then
    removes those rights, with a trace file.

.DESCRIPTION
    Global or SharePoint Administrators cannot read the content or members of sites they are
    not a member of. For an inventory or a tenant migration, this script:

    -Mode Add      lists the active sites (no OneDrive, no system sites), skips those where
                   you are ALREADY site admin, adds you as site collection admin on the
                   others, and records every change in the tracking file;
    -Mode Remove   reads the tracking file and removes you only from the sites the script
                   added you to. Sites where you were already admin are never touched.

    It uses the SharePoint admin API (the same as the admin center): no prior access to the
    sites is needed. Every change is also recorded in the Microsoft 365 audit log. Keep the
    tracking file: with its add and removal dates, it justifies these accesses in an audit.

    Supports -WhatIf: shows what would be done, changes nothing.

.PARAMETER Mode
    Add or Remove.

.PARAMETER TenantName
    Tenant prefix: contoso for contoso.sharepoint.com.

.PARAMETER ClientId
    Client ID of the PnP app (the one created with Export-SharePointInventory.ps1 -RegisterApp).

.PARAMETER TrackingFile
    CSV file listing the changed sites. Default: ./temporary-site-admin.csv

.EXAMPLE
    ./Set-TemporarySiteAdmin.ps1 -Mode Add -TenantName contoso -ClientId <id> -WhatIf
    ./Set-TemporarySiteAdmin.ps1 -Mode Add -TenantName contoso -ClientId <id>
    ./Set-TemporarySiteAdmin.ps1 -Mode Remove -TenantName contoso -ClientId <id>
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Add', 'Remove')]
    [string] $Mode,
    [Parameter(Mandatory)]
    [string] $TenantName,
    [Parameter(Mandatory)]
    [string] $ClientId,
    [string] $TrackingFile = './temporary-site-admin.csv'
)

$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string] $Message)
    Write-Information $Message -InformationAction Continue
}

$tenantFqdn = "$TenantName.onmicrosoft.com"
$adminUrl = "https://$TenantName-admin.sharepoint.com"
$rootUrl = "https://$TenantName.sharepoint.com"

Write-Status 'Sign-in 1/2: SharePoint admin'
$adminConn = Connect-PnPOnline -Url $adminUrl -ClientId $ClientId -Tenant $tenantFqdn -DeviceLogin -ReturnConnection
Write-Status 'Sign-in 2/2: SharePoint sites'
$siteConn = Connect-PnPOnline -Url $rootUrl -ClientId $ClientId -Tenant $tenantFqdn -DeviceLogin -ReturnConnection

$me = (Invoke-PnPGraphMethod -Connection $siteConn -Method Get -Url 'v1.0/me?$select=userPrincipalName').userPrincipalName
if (-not $me) { throw 'Could not determine the signed-in account.' }
Write-Status "Account: $me"

# Tenant administration object (the API behind the SharePoint admin center)
$adminCtx = $adminConn.Context
$tenant = New-Object Microsoft.Online.SharePoint.TenantAdministration.Tenant($adminCtx)

function Invoke-SiteAdminChange {
    param([string] $Url, [bool] $IsAdmin)
    $tenant.SetSiteAdmin($Url, $me, $IsAdmin) | Out-Null
    $adminCtx.ExecuteQuery()
}

function Test-IsSiteAdmin {
    # True if the account is already site admin; false otherwise, including access denied
    param([string] $Url)
    try {
        $r = Invoke-PnPSPRestMethod -Connection $siteConn -Method Get -Url "$Url/_api/web/currentuser?`$select=IsSiteAdmin"
        if ($null -ne $r.IsSiteAdmin) { return [bool]$r.IsSiteAdmin }
        if ($null -ne $r.d) { return [bool]$r.d.IsSiteAdmin }
        return $false
    } catch {
        return $false
    }
}

# Tracking file: comma-separated, written with -WhatIf:$false (it records real changes only)
$csvParams = @{ NoTypeInformation = $true; Encoding = 'utf8BOM'; WhatIf = $false; Confirm = $false }

if ($Mode -eq 'Add') {
    if ((Test-Path $TrackingFile) -and -not $WhatIfPreference) {
        throw "Tracking file $TrackingFile already exists. Run -Mode Remove first, or rename the file."
    }

    $excluded = '^(SRCHCEN|SPSMSITEHOST|APPCATALOG|POINTPUBLISHINGHUB|POINTPUBLISHINGTOPIC|EDISC|STS#-1|REDIRECTSITE|SPSPERS)'
    $sites = @(Get-PnPTenantSite -Connection $adminConn |
            Where-Object { $_.Template -notmatch $excluded -and $_.LockState -ne 'NoAccess' } |
            Sort-Object Title)
    Write-Status "$($sites.Count) site(s) checked."

    $journal = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($s in $sites) {
        $i++
        Write-Progress -Activity 'Adding site admin rights' -Status "$i / $($sites.Count): $($s.Title)" -PercentComplete (($i / $sites.Count) * 100)

        if (Test-IsSiteAdmin $s.Url) {
            [pscustomobject]@{ Site = $s.Title; Url = $s.Url; Action = 'AlreadyAdmin' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($s.Url, "Add $me as site collection admin")) {
            [pscustomobject]@{ Site = $s.Title; Url = $s.Url; Action = 'WouldAdd' }
            continue
        }
        try {
            Invoke-SiteAdminChange -Url $s.Url -IsAdmin $true
            $status = 'Added'; $err = ''
        } catch {
            Write-Warning "$($s.Title): $($_.Exception.Message)"
            $status = 'Failed'; $err = $_.Exception.Message
        }
        $journal.Add([pscustomobject]@{
                Site = $s.Title; Url = $s.Url; Account = $me; Status = $status
                AddedOn = (Get-Date -Format 'yyyy-MM-dd HH:mm'); RemovedOn = ''; Error = $err
            })
        # Saved after each site: the file stays accurate if the run is interrupted
        $journal | Export-Csv -Path $TrackingFile @csvParams
        [pscustomobject]@{ Site = $s.Title; Url = $s.Url; Action = $status }
    }
    Write-Progress -Activity 'Adding site admin rights' -Completed

    if (-not $WhatIfPreference) {
        $added = @($journal | Where-Object Status -EQ 'Added').Count
        Write-Status "Added on $added site(s), listed in $TrackingFile. Wait a few minutes for the rights to apply."
        Write-Status "To undo: ./Set-TemporarySiteAdmin.ps1 -Mode Remove -TenantName $TenantName -ClientId $ClientId"
    }
}

if ($Mode -eq 'Remove') {
    if (-not (Test-Path $TrackingFile)) { throw "Tracking file not found: $TrackingFile" }
    $journal = @(Import-Csv -Path $TrackingFile)
    $toRemove = @($journal | Where-Object { $_.Status -eq 'Added' })
    Write-Status "$($toRemove.Count) site(s) to clean up."

    foreach ($row in $toRemove) {
        if (-not $PSCmdlet.ShouldProcess($row.Url, "Remove $me from site collection admins")) {
            [pscustomobject]@{ Site = $row.Site; Url = $row.Url; Action = 'WouldRemove' }
            continue
        }
        try {
            Invoke-SiteAdminChange -Url $row.Url -IsAdmin $false
            $row.Status = 'Removed'
            $row.RemovedOn = Get-Date -Format 'yyyy-MM-dd HH:mm'
        } catch {
            $row.Error = $_.Exception.Message
            Write-Warning "$($row.Site): $($_.Exception.Message)"
        }
        [pscustomobject]@{ Site = $row.Site; Url = $row.Url; Action = $row.Status }
    }

    if (-not $WhatIfPreference) {
        $journal | Export-Csv -Path $TrackingFile @csvParams
        $left = @($journal | Where-Object Status -EQ 'Added').Count
        if ($left -eq 0) {
            Write-Status "All added rights removed. History kept in $TrackingFile"
        } else {
            Write-Warning "$left site(s) failed: run -Mode Remove again."
        }
    }
}
