<#
.SYNOPSIS
    Copies the work workspaces' Claude Code state from the personal profile into the work profile.

.DESCRIPTION
    Run this ONCE, from a plain PowerShell 7 terminal, after the work profile has been logged in at
    least once (so that <work config dir>\.claude.json exists).

    It copies, never moves: the personal profile is opened read-only and keeps everything, so it
    stays able to /resume the same sessions.

      * <personal>\projects\*  for projects under the work root   -> <work>\projects\
        (session transcripts, and the per-project memory\ directories that live alongside them)
      * .claude.json "projects" entries under the work root
        (directory trust, allowedTools, per-project MCP toggles, lastSessionId)
      * the user-scope MCP servers named in $ClaudeMcpServersToCopy, with their headers intact

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

# --- transcripts and project memories --------------------------------------------------------------
# Project directory names are the project path with every non-alphanumeric character replaced by a
# hyphen, so the work root maps to a name prefix. Matching on that prefix rather than on a bare
# substring keeps an unrelated project whose name merely contains the same word from being swept in.
#
# The character class has to be the full negated-alphanumeric one, not just separators: a work root
# containing a space ('C:\Dev\Acme Corp') lands on disk as 'C--Dev-Acme-Corp-...', and a prefix that
# kept the space would match nothing and report zero copies without failing.
$sourceProjects = Join-Path $PersonalDir 'projects'
$targetProjects = Join-Path $WorkDir 'projects'
New-Item -ItemType Directory -Path $targetProjects -Force | Out-Null

$prefix = ($WorkRoot -replace '[^A-Za-z0-9]', '-')
$directories = Get-ChildItem -LiteralPath $sourceProjects -Directory |
               Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }

foreach ($directory in $directories) {
    Copy-Item -LiteralPath $directory.FullName -Destination $targetProjects -Recurse -Force
}
if ($directories.Count -eq 0) {
    Write-Warning "No project directories under '$WorkRoot' (looked for names starting '$prefix')."
}
else { Write-Host "Copied $($directories.Count) project directories into $targetProjects" }

# --- .claude.json merge ----------------------------------------------------------------------------
$personal = Get-Content -LiteralPath $personalJson -Raw | ConvertFrom-Json -AsHashtable
$work     = Get-Content -LiteralPath $workJson     -Raw | ConvertFrom-Json -AsHashtable

if (-not $work.ContainsKey('projects'))   { $work['projects']   = @{} }
if (-not $work.ContainsKey('mcpServers')) { $work['mcpServers'] = @{} }

# Project keys are stored with mixed separators and mixed drive-letter case, so compare normalised
# forms rather than doing a literal prefix test.
$rootNormalised = $WorkRoot.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
$copied = 0
foreach ($key in $personal['projects'].Keys) {
    $normalised = $key.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    if ($normalised -eq $rootNormalised -or $normalised.StartsWith($rootNormalised + '\')) {
        $work['projects'][$key] = $personal['projects'][$key]
        $copied++
    }
}
Write-Host "Merged $copied project entries"

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
