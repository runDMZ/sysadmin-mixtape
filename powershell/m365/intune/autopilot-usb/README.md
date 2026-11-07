# Autopilot USB kit

Registers a Windows device in Windows Autopilot from a USB drive, in one command, with no sign-in window.

## Why

Since **Microsoft.Graph.Authentication 2.34.0**, interactive sign-in goes through WAM (Web Account Manager) by default. In an elevated session or during the OOBE there is no window for WAM to attach to, so `Get-WindowsAutopilotInfo -Online` hangs forever without showing anything. This kit authenticates as an **app registration** instead, so there is no window to show.

## One-time setup

1. **Entra ID > App registrations > New registration**, single tenant, e.g. `Autopilot-Import`.
2. **API permissions > Add > Microsoft Graph > Application permissions**: `DeviceManagementServiceConfig.ReadWrite.All`, then **Grant admin consent**. That is the only permission it needs.
3. **Certificates & secrets > New client secret**, 3 to 6 months. Copy the **Value** immediately.
4. On the USB drive, copy `Register-Autopilot.ps1`, `autopilot.cmd` and `autopilot.config.example.psd1`. Rename the last one to `autopilot.config.psd1` and fill it in.

## Usage

- **During the OOBE**: connect to Wi-Fi, press **Shift+F10**, then run `D:\autopilot.cmd CORP` (with your drive letter and group tag).
- **On an installed PC**: right-click `autopilot.cmd` > *Run as administrator* (no group tag), or run it from an elevated prompt with the tag.

The group tag must match the rule of your dynamic device groups exactly, or the device will not get the right deployment profile.

## What it leaves on the drive

- `hashes\<serial>.csv`: the hardware hash, for a manual import in Intune if the upload fails.
- `autopilot.log`: one line per step, with the serial number.

## Security

The client secret is stored in clear text on the drive:

- give it a short lifetime and renew it;
- keep the drive under control, like a badge;
- **revoke the secret immediately** if the drive is lost;
- record the app registration in your register of technical accounts.

## Troubleshooting

| Message | Likely cause |
|---|---|
| `Cannot validate argument on parameter 'AuthUrl'` | Tenant ID still a placeholder, or pasted with `< >` or spaces |
| `401` / `invalid_client` / `AADSTS7000222` | Wrong or expired secret: create a new one |
| Error on `Install-PackageProvider` or `Install-Script` | No network yet (connect Wi-Fi first in OOBE) |
| Error at the upload step | Device already registered, here or in another tenant: the CSV is still saved |
