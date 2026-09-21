# Claude Code account switcher.
#
# Personal account uses the default config dir (~\.claude) and deliberately leaves
# CLAUDE_CONFIG_DIR *unset*: when the variable is set, Claude Code appends a hash of its
# value to the Windows Credential Manager service name, so pinning it to the default path
# would still address a different credential entry than the one already logged in.
#
# Work account uses ~\.claude-work, which isolates credentials, .claude.json, settings,
# CLAUDE.md, MCP registrations, project trust state and transcripts.

$script:ClaudeExe      = Join-Path $HOME '.local\bin\claude.exe'
$script:ClaudeWorkDir  = Join-Path $HOME '.claude-work'
$script:ClaudeWorkRoot = 'C:\Dev\Work'   # placeholder; profiles.config.ps1 is the real source

# profiles.config.ps1 carries the machine-specific values. The defaults above stand in when it is
# missing, so this script also works on its own.
$script:ClaudeConfigFile = Join-Path $PSScriptRoot 'profiles.config.ps1'
if (Test-Path -LiteralPath $script:ClaudeConfigFile) {
    . $script:ClaudeConfigFile
    if ($ClaudeWorkRoot) { $script:ClaudeWorkRoot = $ClaudeWorkRoot }
    if ($ClaudeWorkDir)  { $script:ClaudeWorkDir  = $ClaudeWorkDir }
}

function Get-ClaudeAccountForPath {
    param([string] $Path = $PWD.ProviderPath)

    try { $full = [IO.Path]::GetFullPath($Path) } catch { return 'personal' }
    $root = [IO.Path]::GetFullPath($script:ClaudeWorkRoot).TrimEnd('\')

    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'work' }

    return 'personal'
}

function Invoke-ClaudeAs {
    # The parameter is -Account rather than -Profile on purpose: a $Profile parameter would
    # shadow the automatic $PROFILE variable inside this scope.
    param(
        [Parameter(Mandatory)][ValidateSet('personal', 'work')][string] $Account,
        [string[]] $ClaudeArgs
    )

    if (-not (Test-Path -LiteralPath $script:ClaudeExe)) {
        Write-Error "claude.exe not found at $script:ClaudeExe"
        return
    }

    $had   = Test-Path Env:\CLAUDE_CONFIG_DIR
    $saved = $env:CLAUDE_CONFIG_DIR
    try {
        if ($Account -eq 'work') { $env:CLAUDE_CONFIG_DIR = $script:ClaudeWorkDir }
        else { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }

        & $script:ClaudeExe @ClaudeArgs
    }
    finally {
        if ($had) { $env:CLAUDE_CONFIG_DIR = $saved }
        else { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}

function claude {
    # An inherited CLAUDE_CONFIG_DIR means we are nested inside an existing session; stay on
    # whichever account that session belongs to instead of re-deciding from the directory.
    if (Test-Path Env:\CLAUDE_CONFIG_DIR) { & $script:ClaudeExe @args; return }

    Invoke-ClaudeAs -Account (Get-ClaudeAccountForPath) -ClaudeArgs $args
}

function claude-work     { Invoke-ClaudeAs -Account work     -ClaudeArgs $args }
function claude-personal { Invoke-ClaudeAs -Account personal -ClaudeArgs $args }
