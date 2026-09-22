<#
.SYNOPSIS
    Refreshes the cached usage figures the status line reads.

.DESCRIPTION
    Claude Code fetches GET /api/oauth/usage only from interactive paths -- the /usage view and the
    extra-usage flows -- and only one of those writes its cache. There is no timer and no CLI
    subcommand for it, so the spend figure in .claude.json is as old as the last time you opened
    /usage, which can be days. This script fetches it directly and writes the result to a side file
    the status line prefers whenever it is fresher.

    Normally you do not run this yourself: statusline-command.ps1 launches it, detached, when the
    figures go stale. Run it by hand to seed a profile or to see why it is failing.

    Two things it deliberately does NOT do:

      * It never writes .claude.json. The CLI owns that file and rewrites it wholesale on exit, so
        a concurrent writer would lose data. The side file is ours alone.
      * It never writes .credentials.json. The access token is read and sent to api.anthropic.com
        -- the service that issued it -- and nowhere else. If the token has expired the script gives
        up rather than attempting a refresh, since getting that wrong would break CLI auth. Normal
        CLI use refreshes it well inside its lifetime.

.PARAMETER Force
    Fetch regardless of how recently one was attempted.

.PARAMETER NoSpawn
    Fetch in this process instead of detaching a child. What the status line invokes, and what you
    want when running by hand with -Verbose to see errors.

.PARAMETER ConfigDir
    Profile to refresh. Defaults to $env:CLAUDE_CONFIG_DIR, or ~\.claude when that is unset.

.EXAMPLE
    .\refresh-usage.ps1 -Force -NoSpawn -Verbose

.EXAMPLE
    .\refresh-usage.ps1 -ConfigDir "$HOME\.claude-work" -Force -NoSpawn
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $NoSpawn,
    [int] $MinIntervalMinutes = 10,
    [string] $ConfigDir
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigDir) {
    $ConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
}

$cacheFile   = Join-Path $ConfigDir 'statusline-usage.json'
$attemptFile = Join-Path $ConfigDir 'statusline-usage.attempt'

# The throttle keys off the last *attempt*, not the last success. Keying off the cache instead
# would retry on every invocation once fetching started failing -- an expired token, no network --
# which on the status-line path means a process spawn per render.
function Get-AgeMinutes([string] $path) {
    if (-not (Test-Path -LiteralPath $path)) { return [double]::PositiveInfinity }
    return ([DateTime]::Now - (Get-Item -LiteralPath $path).LastWriteTime).TotalMinutes
}

if (-not $Force -and (Get-AgeMinutes $attemptFile) -lt $MinIntervalMinutes) { return }

New-Item -ItemType File -Path $attemptFile -Force | Out-Null

if (-not $NoSpawn) {
    # One quoted string, not an array: an array passes the quotes through literally and -File
    # rejects them as illegal path characters, while dropping them breaks on any path with a space.
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoSpawn -Force -ConfigDir "{1}"' -f
                 $PSCommandPath, $ConfigDir
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    return
}

try {
    $credentialsFile = Join-Path $ConfigDir '.credentials.json'
    if (-not (Test-Path -LiteralPath $credentialsFile)) {
        Write-Verbose "No credentials at $credentialsFile"
        return
    }

    $oauth = (Get-Content -LiteralPath $credentialsFile -Raw | ConvertFrom-Json).claudeAiOauth
    if (-not $oauth.accessToken) { Write-Verbose 'No OAuth access token'; return }
    if ($oauth.expiresAt -and
        [DateTimeOffset]::FromUnixTimeMilliseconds([int64] $oauth.expiresAt) -lt [DateTimeOffset]::Now) {
        Write-Verbose 'Access token expired; leaving the refresh to the CLI.'
        return
    }

    # Windows PowerShell 5.1 does not negotiate TLS 1.2 by default on every host.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $response = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
                                  -Method Get -TimeoutSec 15 -Headers @{
        'Authorization'  = "Bearer $($oauth.accessToken)"
        'anthropic-beta' = 'oauth-2025-04-20'
        'Content-Type'   = 'application/json'
    }

    # Only the fields the status line reads, so a shape change upstream cannot bloat this file.
    $payload = [ordered] @{
        fetchedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        spend       = $response.spend
        five_hour   = $response.five_hour
        seven_day   = $response.seven_day
    }
    # Not Set-Content -Encoding utf8NoBOM: that value only exists in PowerShell 7, and the status
    # line runs this under Windows PowerShell 5.1.
    [IO.File]::WriteAllText($cacheFile, ($payload | ConvertTo-Json -Depth 10),
                            (New-Object Text.UTF8Encoding $false))
    Write-Verbose "Wrote $cacheFile"
}
catch {
    # Never fail a render over this. The segment keeps its previous value and the status line
    # labels how old it is, which is the honest outcome.
    Write-Verbose "Usage refresh failed: $($_.Exception.Message)"
}
