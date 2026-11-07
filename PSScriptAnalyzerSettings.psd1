@{
    # Run with: Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.2')
        }
        PSPlaceOpenBrace  = @{ Enable = $true; OnSameLine = $true }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4 }
    }
}
