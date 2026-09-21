<#
.SYNOPSIS
    Sets up the Claude Code personal/work account split on this machine.

.DESCRIPTION
    Idempotent: safe to re-run. It performs only the mechanical steps —

      1. writes profiles.config.ps1 with the work root and work config dir
      2. creates the work config directory
      3. optionally seeds it from the personal profile (settings.json, skills, plugins)
      4. repoints the personal settings.json status line at the shared script (with a backup)
      5. adds the dot-source line to the PowerShell 7 and Windows PowerShell 5.1 profiles

    and then prints the steps that need a human: logging the work account in, and running
    migrate-workspaces.ps1.

    Nothing here needs an elevated prompt.

.PARAMETER WorkRoot
    Directory tree owned by the work account. `claude` routes anything at or under it to work.

.PARAMETER WorkDir
    Config directory for the work account. Defaults to ~\.claude-work.

.PARAMETER Seed
    Copy settings.json, skills\ and plugins\ from the personal profile into the work one. Skipped
    for files that already exist unless -Force is given.

.PARAMETER Force
    Overwrite profiles.config.ps1 and any seeded files that already exist.

.EXAMPLE
    .\install.ps1 -WorkRoot 'C:\Dev\Work' -Seed

.EXAMPLE
    .\install.ps1 -WorkRoot 'D:\src\acme' -WorkDir 'D:\claude-acme'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorkRoot,
    [string] $WorkDir = (Join-Path $HOME '.claude-work'),
    [string] $PersonalDir = (Join-Path $HOME '.claude'),
    [switch] $Seed,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$statusLineScript = Join-Path $here 'statusline-command.ps1'

function Write-Step([string] $message) { Write-Host "==> $message" }
function Write-Skip([string] $message) { Write-Host "    (skipped) $message" }

$statusLineCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$statusLineScript`""

# Set-Content's utf8NoBOM value is PowerShell 7+, and this script has to run under Windows
# PowerShell 5.1 as well, where the only BOM-less choice writes through .NET directly. The BOM is
# not cosmetic here: a strict JSON parser rejects a settings.json that starts with one.
#
# WriteAllText resolves a relative path against the process working directory rather than the
# PowerShell one, so the path is expanded through the provider first.
function Write-Utf8NoBom([string] $path, [string] $text) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    [IO.File]::WriteAllText($full, $text, (New-Object Text.UTF8Encoding $false))
}

# Seeding copies a settings.json that may have no status line at all, so this adds the property
# rather than only rewriting it when present — otherwise the work profile silently ends up without
# the account tag, which is the one thing the split needs to be visible.
function Set-StatusLine($settings, [string] $command) {
    if ($settings.statusLine) { $settings.statusLine.command = $command }
    else {
        $settings | Add-Member -NotePropertyName statusLine `
                               -NotePropertyValue ([pscustomobject] @{ type = 'command'; command = $command })
    }
}

$claudeExe = Join-Path $HOME '.local\bin\claude.exe'
if (-not (Test-Path -LiteralPath $claudeExe)) {
    Write-Warning "claude.exe not found at $claudeExe. The switcher will not run until it exists."
}

# --- 1. profiles.config.ps1 ------------------------------------------------------------------------
$configFile = Join-Path $here 'profiles.config.ps1'
if ((Test-Path -LiteralPath $configFile) -and -not $Force) {
    Write-Skip "profiles.config.ps1 already exists (pass -Force to rewrite)"
}
else {
    Write-Step "Writing profiles.config.ps1"
    @"
# Local settings for the Claude Code account split. See README.md and SETUP.md.

# Directory tree owned by the work account.
`$ClaudeWorkRoot = '$WorkRoot'

# Config directory for the work account. The personal account keeps the default (~\.claude) with
# CLAUDE_CONFIG_DIR left unset, deliberately -- see README.md.
`$ClaudeWorkDir = '$WorkDir'

# Labels shown in the status-line tag.
`$ClaudeAccountLabels = @{ personal = 'Personal'; work = 'Work' }

# User-scope MCP servers that migrate-workspaces.ps1 copies into the work profile, by name.
# Consider what each one authenticates as before listing it.
`$ClaudeMcpServersToCopy = @()
"@ | ForEach-Object { Write-Utf8NoBom $configFile $_ }
}

# --- 2. work config directory ----------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkDir) { Write-Skip "$WorkDir already exists" }
else {
    Write-Step "Creating $WorkDir"
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# --- 3. seed the work profile ----------------------------------------------------------------------
if ($Seed) {
    $workSettings = Join-Path $WorkDir 'settings.json'
    if ((Test-Path -LiteralPath $workSettings) -and -not $Force) {
        Write-Skip "work settings.json already exists"
    }
    else {
        $personalSettings = Join-Path $PersonalDir 'settings.json'
        if (Test-Path -LiteralPath $personalSettings) {
            Write-Step "Seeding work settings.json from the personal profile"
            $settings = Get-Content -LiteralPath $personalSettings -Raw | ConvertFrom-Json
            Set-StatusLine $settings $statusLineCommand
            Write-Utf8NoBom $workSettings ($settings | ConvertTo-Json -Depth 20)
        }
        else { Write-Skip "no personal settings.json to seed from" }
    }

    foreach ($name in @('skills', 'plugins')) {
        $source = Join-Path $PersonalDir $name
        $target = Join-Path $WorkDir $name
        if (-not (Test-Path -LiteralPath $source)) { Write-Skip "no $name\ in the personal profile"; continue }
        if ((Test-Path -LiteralPath $target) -and -not $Force) { Write-Skip "$name\ already present"; continue }
        Write-Step "Copying $name\ into the work profile"
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }

    Write-Host "    Copy your CLAUDE.md across yourself: it usually needs editing, not copying."
}

# --- 4. status lines -------------------------------------------------------------------------------
# Both profiles, not just the personal one: without -Seed the work profile has no settings.json at
# all, and a work account with no account tag is the failure this whole thing is meant to prevent.
$personalSettings = Join-Path $PersonalDir 'settings.json'
$workSettings     = Join-Path $WorkDir 'settings.json'

foreach ($target in @(@('personal', $personalSettings), @('work', $workSettings))) {
    $label = $target[0]
    $path  = $target[1]

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Step "Creating the $label settings.json with the shared status line"
        $settings = [pscustomobject] @{}
        Set-StatusLine $settings $statusLineCommand
        Write-Utf8NoBom $path ($settings | ConvertTo-Json -Depth 20)
        continue
    }

    $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($settings.statusLine -and $settings.statusLine.command -eq $statusLineCommand) {
        Write-Skip "$label status line already points at the shared script"
        continue
    }

    Write-Step "Repointing the $label status line at the shared script"
    Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
    Set-StatusLine $settings $statusLineCommand
    Write-Utf8NoBom $path ($settings | ConvertTo-Json -Depth 20)
}

# --- 5. PowerShell profiles ------------------------------------------------------------------------
# Both editions, because an IDE's built-in terminal may launch either one.
$switcher = Join-Path $here 'claude-switch.ps1'
$line = ". `"$switcher`""
$documents = [Environment]::GetFolderPath('MyDocuments')

$profilePaths = @(
    (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
)

$stale = $false
foreach ($path in $profilePaths) {
    $existing = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw } else { '' }
    if ($existing.Contains($switcher)) {
        Write-Skip "$path already loads this switcher"
        continue
    }
    # A dot-source naming claude-switch.ps1 at some *other* path is a leftover from an earlier
    # layout. Matching on the bare file name would let that leftover pass for a working install, so
    # it is reported instead: the old line has to come out before this one goes in.
    if ($existing.Contains('claude-switch.ps1')) {
        Write-Warning "$path dot-sources a different claude-switch.ps1. Remove that line and re-run."
        $stale = $true
        continue
    }
    Write-Step "Adding the switcher to $path"
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $block = "`n# Claude Code account switcher: provides claude / claude-work / claude-personal.`n$line`n"
    Add-Content -LiteralPath $path -Value $block
}

# --- what is left for a human ----------------------------------------------------------------------
Write-Host ""
if ($stale) {
    Write-Warning "A stale switcher line is still in a PowerShell profile; the switcher will not load until it is removed."
}
Write-Host "Installed. Remaining steps, in order:"
Write-Host "  1. Open a NEW terminal, so the profile loads."
Write-Host "  2. Run 'claude-work', complete onboarding, and /login with the work account."
Write-Host "     Exit that session cleanly so its .claude.json is written."
Write-Host "  3. Put a work-appropriate CLAUDE.md in $WorkDir (edited, not copied verbatim)."
Write-Host "  4. To bring existing work project state across, close every Claude Code session and run:"
Write-Host "       pwsh -File `"$(Join-Path $here 'migrate-workspaces.ps1')`""
Write-Host "     That step needs PowerShell 7: winget install Microsoft.PowerShell"
Write-Host ""
Write-Host "Verify with: claude-work then /status, and 'claude' in a directory under $WorkRoot."
