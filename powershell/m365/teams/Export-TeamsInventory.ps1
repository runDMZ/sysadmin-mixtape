#Requires -Version 7.2
#Requires -Modules MicrosoftTeams

<#
.SYNOPSIS
    Inventories Microsoft Teams: teams, channels, members and effective channel access.

.DESCRIPTION
    Read-only. Writes four CSV files, ready for Excel:
      01-Teams.csv           one row per team: visibility, channel counts (private, shared),
                             owners, members, guests, user domains
      02-Channels.csv        one row per channel: type (standard, private, shared), user count
      03-TeamMembers.csv     one row per user and per team, with role and domain
      04-ChannelAccess.csv   one row per user and per channel: the effective access
                             (standard channel: team members; private or shared channel:
                             its own members)
      99-Errors.csv          what could not be read, if anything

    The Domain column of every file helps split a multi-company tenant, or spot guests.
    Typical uses: tenant-to-tenant migration, moving to another collaboration tool,
    access review.

    Required role: Teams Administrator (or Global Administrator).

.PARAMETER OutputFolder
    Output folder. Default: ./Export-Teams-<date>

.PARAMETER IncludeArchived
    Include archived teams (excluded by default).

.PARAMETER Delimiter
    CSV delimiter. Default ','. Use ';' for Excel in locales where ',' is the decimal separator.

.PARAMETER UseDeviceAuthentication
    Sign in with a device code (useful on Linux or over SSH).

.EXAMPLE
    ./Export-TeamsInventory.ps1 -IncludeArchived -Delimiter ';'

.NOTES
    Limits: for shared channels, direct members are listed, not the whole teams the channel
    is shared with. Chats and meetings are not covered.
#>
[CmdletBinding()]
param(
    [string] $OutputFolder = "./Export-Teams-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [switch] $IncludeArchived,
    [string] $Delimiter = ',',
    [switch] $UseDeviceAuthentication
)

$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string] $Message)
    Write-Information $Message -InformationAction Continue
}

function Get-UserDomain {
    param([string] $Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) { return '' }
    if ($Upn -match '#EXT#') {
        # Guest: first.last_domain.com#EXT#@tenant.onmicrosoft.com
        return (($Upn -split '#EXT#')[0] -replace '^.*_', '').ToLower()
    }
    return ($Upn -split '@')[-1].ToLower()
}

function Get-AccountType {
    param([string] $Upn, [string] $Role)
    if ($Role -eq 'guest' -or $Upn -match '#EXT#') { return 'Guest' }
    return 'Internal'
}

$connectParams = @{}
if ($UseDeviceAuthentication) { $connectParams.UseDeviceAuthentication = $true }
$null = Connect-MicrosoftTeams @connectParams

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

$rowsTeams = [System.Collections.Generic.List[object]]::new()
$rowsChannels = [System.Collections.Generic.List[object]]::new()
$rowsMembers = [System.Collections.Generic.List[object]]::new()
$rowsAccess = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

try {
    Write-Status 'Reading teams...'
    $teams = @(Get-Team)
    if (-not $IncludeArchived) { $teams = @($teams | Where-Object { -not $_.Archived }) }
    Write-Status "$($teams.Count) team(s) to process."

    $i = 0
    foreach ($team in $teams) {
        $i++
        Write-Progress -Activity 'Teams inventory' -Status "$i / $($teams.Count): $($team.DisplayName)" `
            -PercentComplete (($i / [math]::Max($teams.Count, 1)) * 100)

        $teamUsers = @()
        try {
            $teamUsers = @(Get-TeamUser -GroupId $team.GroupId)
        } catch {
            $errors.Add([pscustomobject]@{ Team = $team.DisplayName; Channel = ''; Error = "Team members: $($_.Exception.Message)" })
        }

        foreach ($u in $teamUsers) {
            $rowsMembers.Add([pscustomobject]@{
                    Team        = $team.DisplayName
                    TeamId      = $team.GroupId
                    User        = $u.Name
                    UPN         = $u.User
                    Domain      = Get-UserDomain $u.User
                    AccountType = Get-AccountType $u.User $u.Role
                    Role        = $u.Role
                })
        }

        $channels = @()
        try {
            $channels = @(Get-TeamChannel -GroupId $team.GroupId)
        } catch {
            $errors.Add([pscustomobject]@{ Team = $team.DisplayName; Channel = ''; Error = "Channels: $($_.Exception.Message)" })
        }

        foreach ($ch in $channels) {
            $type = switch ($ch.MembershipType) {
                'Private' { 'Private' }
                'Shared' { 'Shared' }
                default { 'Standard' }
            }

            if ($ch.MembershipType -in @('Private', 'Shared')) {
                $channelUsers = @()
                try {
                    $channelUsers = @(Get-TeamChannelUser -GroupId $team.GroupId -DisplayName $ch.DisplayName)
                } catch {
                    $errors.Add([pscustomobject]@{ Team = $team.DisplayName; Channel = $ch.DisplayName; Error = "Channel members: $($_.Exception.Message)" })
                }
                $source = 'Channel member'
            } else {
                $channelUsers = $teamUsers
                $source = 'Inherited from team'
            }

            foreach ($u in $channelUsers) {
                $rowsAccess.Add([pscustomobject]@{
                        Team         = $team.DisplayName
                        Channel      = $ch.DisplayName
                        ChannelType  = $type
                        User         = $u.Name
                        UPN          = $u.User
                        Domain       = Get-UserDomain $u.User
                        AccountType  = Get-AccountType $u.User $u.Role
                        Role         = $u.Role
                        AccessSource = $source
                    })
            }

            $rowsChannels.Add([pscustomobject]@{
                    Team        = $team.DisplayName
                    Channel     = $ch.DisplayName
                    ChannelType = $type
                    UserCount   = @($channelUsers).Count
                    GuestCount  = @($channelUsers | Where-Object { (Get-AccountType $_.User $_.Role) -eq 'Guest' }).Count
                    Domains     = (@($channelUsers | ForEach-Object { Get-UserDomain $_.User }) | Sort-Object -Unique) -join ', '
                    Description = $ch.Description
                    ChannelId   = $ch.Id
                    TeamId      = $team.GroupId
                })
        }

        $rowsTeams.Add([pscustomobject]@{
                Team                = $team.DisplayName
                Visibility          = $team.Visibility
                Archived            = $team.Archived
                ChannelCount        = $channels.Count
                PrivateChannelCount = @($channels | Where-Object MembershipType -EQ 'Private').Count
                SharedChannelCount  = @($channels | Where-Object MembershipType -EQ 'Shared').Count
                OwnerCount          = @($teamUsers | Where-Object Role -EQ 'owner').Count
                MemberCount         = @($teamUsers | Where-Object Role -EQ 'member').Count
                GuestCount          = @($teamUsers | Where-Object Role -EQ 'guest').Count
                Owners              = (@($teamUsers | Where-Object Role -EQ 'owner' | ForEach-Object { $_.User }) -join ', ')
                Domains             = (@($teamUsers | ForEach-Object { Get-UserDomain $_.User }) | Sort-Object -Unique) -join ', '
                Description         = $team.Description
                TeamId              = $team.GroupId
            })
    }
    Write-Progress -Activity 'Teams inventory' -Completed

    $csvParams = @{ Delimiter = $Delimiter; NoTypeInformation = $true; Encoding = 'utf8BOM' }
    $rowsTeams | Sort-Object Team | Export-Csv -Path (Join-Path $OutputFolder '01-Teams.csv') @csvParams
    $rowsChannels | Sort-Object Team, Channel | Export-Csv -Path (Join-Path $OutputFolder '02-Channels.csv') @csvParams
    $rowsMembers | Sort-Object Team, Role, User | Export-Csv -Path (Join-Path $OutputFolder '03-TeamMembers.csv') @csvParams
    $rowsAccess | Sort-Object Team, Channel, User | Export-Csv -Path (Join-Path $OutputFolder '04-ChannelAccess.csv') @csvParams
    if ($errors.Count -gt 0) {
        $errors | Export-Csv -Path (Join-Path $OutputFolder '99-Errors.csv') @csvParams
        Write-Warning "$($errors.Count) error(s), see 99-Errors.csv"
    }

    Write-Status "Done: $($rowsTeams.Count) teams, $($rowsChannels.Count) channels, $($rowsAccess.Count) channel access rows."
    Write-Status "Files in: $((Resolve-Path $OutputFolder).Path)"
} finally {
    $null = Disconnect-MicrosoftTeams
}
