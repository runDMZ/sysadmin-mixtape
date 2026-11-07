#Requires -Version 7.4
#Requires -Modules PnP.PowerShell

<#
.SYNOPSIS
    Inventories SharePoint Online: active sites, owners, members and where each right comes from.

.DESCRIPTION
    Read-only. Writes two CSV files, ready for Excel:
      01-Sites.csv        one row per active site: type, Teams connection, owners, counts of
                          owners / members / visitors / site admins / guests, storage, last
                          modification, external sharing level, whether members could be read
      02-SiteUsers.csv    one row per user and per site, with role (Owner, Member, Visitor,
                          Site admin) and source of the right (Microsoft 365 group, direct
                          assignment, security group, special group)
      99-Errors.csv       sites whose members could not be read, if any

    Microsoft 365 groups and security groups found in SharePoint groups are expanded, so
    you see real people. OneDrive and system sites are excluded.

    Works on Linux (PnP.PowerShell), unlike the official SharePoint Online module.

    Being Global or SharePoint Administrator does NOT give access to the content of every
    site: members of sites you are not a member of may be unreadable. Those sites are
    flagged in the MembersRead column. Set-TemporarySiteAdmin.ps1 solves that, with a trace.

.PARAMETER TenantName
    Tenant prefix: contoso for contoso.sharepoint.com.

.PARAMETER RegisterApp
    First run only: creates the Entra ID app PnP.PowerShell needs (delegated permissions:
    SharePoint AllSites.FullControl; Graph Group.Read.All, GroupMember.Read.All,
    User.Read.All) and shows its client ID. Requires a Global Administrator.

.PARAMETER ClientId
    Client ID of the app created with -RegisterApp.

.PARAMETER OutputFolder
    Output folder. Default: ./Export-SharePoint-<date>

.PARAMETER Delimiter
    CSV delimiter. Default ','. Use ';' for Excel in locales where ',' is the decimal separator.

.EXAMPLE
    ./Export-SharePointInventory.ps1 -TenantName contoso -RegisterApp

    Once: creates the app and shows its client ID.

.EXAMPLE
    ./Export-SharePointInventory.ps1 -TenantName contoso -ClientId 00000000-0000-0000-0000-000000000000

.NOTES
    Run it in a fresh session (pwsh -NoProfile): PnP.PowerShell and other Microsoft modules
    (MicrosoftTeams, Microsoft.Graph, ExchangeOnlineManagement) ship different versions of
    the same authentication library, and loading both in one session can crash PowerShell
    with a "Stack overflow".
    Two device codes are asked: one for the SharePoint admin site, one for the sites.
#>
[CmdletBinding(DefaultParameterSetName = 'Inventory')]
param(
    [Parameter(Mandatory)]
    [string] $TenantName,
    [Parameter(Mandatory, ParameterSetName = 'Register')]
    [switch] $RegisterApp,
    [Parameter(Mandatory, ParameterSetName = 'Inventory')]
    [string] $ClientId,
    [Parameter(ParameterSetName = 'Inventory')]
    [string] $OutputFolder = "./Export-SharePoint-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [Parameter(ParameterSetName = 'Inventory')]
    [string] $Delimiter = ','
)

$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string] $Message)
    Write-Information $Message -InformationAction Continue
}

$tenantFqdn = "$TenantName.onmicrosoft.com"
$rootUrl = "https://$TenantName.sharepoint.com"
$adminUrl = "https://$TenantName-admin.sharepoint.com"

# --- First run: create the Entra ID app ---------------------------------------
if ($RegisterApp) {
    Write-Status 'Creating the Entra ID app (device code sign-in)...'
    Register-PnPEntraIDAppForInteractiveLogin `
        -ApplicationName 'PnP - SharePoint inventory' `
        -Tenant $tenantFqdn `
        -SharePointDelegatePermissions 'AllSites.FullControl' `
        -GraphDelegatePermissions 'Group.Read.All', 'GroupMember.Read.All', 'User.Read.All' `
        -DeviceLogin | Format-List
    Write-Status "Note the app (client) ID shown above, then run: ./Export-SharePointInventory.ps1 -TenantName $TenantName -ClientId <id>"
    return
}

# --- Connections: admin site (list of sites) and tenant (members of each site) --
Write-Status 'Sign-in 1/2: SharePoint admin'
$adminConn = Connect-PnPOnline -Url $adminUrl -ClientId $ClientId -Tenant $tenantFqdn -DeviceLogin -ReturnConnection
Write-Status 'Sign-in 2/2: SharePoint sites'
$siteConn = Connect-PnPOnline -Url $rootUrl -ClientId $ClientId -Tenant $tenantFqdn -DeviceLogin -ReturnConnection

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

# --- Helpers ------------------------------------------------------------------
function Get-UserDomain {
    param([string] $Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) { return '' }
    if ($Upn -match '#EXT#') {
        return (($Upn -split '#EXT#')[0] -replace '^.*_', '').ToLower()
    }
    return ($Upn -split '@')[-1].ToLower()
}

function Get-AccountType {
    param([string] $Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) { return 'Special group' }
    if ($Upn -match '#EXT#') { return 'Guest' }
    return 'Internal'
}

function Get-TemplateLabel {
    param([string] $Template)
    switch -Regex ($Template) {
        '^GROUP#' { return 'Team site (Microsoft 365 group)' }
        '^SITEPAGEPUBLISHING#' { return 'Communication site' }
        '^STS#3' { return 'Team site without group' }
        '^STS#' { return 'Classic team site' }
        '^TEAMCHANNEL#0' { return 'Teams private channel' }
        '^TEAMCHANNEL#1' { return 'Teams shared channel' }
        default { return $Template }
    }
}

function Get-SharingLabel {
    param([string] $Sharing)
    switch ($Sharing) {
        'Disabled' { return 'Disabled (internal only)' }
        'ExistingExternalUserSharingOnly' { return 'Existing guests only' }
        'ExternalUserSharingOnly' { return 'New and existing guests' }
        'ExternalUserAndGuestSharing' { return 'Anyone (anonymous links)' }
        default { return $Sharing }
    }
}

function Invoke-SpGet {
    param([string] $Url)
    $r = Invoke-PnPSPRestMethod -Method Get -Url $Url -Connection $siteConn
    if ($null -ne $r.value) { return @($r.value) }
    if ($null -ne $r.d -and $null -ne $r.d.results) { return @($r.d.results) }
    return @()
}

$groupCache = @{}
function Get-EntraGroupUser {
    # Kind: owners | members | transitiveMembers
    param([string] $GroupId, [string] $Kind)
    $key = "$GroupId|$Kind"
    if (-not $groupCache.ContainsKey($key)) {
        $r = Invoke-PnPGraphMethod -Connection $siteConn -Method Get -All -Url "v1.0/groups/$GroupId/$($Kind)?`$select=displayName,userPrincipalName"
        $items = if ($null -ne $r.value) { @($r.value) } else { @($r) }
        $groupCache[$key] = @($items | Where-Object { $_.userPrincipalName } | ForEach-Object {
                [pscustomobject]@{ Name = $_.displayName; Upn = $_.userPrincipalName }
            })
    }
    return $groupCache[$key]
}

function Resolve-SpPrincipal {
    # Turns a member of a SharePoint group into the list of real users behind it
    param($Principal)
    $login = [string]$Principal.LoginName
    $title = [string]$Principal.Title

    if ($login -match 'federateddirectoryclaimprovider\|([0-9a-fA-F-]{36})(_o)?$') {
        $gid = $Matches[1]; $isOwners = [bool]$Matches[2]
        $kind = if ($isOwners) { 'owners' } else { 'members' }
        $label = if ($isOwners) { 'Microsoft 365 group owners' } else { 'Microsoft 365 group members' }
        return @(Get-EntraGroupUser $gid $kind | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Upn = $_.Upn; Via = $label }
            })
    }
    if ($login -match '^c:0t\.c\|tenant\|([0-9a-fA-F-]{36})$') {
        $gid = $Matches[1]
        return @(Get-EntraGroupUser $gid 'transitiveMembers' | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Upn = $_.Upn; Via = "Security group: $title" }
            })
    }
    if ($login -match 'spo-grid-all-users') {
        return @([pscustomobject]@{ Name = 'Everyone except external users'; Upn = ''; Via = 'Special group' })
    }
    if ($login -eq 'c:0(.s|true') {
        return @([pscustomobject]@{ Name = 'Everyone'; Upn = ''; Via = 'Special group' })
    }
    if ($login -match '^i:0#\.f\|membership\|(.+)$') {
        return @([pscustomobject]@{ Name = $title; Upn = $Matches[1]; Via = 'Direct assignment' })
    }
    if ($login -match '^SHAREPOINT\\system$' -or $login -match 'app@sharepoint') {
        return @()
    }
    return @([pscustomobject]@{ Name = $title; Upn = $login; Via = 'Other' })
}

# --- Sites --------------------------------------------------------------------
Write-Status 'Reading sites...'
$excluded = '^(SRCHCEN|SPSMSITEHOST|APPCATALOG|POINTPUBLISHINGHUB|POINTPUBLISHINGTOPIC|EDISC|STS#-1|REDIRECTSITE|SPSPERS)'
$sites = @(Get-PnPTenantSite -Connection $adminConn | Where-Object { $_.Template -notmatch $excluded } | Sort-Object Title)
Write-Status "$($sites.Count) site(s) to process."

$rowsSites = [System.Collections.Generic.List[object]]::new()
$rowsUsers = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

$i = 0
foreach ($s in $sites) {
    $i++
    Write-Progress -Activity 'SharePoint inventory' -Status "$i / $($sites.Count): $($s.Title)" `
        -PercentComplete (($i / [math]::Max($sites.Count, 1)) * 100)

    $entries = [System.Collections.Generic.List[object]]::new()
    $groupId = [string]$s.GroupId
    $isGroup = $groupId -and $groupId -ne [guid]::Empty.ToString()
    $readOk = $true

    # 1. Group-connected sites: owners and members of the Microsoft 365 group (Graph)
    if ($isGroup) {
        try {
            foreach ($u in (Get-EntraGroupUser $groupId 'owners')) {
                $entries.Add([pscustomobject]@{ Role = 'Owner'; Name = $u.Name; Upn = $u.Upn; Via = 'Microsoft 365 group owners' })
            }
            foreach ($u in (Get-EntraGroupUser $groupId 'members')) {
                $entries.Add([pscustomobject]@{ Role = 'Member'; Name = $u.Name; Upn = $u.Upn; Via = 'Microsoft 365 group members' })
            }
        } catch {
            $errors.Add([pscustomobject]@{ Site = $s.Title; Url = $s.Url; Step = 'Microsoft 365 group'; Error = $_.Exception.Message })
        }
    }

    # 2. SharePoint groups of the site (owners, members, visitors) and site admins
    if ($s.LockState -ne 'NoAccess') {
        $spGroups = @(
            @{ Role = 'Owner'; Endpoint = 'associatedownergroup' },
            @{ Role = 'Member'; Endpoint = 'associatedmembergroup' },
            @{ Role = 'Visitor'; Endpoint = 'associatedvisitorgroup' }
        )
        foreach ($g in $spGroups) {
            try {
                foreach ($p in (Invoke-SpGet "$($s.Url)/_api/web/$($g.Endpoint)/users")) {
                    foreach ($u in (Resolve-SpPrincipal $p)) {
                        $entries.Add([pscustomobject]@{ Role = $g.Role; Name = $u.Name; Upn = $u.Upn; Via = $u.Via })
                    }
                }
            } catch {
                $readOk = $false
                $errors.Add([pscustomobject]@{ Site = $s.Title; Url = $s.Url; Step = "SharePoint group $($g.Role)"; Error = $_.Exception.Message })
            }
        }
        try {
            foreach ($p in (Invoke-SpGet "$($s.Url)/_api/web/siteusers?`$filter=IsSiteAdmin%20eq%20true")) {
                foreach ($u in (Resolve-SpPrincipal $p)) {
                    $entries.Add([pscustomobject]@{ Role = 'Site admin'; Name = $u.Name; Upn = $u.Upn; Via = $u.Via })
                }
            }
        } catch {
            $readOk = $false
            $errors.Add([pscustomobject]@{ Site = $s.Title; Url = $s.Url; Step = 'Site admins'; Error = $_.Exception.Message })
        }
    }

    # De-duplicate: one row per user, per role and per site
    $seen = @{}
    $unique = @(foreach ($e in $entries) {
            $k = "$($e.Role)|$(if ($e.Upn) { $e.Upn.ToLower() } else { $e.Name })"
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $e }
        })

    foreach ($e in $unique) {
        $rowsUsers.Add([pscustomobject]@{
                Site        = $s.Title
                Url         = $s.Url
                User        = $e.Name
                Email       = $e.Upn
                Domain      = Get-UserDomain $e.Upn
                AccountType = Get-AccountType $e.Upn
                Role        = $e.Role
                Source      = $e.Via
            })
    }

    $owners = @($unique | Where-Object Role -EQ 'Owner')
    $rowsSites.Add([pscustomobject]@{
            Site             = $s.Title
            Url              = $s.Url
            Type             = Get-TemplateLabel $s.Template
            TeamsConnected   = [bool]($s.IsTeamsConnected -or $s.IsTeamsChannelConnected)
            Owners           = ($owners | ForEach-Object { if ($_.Upn) { $_.Upn } else { $_.Name } }) -join ', '
            OwnerCount       = $owners.Count
            MemberCount      = @($unique | Where-Object Role -EQ 'Member').Count
            VisitorCount     = @($unique | Where-Object Role -EQ 'Visitor').Count
            SiteAdminCount   = @($unique | Where-Object Role -EQ 'Site admin').Count
            GuestCount       = @($unique | Where-Object { (Get-AccountType $_.Upn) -eq 'Guest' } | ForEach-Object Upn | Sort-Object -Unique).Count
            Domains          = (@($unique | Where-Object Upn | ForEach-Object { Get-UserDomain $_.Upn }) | Sort-Object -Unique) -join ', '
            StorageMB        = $s.StorageUsageCurrent
            LastModified     = if ($s.LastContentModifiedDate) { ([datetime]$s.LastContentModifiedDate).ToString('yyyy-MM-dd') } else { '' }
            ExternalSharing  = Get-SharingLabel ([string]$s.SharingCapability)
            MembersRead      = if ($readOk) { 'OK' } else { 'Partial (access denied)' }
            Template         = $s.Template
            M365GroupId      = if ($isGroup) { $groupId } else { '' }
        })
}
Write-Progress -Activity 'SharePoint inventory' -Completed

$csvParams = @{ Delimiter = $Delimiter; NoTypeInformation = $true; Encoding = 'utf8BOM' }
$rowsSites | Export-Csv -Path (Join-Path $OutputFolder '01-Sites.csv') @csvParams
$rowsUsers | Sort-Object Site, Role, User | Export-Csv -Path (Join-Path $OutputFolder '02-SiteUsers.csv') @csvParams
if ($errors.Count -gt 0) {
    $errors | Export-Csv -Path (Join-Path $OutputFolder '99-Errors.csv') @csvParams
    Write-Warning "$($errors.Count) error(s), see 99-Errors.csv"
}

Write-Status "Done: $($rowsSites.Count) sites, $($rowsUsers.Count) user rows."
Write-Status "Files in: $((Resolve-Path $OutputFolder).Path)"
