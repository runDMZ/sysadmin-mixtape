#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Groups

<#
.SYNOPSIS
    Shows, for each Microsoft 365 group (and team), which email domains its members come from.

.DESCRIPTION
    Read-only. In a tenant shared by several companies (after a merger, or a holding with
    several brands), it tells which groups are really shared and which belong to one company
    with a few exceptions. Those two cases are handled differently when the tenant is split:
    the first ones need an architecture decision (guest access, a shared space), the second
    ones usually just a membership clean-up.

    For each group: member count, guests, members per internal domain, whether it is a team,
    whether it mixes several internal domains, and the share of the smallest domain among the
    two biggest (MinorityShare: 0.5 = evenly shared, close to 0 = one domain with exceptions).

    Required: an account connected with Connect-MgGraph -Scopes Group.Read.All, User.Read.All

.PARAMETER MixedOnly
    Only return groups whose members come from at least two internal domains.

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    Connect-MgGraph -Scopes Group.Read.All, User.Read.All
    ./Get-M365GroupDomainReport.ps1 -MixedOnly | Sort-Object MinorityShare -Descending | Format-Table Group, IsTeam, Domains, MinorityShare
#>
[CmdletBinding()]
param(
    [switch] $MixedOnly,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    throw 'Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes Group.Read.All, User.Read.All first.'
}

function Get-UpnDomain {
    param([string] $Upn)
    ($Upn -split '@')[-1].ToLowerInvariant()
}

# Teams are Microsoft 365 groups provisioned with the "Team" option: a separate query is more
# reliable than reading resourceProvisioningOptions on each group (often returned empty).
$teamIds = @(Get-MgGroup -All -Filter "resourceProvisioningOptions/Any(x:x eq 'Team')" | ForEach-Object Id)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($group in Get-MgGroup -All -Filter "groupTypes/any(c:c eq 'Unified')") {
    $upns = @(Get-MgGroupMember -GroupId $group.Id -All |
            # Members can be devices or groups, without userPrincipalName
            ForEach-Object { if ($_.AdditionalProperties.ContainsKey('userPrincipalName')) { $_.AdditionalProperties['userPrincipalName'] } } |
            Where-Object { $_ })

    $guests = @($upns | Where-Object { $_ -match '#EXT#' })
    $internal = @($upns | Where-Object { $_ -notmatch '#EXT#' })
    $byDomain = @($internal | Group-Object { Get-UpnDomain $_ } | Sort-Object Count -Descending)

    $minorityShare = 0
    if ($byDomain.Count -ge 2) {
        $minorityShare = [math]::Round($byDomain[1].Count / ($byDomain[0].Count + $byDomain[1].Count), 2)
    }
    $mixed = $byDomain.Count -ge 2
    if ($MixedOnly -and -not $mixed) { continue }

    $results.Add([pscustomobject]@{
            Group         = $group.DisplayName
            IsTeam        = $group.Id -in $teamIds
            MemberCount   = $upns.Count
            GuestCount    = $guests.Count
            Domains       = ($byDomain | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count }) -join ', '
            MixedDomains  = $mixed
            MinorityShare = $minorityShare
            GroupId       = $group.Id
        })
}

if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Written to $OutputPath"
}
$results
