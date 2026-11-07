# 🎧 sysadmin-mixtape

> *Every track solves a problem I actually had.*

Scripts for the everyday work of a sysadmin on Microsoft clouds and Linux: know what is deployed, cut what costs money for nothing, inventory a tenant, enrol devices, automate the repetitive parts. Organised by language, then by platform.

- **Read-only by default.** Scripts that change something support `-WhatIf` and ask for confirmation.
- **Least privilege.** Each script states the minimum role it needs.
- **Pipeline-friendly.** Scripts return objects you can sort, filter or export; most accept `-OutputPath` for a CSV.
- **No tenant data inside.** Tenant names, IDs and secrets are parameters or local config files, ignored by git.

```
sysadmin-mixtape/
├── powershell/
│   ├── azure/     inventory, cost, governance, operations
│   └── m365/      entra, exchange, intune, sharepoint, teams
├── bash/
│   ├── linux/     server health, certificates, mail DNS, backups, local accounts
│   └── tests/     bats tests
└── tests/         Pester tests
```

Security audits (Azure RBAC, network exposure, storage) live in [security-beats](https://github.com/runDMZ/security-beats).

---

## PowerShell · Azure

| Script | Answers | Changes anything? | Minimum role |
|---|---|---|---|
| [`inventory/Get-AzResourceInventory.ps1`](powershell/azure/inventory/Get-AzResourceInventory.ps1) | What is deployed, where, with which tags? | No | Reader |
| [`cost/Find-AzOrphanedResource.ps1`](powershell/azure/cost/Find-AzOrphanedResource.ps1) | What costs money without being used? (unattached disks, unused public IPs, detached NICs, old snapshots, empty resource groups) | No | Reader |
| [`governance/Test-AzTagCompliance.ps1`](powershell/azure/governance/Test-AzTagCompliance.ps1) | Which resources miss the required tags? | No | Reader |
| [`operations/Stop-AzVmByTag.ps1`](powershell/azure/operations/Stop-AzVmByTag.ps1) | Deallocate the running VMs tagged for shutdown (lab, test) | **Yes**, `-WhatIf` | Virtual Machine Contributor |

They work across subscriptions: every enabled subscription of the current tenant by default, or the ones passed with `-SubscriptionId`. The original Azure context is restored at the end.

```powershell
Install-Module Az.Accounts, Az.Resources, Az.Compute, Az.Network -Scope CurrentUser
Connect-AzAccount

./powershell/azure/inventory/Get-AzResourceInventory.ps1 | Group-Object Type | Sort-Object Count -Descending
./powershell/azure/cost/Find-AzOrphanedResource.ps1 | Format-Table Category, Name, ResourceGroup, Details
./powershell/azure/governance/Test-AzTagCompliance.ps1 -RequiredTag Owner, Environment, CostCenter -IncludeResourceGroup -Verbose
./powershell/azure/operations/Stop-AzVmByTag.ps1 -WhatIf
```

- **Orphaned resources**: check before deleting. A disk may be kept on purpose, and a public IP may be reserved for a DNS record or a partner's allow-list.
- **Stopping VMs**: a deallocated VM stops paying for compute; its disks are still billed. To run it every evening, use an **Azure Automation** runbook with a managed identity (Virtual Machine Contributor on the lab scope), `Connect-AzAccount -Identity`, then the script with `-Confirm:$false`.

## PowerShell · Microsoft 365

| Script | What it does | Changes anything? | Required |
|---|---|---|---|
| [`entra/Get-M365GroupDomainReport.ps1`](powershell/m365/entra/Get-M365GroupDomainReport.ps1) | For each Microsoft 365 group and team, the email domains of its members: which groups are really shared between companies, which belong to one company with exceptions | No | Graph: `Group.Read.All`, `User.Read.All` |
| [`entra/Get-M365InactiveUser.ps1`](powershell/m365/entra/Get-M365InactiveUser.ps1) | Accounts nobody uses: no sign-in for 90 days, never signed in, or disabled but still licensed, with the licences they hold | No | Graph: `User.Read.All`, `AuditLog.Read.All`, `Organization.Read.All`; Entra ID P1 in the tenant |
| [`entra/Get-M365LicenseReport.ps1`](powershell/m365/entra/Get-M365LicenseReport.ps1) | For each licence: bought, assigned, left, and what to look at (unused, full, over-assigned, expiring) | No | Graph: `Organization.Read.All` |
| [`exchange/Get-SharedMailboxAccessReport.ps1`](powershell/m365/exchange/Get-SharedMailboxAccessReport.ps1) | Who can open (and send as) each shared mailbox, with the holder's domain | No | Exchange Online, read permissions |
| [`intune/autopilot-usb/`](powershell/m365/intune/autopilot-usb/) | USB kit that registers a PC in Autopilot during the OOBE in one command, with app-only authentication (works around the WAM sign-in hang of Microsoft.Graph 2.34+) | Yes (registers the device) | App registration with `DeviceManagementServiceConfig.ReadWrite.All` |
| [`sharepoint/Export-SharePointInventory.ps1`](powershell/m365/sharepoint/Export-SharePointInventory.ps1) | Every site with owners, members, visitors, admins and the source of each right (groups expanded), storage, sharing level. Works on Linux (PnP) | No | PnP app, SharePoint admin |
| [`sharepoint/Set-TemporarySiteAdmin.ps1`](powershell/m365/sharepoint/Set-TemporarySiteAdmin.ps1) | Makes you site admin only where you are not, for an inventory or a migration, then removes exactly those rights, with a tracking file for audits | **Yes**, `-WhatIf` | PnP app, SharePoint admin |
| [`teams/Export-TeamsInventory.ps1`](powershell/m365/teams/Export-TeamsInventory.ps1) | Every team, channel (private and shared included), member and effective channel access | No | Teams admin |

These scripts come from real administration work on a Microsoft 365 tenant shared by two companies: tenant split preparation, moving part of the collaboration to another tool, device enrolment. Typical uses: **tenant-to-tenant migration, merger or divestiture, access review**.

- **Run each Microsoft 365 module in its own session** (`pwsh -NoProfile`). PnP.PowerShell, Microsoft.Graph, MicrosoftTeams and ExchangeOnlineManagement ship different versions of the same authentication library: loading two of them in one session can fail, or crash PowerShell with a "Stack overflow".
- **Global Administrator does not mean access to every SharePoint site.** The inventory flags sites it could not read; `Set-TemporarySiteAdmin.ps1` grants and removes the missing rights with a trace.
- **The Autopilot kit stores a client secret on a USB drive**: see its [README](powershell/m365/intune/autopilot-usb/README.md) for the security rules.

## Bash · Linux

Small scripts, no dependency beyond the usual tools, exit codes that cron and monitoring understand: **0 OK, 1 warning, 2 critical**. All accept `-h`.

| Script | What it does | Changes anything? |
|---|---|---|
| [`server-health.sh`](bash/linux/server-health.sh) | One-screen health check: load, memory, disk space and inodes, failed systemd units, pending reboot, pending (security) updates, clock sync | No |
| [`check-cert-expiry.sh`](bash/linux/check-cert-expiry.sh) | Days left before TLS certificates expire, on live endpoints (SNI sent) or on certificate files | No |
| [`check-mail-dns.sh`](bash/linux/check-mail-dns.sh) | MX, SPF (single record, policy, 10-lookup limit), DMARC, DKIM selectors (Microsoft 365, Google…) and MTA-STS of a domain | No |
| [`backup-rotate.sh`](bash/linux/backup-rotate.sh) | Compressed backup of directories, checked after writing, with a SHA-256 checksum and rotation; dry run with `-N` | **Yes** (writes and rotates archives) |
| [`audit-local-users.sh`](bash/linux/audit-local-users.sh) | Who can log in: sudo rights, password state, SSH keys, last login; flags extra UID 0, empty passwords, NOPASSWD | No |

```bash
./bash/linux/server-health.sh -q            # prints nothing when all is well
./bash/linux/check-cert-expiry.sh -w 21 example.com mail.example.com:465
./bash/linux/check-mail-dns.sh example.com
sudo ./bash/linux/backup-rotate.sh -d /srv/backup -n etc -k 14 /etc
sudo ./bash/linux/audit-local-users.sh
```

In cron, a non-zero exit code is enough to get an email: `*/30 * * * * server-health.sh -q || mail -s "$(hostname)" admin@example.com`. `backup-rotate.sh` keeps a local copy only: copy the archives off the machine and test a restore from time to time.

---

## Tests

**Bash**: 16 [bats](https://github.com/bats-core/bats-core) tests, run on Linux. Commands such as `df` and `dig` are replaced by stubs; certificates (one served by a local `openssl s_server`), backups and account files are real files in a temporary directory. They check, for example, that more than 10 SPF lookups is critical, that a restore gives back the files minus the excluded ones, or that a dry run deletes nothing. Scripts pass `shellcheck` with no warning.

```bash
bats bash/tests
shellcheck bash/linux/*.sh
```

**PowerShell**: the Azure scripts have Pester tests that replace every Az cmdlet with a mock, so they run without an Azure account. The Az modules must still be installed, because Pester can only mock commands that exist.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path ./powershell -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

19 test cases check the logic of the Azure scripts against fake Azure objects: for example, that a public IP used by a NAT gateway is not reported as unused, or that `-WhatIf` never calls `Stop-AzVM`.

## Conventions

- `#Requires` for the PowerShell version and modules (except the Autopilot kit, which must run on Windows PowerShell 5.1 during OOBE);
- comment-based help with the required role and examples: `Get-Help <script> -Full`;
- objects as output, progress on the information or verbose streams, never `Write-Host`;
- `SupportsShouldProcess` (`-WhatIf`, `-Confirm`) for anything that changes something;
- no tenant name, ID or secret in the code.

## Next tracks

- Azure: cost by resource group and tag, Key Vault secrets close to expiry, VMs without backup
- Microsoft 365: Intune device compliance report, mailbox sizes and quotas
- Bash: log rotation and disk clean-up, user onboarding and offboarding
