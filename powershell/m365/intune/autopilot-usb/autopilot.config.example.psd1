# Copy this file to autopilot.config.psd1 on the USB drive and fill in the values.
# autopilot.config.psd1 is ignored by git: it holds a secret, never commit it.
@{
    # Entra ID > Overview > Directory (tenant) ID
    TenantId  = '<TENANT-ID>'

    # Entra ID > App registrations > your app > Application (client) ID
    AppId     = '<APP-ID>'

    # Certificates & secrets > client secret VALUE (shown only once at creation)
    AppSecret = '<APP-SECRET>'
}
