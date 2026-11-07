#Requires -Version 7.2
#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Lists who can open (and optionally send as) each shared mailbox.

.DESCRIPTION
    Read-only. Returns one row per shared mailbox and per access holder, with the right
    (FullAccess, and SendAs with -IncludeSendAs) and the holder's email domain. Useful for an
    access review, and in a multi-company tenant to find mailboxes shared across companies
    (-MultiDomainOnly).

    Access granted through a group is shown as the group, not expanded into its members:
    review those groups separately.

    Required: an account connected with Connect-ExchangeOnline, with the right to read
    mailbox permissions (e.g. View-Only Recipients or Exchange Administrator).

.PARAMETER IncludeSendAs
    Also list SendAs rights.

.PARAMETER MultiDomainOnly
    Only return mailboxes whose holders come from at least two email domains.

.PARAMETER OutputPath
    Optional path of a CSV file to write the results to.

.EXAMPLE
    Connect-ExchangeOnline -Device
    ./Get-SharedMailboxAccessReport.ps1 -IncludeSendAs | Format-Table Mailbox, Holder, Right
#>
[CmdletBinding()]
param(
    [switch] $IncludeSendAs,
    [switch] $MultiDomainOnly,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-ConnectionInformation)) {
    throw 'Not connected to Exchange Online. Run Connect-ExchangeOnline first.'
}

function Test-RealHolder {
    # Skip built-in principals such as NT AUTHORITY\SELF and raw SIDs
    param([string] $Name)
    $Name -and $Name -notlike 'NT AUTHORITY\*' -and $Name -notmatch '^S-1-5-'
}

$results = [System.Collections.Generic.List[object]]::new()
$mailboxes = @(Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited)
Write-Verbose "$($mailboxes.Count) shared mailbox(es)"

foreach ($mbx in $mailboxes) {
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($perm in Get-EXOMailboxPermission -Identity $mbx.UserPrincipalName) {
        if (-not (Test-RealHolder $perm.User) -or $perm.AccessRights -notcontains 'FullAccess') { continue }
        $rows.Add(@{ Holder = $perm.User; Right = 'FullAccess' })
    }
    if ($IncludeSendAs) {
        foreach ($perm in Get-EXORecipientPermission -Identity $mbx.UserPrincipalName) {
            if (-not (Test-RealHolder $perm.Trustee) -or $perm.AccessRights -notcontains 'SendAs') { continue }
            $rows.Add(@{ Holder = $perm.Trustee; Right = 'SendAs' })
        }
    }

    $domains = @($rows | Where-Object { $_.Holder -like '*@*' } | ForEach-Object { ($_.Holder -split '@')[-1].ToLowerInvariant() } | Sort-Object -Unique)
    if ($MultiDomainOnly -and $domains.Count -lt 2) { continue }

    foreach ($row in $rows) {
        $results.Add([pscustomobject]@{
                Mailbox        = $mbx.DisplayName
                MailboxAddress = $mbx.PrimarySmtpAddress
                Holder         = $row.Holder
                HolderType     = if ($row.Holder -like '*@*') { 'User' } else { 'Group or other' }
                HolderDomain   = if ($row.Holder -like '*@*') { ($row.Holder -split '@')[-1].ToLowerInvariant() } else { '' }
                Right          = $row.Right
                MailboxDomains = $domains -join ', '
            })
    }
}

if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Verbose "Written to $OutputPath"
}
$results
