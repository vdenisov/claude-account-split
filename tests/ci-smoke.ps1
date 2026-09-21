<#
.SYNOPSIS
    End-to-end smoke test: installs the split for real, twice, and checks what it produced.

.DESCRIPTION
    Writes to $HOME, to both PowerShell profiles and to C:\, so it refuses to run anywhere but a
    GitHub Actions runner, which is thrown away afterwards. Runs under whichever PowerShell edition
    invokes it; the workflow calls it from both, and every child process it starts is that same
    edition -- except the status line, which settings.json always launches with powershell.exe.

    The fixtures reproduce the conditions that have broken the scripts before: a work root with
    spaces in it, a personal settings.json with no statusLine, an empty profile file, a profile
    carrying a switcher line from an earlier layout, and .claude.json keys differing only in case.
#>
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true') {
    throw "ci-smoke.ps1 installs into the real user profile; it only runs on a GitHub Actions runner."
}

$repo    = Split-Path -Parent $PSScriptRoot
$shell   = (Get-Process -Id $PID).Path
$isCore  = $PSVersionTable.PSVersion.Major -ge 6
$edition = if ($isCore) { 'PowerShell 7' } else { 'Windows PowerShell 5.1' }
$script:failures = 0

function Check([string] $name, [bool] $ok, [string] $detail = '') {
    if ($ok) { Write-Host "  PASS  $name" }
    else {
        $script:failures++
        Write-Host "  FAIL  $name"
        Write-Host "::error::[$edition] $name$(if ($detail) { " -- $detail" })"
    }
}

function Section([string] $title) { Write-Host ""; Write-Host "=== $title" }

# Runs a script block in a fresh process of this edition, with the user profile loaded, and returns
# its output parsed from JSON. Encoded, so no quoting survives or breaks on the way through.
function Invoke-Fresh([string] $code) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $out = & $shell -NoLogo -ExecutionPolicy Bypass -EncodedCommand $encoded
    return ($out -join "`n") | ConvertFrom-Json
}

# Runs one of the repo's scripts in a child process of this edition and captures everything it
# prints. The local 'Continue' matters under 5.1: there, a child writing to stderr through 2>&1
# while the preference is 'Stop' becomes a terminating error, which would abort this test at the
# very point where a script is expected to fail loudly (migration refusing to run under 5.1).
function Invoke-RepoScript([string] $name, [string[]] $arguments = @()) {
    $ErrorActionPreference = 'Continue'
    $output = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo $name) @arguments 2>&1
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host "    | $_" }
    return [pscustomobject] @{ Output = @($output | ForEach-Object { "$_" }); ExitCode = $code }
}

function Read-Bytes([string] $path) { return [IO.File]::ReadAllBytes($path) }
function Test-Bom([string] $path) {
    $b = Read-Bytes $path
    return $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
}

$root       = 'C:\ci work\Acme Corp'
$personal   = Join-Path $HOME '.claude'
$work       = Join-Path $HOME '.claude-work'
$documents  = [Environment]::GetFolderPath('MyDocuments')
$profile7   = Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1'
$profile51  = Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
$switcher   = Join-Path $repo 'claude-switch.ps1'
$statusLine = Join-Path $repo 'statusline-command.ps1'

Write-Host "Edition: $edition ($($PSVersionTable.PSVersion))  Shell: $shell"

# --- parse -----------------------------------------------------------------------------------------
# Under this edition's own parser: 5.1 rejects syntax that 7 accepts.
Section "Every script parses"
foreach ($file in Get-ChildItem -LiteralPath $repo -Filter *.ps1 -Recurse) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $errors)
    Check $file.Name (-not $errors) (($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')
}

# --- fixtures --------------------------------------------------------------------------------------
Section "Fixtures"
New-Item -ItemType Directory -Force -Path (Join-Path $root 'repo-a') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $personal 'skills\demo') | Out-Null
Set-Content -LiteralPath (Join-Path $personal 'skills\demo\SKILL.md') -Value 'demo'

# No statusLine: the case where seeding used to leave the work profile without an account tag.
'{ "theme": "dark", "model": "opus" }' | Set-Content -LiteralPath (Join-Path $personal 'settings.json')

# An empty PowerShell 7 profile, which is what removing a stale switcher line leaves behind; it used
# to crash the profile step. The 5.1 profile is left absent to cover the create path.
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $profile7) | Out-Null
[IO.File]::WriteAllText($profile7, '')
if (Test-Path -LiteralPath $profile51) { Remove-Item -LiteralPath $profile51 }
Write-Host "  work root '$root', personal settings without statusLine, empty PS7 profile, no 5.1 profile"

# --- install, twice --------------------------------------------------------------------------------
Section "install.ps1, first run"
$first = Invoke-RepoScript 'install.ps1' @('-WorkRoot', $root, '-Seed')
Check "exits 0" ($first.ExitCode -eq 0) "exit code $($first.ExitCode)"

Section "install.ps1, second run (idempotent)"
$second = Invoke-RepoScript 'install.ps1' @('-WorkRoot', $root, '-Seed')
Check "exits 0" ($second.ExitCode -eq 0) "exit code $($second.ExitCode)"
$acted = @($second.Output | Where-Object { $_ -like '==>*' })
Check "changes nothing" ($acted.Count -eq 0) ($acted -join '; ')

# --- what the installer wrote ----------------------------------------------------------------------
Section "Installed state"
$config = Get-Content -LiteralPath (Join-Path $repo 'profiles.config.ps1') -Raw
Check "profiles.config.ps1 carries the work root" ($config.Contains("'$root'"))

foreach ($pair in @(@('personal', (Join-Path $personal 'settings.json')), @('work', (Join-Path $work 'settings.json')))) {
    $label = $pair[0]; $path = $pair[1]
    Check "$label settings.json exists" (Test-Path -LiteralPath $path)
    Check "$label settings.json has no BOM" (-not (Test-Bom $path))
    $json = $null
    try { $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { }
    Check "$label settings.json is valid JSON" ($null -ne $json)
    Check "$label status line points at the shared script" ($json.statusLine.command -like "*`"$statusLine`"")
    Check "$label settings.json keeps the personal keys" ($json.theme -eq 'dark' -and $json.model -eq 'opus')
}
Check "skills seeded into the work profile" (Test-Path -LiteralPath (Join-Path $work 'skills\demo\SKILL.md'))

foreach ($path in @($profile7, $profile51)) {
    $text = [IO.File]::ReadAllText($path)
    $count = ([regex]::Matches($text, [regex]::Escape($switcher))).Count
    Check "$(Split-Path -Leaf (Split-Path -Parent $path)) profile loads the switcher exactly once" ($count -eq 1) "found $count"
}

# --- a fresh shell ---------------------------------------------------------------------------------
Section "Fresh $edition shell, profile loaded"
$probe = Invoke-Fresh @'
[pscustomobject] @{
    functions = @('claude', 'claude-work', 'claude-personal' |
                  Where-Object { Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue })
    underRoot = Get-ClaudeAccountForPath 'C:\ci work\Acme Corp\repo-a'
    atRoot    = Get-ClaudeAccountForPath 'C:\ci work\Acme Corp'
    sibling   = Get-ClaudeAccountForPath 'C:\ci work\Acme Corporate'
    elsewhere = Get-ClaudeAccountForPath 'C:\elsewhere\x'
} | ConvertTo-Json -Compress
'@
Check "claude / claude-work / claude-personal are defined" (@($probe.functions).Count -eq 3) (@($probe.functions) -join ', ')
Check "a repo under the work root routes to work" ($probe.underRoot -eq 'work') $probe.underRoot
Check "the work root itself routes to work" ($probe.atRoot -eq 'work') $probe.atRoot
Check "a sibling sharing the root's prefix routes to personal" ($probe.sibling -eq 'personal') $probe.sibling
Check "anywhere else routes to personal" ($probe.elsewhere -eq 'personal') $probe.elsewhere

# --- status line -----------------------------------------------------------------------------------
Section "Status line"
$ansi = [regex] ([string][char] 27 + '\[[0-9;]*m')
$payload = Get-Content -LiteralPath (Join-Path $repo 'statusline-payload.sample.json') -Raw
foreach ($case in @(@('Personal', $null), @('Work', $work))) {
    $env:CLAUDE_CONFIG_DIR = $case[1]
    $rendered = $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $statusLine
    $plain = $ansi.Replace(($rendered -join "`n"), '')
    Check "renders the [$($case[0])] tag" ($plain.StartsWith("[$($case[0])] ")) ($plain -split "`n")[0]
}
$env:CLAUDE_CONFIG_DIR = $null

# --- stale switcher line ---------------------------------------------------------------------------
# A dot-source of claude-switch.ps1 from some other path must be reported, not taken for a working
# install and not stacked on.
Section "Stale switcher line in a profile"
$saved = [IO.File]::ReadAllText($profile51)
$staleLine = '. "$HOME\.claude-profiles\claude-switch.ps1"'
[IO.File]::WriteAllText($profile51, "$staleLine`r`n")
$stale = Invoke-RepoScript 'install.ps1' @('-WorkRoot', $root)
# Compared with all whitespace removed: the 5.1 host wraps a long warning at the console width, and
# on the runner the profile path is long enough to push the wrap into the middle of this phrase.
$squashed = ($stale.Output -join '') -replace '\s', ''
Check "is reported" ($squashed.Contains('dot-sourcesadifferentclaude-switch.ps1'))
Check "is left alone, with nothing added" ([IO.File]::ReadAllText($profile51) -eq "$staleLine`r`n")
[IO.File]::WriteAllText($profile51, $saved)

# --- migration -------------------------------------------------------------------------------------
Section "migrate-workspaces.ps1"
# Directory names are hardcoded as Claude Code writes them, not derived with the rule under test:
# every non-alphanumeric character, spaces included, becomes a hyphen.
$projects = Join-Path $personal 'projects'
foreach ($name in 'C--ci-work-Acme-Corp-repo-a', 'C--elsewhere-x') {
    New-Item -ItemType Directory -Force -Path (Join-Path $projects $name) | Out-Null
    Set-Content -LiteralPath (Join-Path $projects "$name\session.jsonl") -Value '{}'
}
# Keys differing only in case, as the real file has; plain ConvertFrom-Json rejects them.
@'
{
  "projects": {
    "C:/ci work/Acme Corp/repo-a": { "hasTrustDialogAccepted": true },
    "c:/ci work/Acme Corp/repo-a": { "hasTrustDialogAccepted": true },
    "C:/elsewhere/x": { "hasTrustDialogAccepted": true }
  },
  "mcpServers": {}
}
'@ | Set-Content -LiteralPath (Join-Path $HOME '.claude.json')
'{ "projects": {} }' | Set-Content -LiteralPath (Join-Path $work '.claude.json')

$migrate = Invoke-RepoScript 'migrate-workspaces.ps1'
$migrateExit = $migrate.ExitCode

if ($isCore) {
    Check "exits 0" ($migrateExit -eq 0) "exit code $migrateExit"
    $target = Join-Path $work 'projects'
    Check "copies the transcript dir under a work root with spaces" (Test-Path -LiteralPath (Join-Path $target 'C--ci-work-Acme-Corp-repo-a\session.jsonl'))
    Check "leaves the transcript dir outside the work root" (-not (Test-Path -LiteralPath (Join-Path $target 'C--elsewhere-x')))
    Check "leaves the personal copy in place" (Test-Path -LiteralPath (Join-Path $projects 'C--ci-work-Acme-Corp-repo-a\session.jsonl'))

    $merged = Get-Content -LiteralPath (Join-Path $work '.claude.json') -Raw | ConvertFrom-Json -AsHashtable
    $keys = @($merged['projects'].Keys)
    Check "merges both case variants of the work project" (($keys -ccontains 'C:/ci work/Acme Corp/repo-a') -and ($keys -ccontains 'c:/ci work/Acme Corp/repo-a')) ($keys -join ', ')
    Check "does not merge the project outside the work root" ($keys -notcontains 'C:/elsewhere/x') ($keys -join ', ')
}
else {
    Check "refuses to run under 5.1" ($migrateExit -ne 0) "exit code $migrateExit"
    Check "says PowerShell 7 is needed" (($migrate.Output -join '') -match 'PowerShell7|PowerShell 7')
}

# --- result ----------------------------------------------------------------------------------------
Write-Host ""
if ($script:failures) {
    Write-Host "$($script:failures) check(s) failed under $edition."
    exit 1
}
Write-Host "All checks passed under $edition."
# Explicit, because the runner's wrapper exits with $LASTEXITCODE, which still holds the code of the
# last child process -- under 5.1 that is the migration script refusing to run, as it should.
exit 0
