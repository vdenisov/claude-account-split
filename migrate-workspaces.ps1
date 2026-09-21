<#
.SYNOPSIS
    Copies the work workspaces' Claude Code state from the personal profile into the work profile.

.DESCRIPTION
    Run this ONCE, from a plain PowerShell 7 terminal, after the work profile has been logged in at
    least once (so that <work config dir>\.claude.json exists).

    It copies, never moves: the personal profile is opened read-only and keeps everything, so it
    stays able to /resume the same sessions.

      * .claude.json "projects" entries under the work root
        (directory trust, allowedTools, per-project MCP toggles, lastSessionId)
      * <personal>\projects\<dir> for each of those entries        -> <work>\projects\
        (session transcripts, and the per-project memory\ directories that live alongside them)
      * the user-scope MCP servers named in $ClaudeMcpServersToCopy, with their headers intact

    Transcript directories are chosen through the project entries, never by matching directory names
    against the work root: the names are a lossy encoding of the path, so a sibling such as
    'Acme Corp Archive' is indistinguishable by name from a subdirectory of 'Acme Corp'. Directories
    that resemble the work root but belong to no project under it are listed, not copied.

    Re-running is safe: it overwrites the same entries with the current personal values.

.PARAMETER Force
    Skip the check that no Claude Code process is running. Only for the case where you are certain
    the running process is not one of these two profiles.

.EXAMPLE
    .\migrate-workspaces.ps1

.EXAMPLE
    .\migrate-workspaces.ps1 -WorkRoot 'D:\src\acme' -McpServers @('context7')

.NOTES
    Must not run while any Claude Code session is open against either profile: the CLI rewrites
    .claude.json on exit and would clobber the merge.
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [string] $PersonalDir = (Join-Path $HOME '.claude'),
    [string] $WorkDir,
    [string] $WorkRoot,
    [string[]] $McpServers
)

$ErrorActionPreference = 'Stop'

# ConvertFrom-Json -AsHashtable is PowerShell 6+, and .claude.json cannot be parsed without it: it
# holds keys differing only in case ("C:/Dev/..." and "c:/Dev/...").
if ($PSVersionTable.PSVersion.Major -lt 6) {
    throw "Run this under PowerShell 7 (pwsh); -AsHashtable is unavailable in Windows PowerShell 5.1."
}

# Defaults come from profiles.config.ps1 so this agrees with the switcher and the status line.
$ClaudeWorkDir = Join-Path $HOME '.claude-work'
$ClaudeWorkRoot = 'C:\Dev\Work'
$ClaudeMcpServersToCopy = @()

$configFile = Join-Path $PSScriptRoot 'profiles.config.ps1'
if (Test-Path -LiteralPath $configFile) { . $configFile }

if (-not $WorkDir)    { $WorkDir = $ClaudeWorkDir }
if (-not $WorkRoot)   { $WorkRoot = $ClaudeWorkRoot }
if (-not $McpServers) { $McpServers = $ClaudeMcpServersToCopy }

if (-not $Force) {
    $running = Get-Process -Name claude -ErrorAction SilentlyContinue
    if ($running) {
        throw ("Claude Code is running (PID {0}). Close every session first, or pass -Force." -f `
               ($running.Id -join ', '))
    }
}

$personalJson = Join-Path (Split-Path -Parent $PersonalDir) '.claude.json'
$workJson     = Join-Path $WorkDir '.claude.json'

foreach ($path in @($personalJson, $workJson)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Not found: $path. Launch 'claude-work' and log in once before running this."
    }
}

# --- backup --------------------------------------------------------------------------------------
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$workJson.$stamp.bak"
Copy-Item -LiteralPath $workJson -Destination $backup
Write-Host "Backed up work .claude.json -> $backup"

# --- which projects belong to the work root ---------------------------------------------------------
$personal = Get-Content -LiteralPath $personalJson -Raw | ConvertFrom-Json -AsHashtable
$work     = Get-Content -LiteralPath $workJson     -Raw | ConvertFrom-Json -AsHashtable

if (-not $work.ContainsKey('projects'))   { $work['projects']   = @{} }
if (-not $work.ContainsKey('mcpServers')) { $work['mcpServers'] = @{} }

# Project keys are stored with mixed separators and mixed drive-letter case, so compare normalised
# forms rather than doing a literal prefix test. Requiring the separator after the root is what keeps
# a sibling such as 'C:\Dev\Acme Corp Archive' out.
$rootNormalised = $WorkRoot.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
$workKeys = @($personal['projects'].Keys | Where-Object {
    $normalised = $_.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    $normalised -eq $rootNormalised -or $normalised.StartsWith($rootNormalised + '\')
})

# --- transcripts and project memories --------------------------------------------------------------
# A project's directory under projects\ is its path with every non-alphanumeric character replaced by
# a hyphen. That encoding is lossy -- 'C:\Dev\Acme Corp Archive' and 'C:\Dev\Acme Corp\Archive' both
# start 'C--Dev-Acme-Corp-' -- so directories are not picked by matching their names against the work
# root. Each one is derived instead from a project entry selected above, where the path is still
# intact, and looked up by its exact name. Sort -Unique folds the drive-letter case variants, which
# name the same directory on a case-insensitive filesystem.
$sourceProjects = Join-Path $PersonalDir 'projects'
$targetProjects = Join-Path $WorkDir 'projects'
New-Item -ItemType Directory -Path $targetProjects -Force | Out-Null

$names = @($workKeys | ForEach-Object { $_ -replace '[^A-Za-z0-9]', '-' } | Sort-Object -Unique)
$copiedDirectories = 0
foreach ($name in $names) {
    # A project that was opened but never ran a session has an entry and no directory.
    $source = Join-Path $sourceProjects $name
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
    Copy-Item -LiteralPath $source -Destination $targetProjects -Recurse -Force
    $copiedDirectories++
}
if ($copiedDirectories -eq 0) {
    Write-Warning "No project directories found for the $($workKeys.Count) project entries under '$WorkRoot'."
}
else { Write-Host "Copied $copiedDirectories project directories into $targetProjects" }

# Directories whose names start like the work root's but that no work project entry accounts for: a
# sibling that shares the root's prefix, or a directory whose .claude.json entry is gone. Reported,
# not guessed at -- copy one across by hand if it does belong to the work account.
if (Test-Path -LiteralPath $sourceProjects) {
    $prefix = $WorkRoot -replace '[^A-Za-z0-9]', '-'
    $unclaimed = @(Get-ChildItem -LiteralPath $sourceProjects -Directory | Where-Object {
        $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $names -notcontains $_.Name
    })
    foreach ($directory in $unclaimed) {
        Write-Warning "Not copied: projects\$($directory.Name) resembles the work root but matches no project under it."
    }
}

# --- .claude.json merge ----------------------------------------------------------------------------
foreach ($key in $workKeys) { $work['projects'][$key] = $personal['projects'][$key] }
Write-Host "Merged $($workKeys.Count) project entries"

if ($McpServers) {
    foreach ($name in $McpServers) {
        if ($personal['mcpServers'].ContainsKey($name)) {
            $work['mcpServers'][$name] = $personal['mcpServers'][$name]
            Write-Host "Merged MCP server '$name'"
        }
        else { Write-Warning "MCP server '$name' not found in the personal profile; skipped" }
    }
}
else {
    $available = ($personal['mcpServers'].Keys | Sort-Object) -join ', '
    Write-Host "No MCP servers requested. Available in the personal profile: $available"
}

$work | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $workJson -Encoding utf8NoBOM
Write-Host "Wrote $workJson"
Write-Host "Done. Start 'claude-work' and check /mcp, and /resume in one of the migrated projects."
