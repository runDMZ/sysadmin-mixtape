<#
.SYNOPSIS
    Registers the current Windows device in Windows Autopilot, without any sign-in window.

.DESCRIPTION
    Designed to run from a USB drive, during the OOBE (Shift+F10) or on an installed PC
    as administrator, through autopilot.cmd.

    It authenticates as an Entra ID app registration (app-only), so it does not depend on
    the interactive sign-in of Microsoft.Graph.Authentication. Since version 2.34.0 that
    sign-in goes through WAM by default, and "Get-WindowsAutopilotInfo -Online" hangs
    without ever showing a window in elevated or OOBE sessions.

    Steps:
      1. saves the hardware hash to hashes\<serial>.csv on the drive (fallback: manual
         CSV import in Intune);
      2. uploads it to Autopilot, with an optional group tag;
      3. waits for the deployment profile assignment;
      4. logs everything to autopilot.log.

    Compatible with Windows PowerShell 5.1 (the only PowerShell available during OOBE).

.PARAMETER GroupTag
    Optional Autopilot group tag, typically used by dynamic device groups to pick the
    deployment profile. It must match the group rule exactly.

.PARAMETER ConfigPath
    Configuration file holding TenantId, AppId and AppSecret.
    Default: autopilot.config.psd1 next to this script.

.EXAMPLE
    autopilot.cmd CORP

    Registers the device with the group tag CORP (autopilot.cmd calls this script).

.NOTES
    Required app registration: Microsoft Graph application permission
    DeviceManagementServiceConfig.ReadWrite.All, with admin consent.
    The secret sits in clear text on the USB drive: give it a short lifetime (3 to 6
    months), keep the drive under control, and revoke the secret if the drive is lost.
#>
[CmdletBinding()]
param(
    [string] $GroupTag = '',
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'autopilot.config.psd1')
)

$ErrorActionPreference = 'Stop'
$UsbRoot = $PSScriptRoot
$HashDir = Join-Path $UsbRoot 'hashes'
$LogFile = Join-Path $UsbRoot 'autopilot.log'
$Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()

function Write-Log {
    param([string] $Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Serial, $Message
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

try {
    Write-Log ("Registration started (group tag: {0})" -f $(if ($GroupTag) { $GroupTag } else { 'none' }))

    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath. Copy autopilot.config.example.psd1 to autopilot.config.psd1 and fill it in."
    }
    $config = Import-PowerShellDataFile -Path $ConfigPath
    foreach ($key in 'TenantId', 'AppId', 'AppSecret') {
        if (-not $config[$key] -or $config[$key] -match '[<>]') {
            throw "$key is missing or still a placeholder in $ConfigPath."
        }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # PowerShell Gallery prerequisites (a network connection is needed: connect Wi-Fi first in OOBE)
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope AllUsers
    $autopilotScript = Join-Path $env:ProgramFiles 'WindowsPowerShell\Scripts\Get-WindowsAutopilotInfo.ps1'

    # 1. Local copy of the hash: fallback for a manual CSV import in Intune
    New-Item -ItemType Directory -Path $HashDir -Force | Out-Null
    & $autopilotScript -OutputFile (Join-Path $HashDir "$Serial.csv")
    Write-Log "Hash saved to hashes\$Serial.csv"

    # 2. Direct upload to Autopilot, app-only
    $params = @{
        Online    = $true
        TenantId  = $config.TenantId
        AppId     = $config.AppId
        AppSecret = $config.AppSecret
        Assign    = $true
    }
    if ($GroupTag) { $params.GroupTag = $GroupTag }

    & $autopilotScript @params
    Write-Log 'Autopilot registration completed'
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log 'The hash is still available in hashes\ for a manual CSV import.'
    exit 1
}
