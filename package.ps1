<#
.SYNOPSIS
    Builds a shareable zip of this directory, without the local configuration.

.DESCRIPTION
    Everything here is written to be handed to someone else, with one exception:
    profiles.config.ps1 holds your machine's values — the work directory tree, and which MCP
    servers you copy across. That file is excluded and profiles.config.example.ps1 ships in its
    place, so the recipient fills in their own.

    The script then scans what it packaged for anything that still looks local, and refuses to
    produce the zip if it finds something. Add your own patterns with -ExtraPatterns.

.PARAMETER OutFile
    Where to write the zip. Defaults to claude-account-split.zip in the current directory.

.PARAMETER ExtraPatterns
    Additional regular expressions to treat as local detail — a company name, a username, an
    internal host.

.EXAMPLE
    .\package.ps1

.EXAMPLE
    .\package.ps1 -OutFile ~\Desktop\split.zip -ExtraPatterns 'acmecorp', 'jdoe'
#>
[CmdletBinding()]
param(
    [string] $OutFile = (Join-Path (Get-Location) 'claude-account-split.zip'),
    [string[]] $ExtraPatterns = @()
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$excluded = @('profiles.config.ps1')

$staging = Join-Path ([IO.Path]::GetTempPath()) ("claude-split-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    Get-ChildItem -LiteralPath $here -File |
        Where-Object { $_.Name -notin $excluded -and $_.Extension -ne '.zip' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $staging }

    if (-not (Test-Path -LiteralPath (Join-Path $staging 'profiles.config.example.ps1'))) {
        throw "profiles.config.example.ps1 is missing; the recipient would have nothing to fill in."
    }

    # The user name is the most reliable marker of a leaked absolute path, so it is always checked.
    $patterns = @([regex]::Escape($env:USERNAME)) + $ExtraPatterns
    $findings = @()
    foreach ($file in Get-ChildItem -LiteralPath $staging -File) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($content, $pattern, 'IgnoreCase')) {
                $line = ($content.Substring(0, $match.Index) -split "`n").Count
                $findings += "  $($file.Name):$line matches /$pattern/"
            }
        }
    }

    if ($findings) {
        Write-Host "Local detail found; nothing was written:" -ForegroundColor Red
        $findings | Select-Object -Unique | ForEach-Object { Write-Host $_ }
        throw "Scrub these and re-run."
    }

    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutFile

    Write-Host "Wrote $OutFile"
    Get-ChildItem -LiteralPath $staging -File | ForEach-Object { Write-Host "  $($_.Name)" }
    Write-Host ""
    Write-Host "Excluded: $($excluded -join ', ')"
    Write-Host "Checked for: $($patterns -join ', ')"
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
