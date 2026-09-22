$ErrorActionPreference = 'SilentlyContinue'
$json = [Console]::In.ReadToEnd()
$data = $json | ConvertFrom-Json

# --- appearance ---------------------------------------------------------------------------------

# Colour the account tag, the separators, and the numbers that matter as they approach a limit.
# Set to $false for plain text.
$UseColor = $true

# Which accounts get the usage line: 'all', 'work', 'personal' or 'none'.
$BudgetAccounts = 'all'

# Launch refresh-usage.ps1 when the spend figures go older than this many minutes. Set
# $AutoRefreshUsage to $false to leave the figures to whatever the CLI last cached, which only
# moves when you open /usage.
$AutoRefreshUsage = $true
$UsageRefreshMinutes = 10

# SGR foreground codes for the account tag. The standard 3x set rather than the bright 9x one:
# the tag is a label, not an alert, and the host's dim does not knock 9x back far enough to stop
# it shouting. Step down further with '2;36' (faint cyan) if it is still too present; that needs
# '22;39' to unwind, so change $TagReset with it.
$TagColors = @{ personal = '36'; work = '33'; other = '35' }
$TagReset  = '39'

# Where each figure turns yellow, then red: @(warn, danger).
#
# The budget ones sit high on purpose. A colour that appears at half a budget spent is on for most
# of the month and stops meaning anything; these are set to fire when there is genuinely something
# to react to. Context is different -- it warns about a compaction coming up, not a limit -- so it
# keeps its own lower pair.
$Thresholds = @{
    spend    = @(75, 90)   # percent of the seat's spend limit used
    window   = @(75, 90)   # percent of a 5-hour or 7-day rate-limit window used
    context  = @(70, 85)   # percent of the context window used
    ageHours = @(6, 24)    # how old the cached spend figure is, in hours
}

# Machine-specific values, shared with claude-switch.ps1. The defaults here stand in when
# profiles.config.ps1 is missing.
$ClaudeWorkDir = Join-Path $HOME '.claude-work'
$ClaudeAccountLabels = @{ personal = 'Personal'; work = 'Work' }

$configFile = Join-Path $PSScriptRoot 'profiles.config.ps1'
if (Test-Path -LiteralPath $configFile) { . $configFile }

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Esc = [char] 27

# Colour runs end with SGR 39 (default foreground), never SGR 0: the host renders the whole status
# line with dimColor, and a full reset would cancel that dim for the rest of the line.
function Colorize([string] $text, [string] $sgr, [string] $reset = '39') {
    if (-not $UseColor -or -not $sgr) { return $text }
    return "$Esc[${sgr}m$text$Esc[${reset}m"
}

function Get-ThresholdColor([double] $value, [double] $warn, [double] $danger) {
    if ($value -ge $danger) { return '91' }   # bright red
    if ($value -ge $warn)   { return '93' }   # bright yellow
    return $null
}

# --- formatting helpers -------------------------------------------------------------------------

function Format-Tokens($n) {
    if ($n -ge 1000000) { return [string]::Format($Inv, '{0:N2}M', $n / 1000000.0) }
    if ($n -ge 1000)    { return [string]::Format($Inv, '{0:N1}k', $n / 1000.0) }
    return "$n"
}

# Cents only when there are cents to show: $200, but $12.40.
function Format-Money([string] $symbol, [double] $amount) {
    $format = if ([Math]::Abs($amount - [Math]::Truncate($amount)) -lt 0.005) { '{0}{1:N0}' } else { '{0}{1:N2}' }
    return [string]::Format($Inv, $format, $symbol, $amount)
}

# "Opus 5 (1M context)" -> "Opus 5 1M". The parenthesised context size is the only long part of a
# display name, and the parentheses carry nothing once the effort level follows in its own pair.
function Format-Model([string] $name) {
    if (-not $name) { return $null }
    return ($name -replace '\(\s*(\d+(?:\.\d+)?[kKmM])\s*context\s*\)', '$1').Trim()
}

# Time left until a rate-limit window resets, from a Unix epoch-seconds timestamp.
function Format-Reset($epochSeconds) {
    if ($null -eq $epochSeconds) { return $null }
    $span = [DateTimeOffset]::FromUnixTimeSeconds([int64] $epochSeconds) - [DateTimeOffset]::UtcNow
    if ($span.TotalMinutes -lt 1) { return 'now' }
    if ($span.TotalHours   -lt 1) { return '{0}m' -f [int] $span.TotalMinutes }
    if ($span.TotalDays    -lt 1) { return '{0}h{1:00}m' -f [int] $span.TotalHours, $span.Minutes }
    return '{0}d{1}h' -f [int] $span.TotalDays, $span.Hours
}

# --- account identity ---------------------------------------------------------------------------

# Statusline commands inherit the CLI's environment, so CLAUDE_CONFIG_DIR identifies the account.
# Unset means the default config dir, which is the personal profile.
function Get-Account {
    $configDir = $env:CLAUDE_CONFIG_DIR
    if (-not $configDir) { return 'personal' }
    $work = [IO.Path]::GetFullPath($ClaudeWorkDir).TrimEnd('\')
    try { $current = [IO.Path]::GetFullPath($configDir).TrimEnd('\') } catch { return 'personal' }
    if ($current.Equals($work, [StringComparison]::OrdinalIgnoreCase)) { return 'work' }
    return (Split-Path -Leaf $current)
}

function Format-AccountTag([string] $account) {
    switch ($account) {
        'personal' { return (Colorize "[$($ClaudeAccountLabels.personal)]" $TagColors.personal $TagReset) }
        'work'     { return (Colorize "[$($ClaudeAccountLabels.work)]"     $TagColors.work     $TagReset) }
        default    { return (Colorize "[$account]"                         $TagColors.other    $TagReset) }
    }
}

# --- spend limit --------------------------------------------------------------------------------

# The active profile's config directory, resolved the way the CLI resolves it.
$ClaudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }

# Mirrors how the CLI resolves its global config file:
#   <CLAUDE_CONFIG_DIR>\.config.json when that exists, otherwise
#   <CLAUDE_CONFIG_DIR, or $HOME when unset>\.claude.json
function Get-GlobalConfigPath {
    $configDir = $ClaudeConfigDir
    $alt = Join-Path $configDir '.config.json'
    if (Test-Path -LiteralPath $alt) { return $alt }
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $HOME }
    return (Join-Path $root '.claude.json')
}

# Shared read, so this never collides with the CLI rewriting the file.
function Read-Shared([string] $path) {
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
}

# Returns the JSON object starting at $start, brace-balanced and quote-aware, so a string value
# containing a brace cannot end the block early.
function Get-JsonBlock([string] $text, [int] $start) {
    $depth = 0; $inString = $false; $escaped = $false
    for ($i = $start; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inString) {
            if ($escaped)               { $escaped = $false }
            elseif ($c -eq [char] 0x5C) { $escaped = $true }
            elseif ($c -eq '"')         { $inString = $false }
            continue
        }
        if ($c -eq '"')     { $inString = $true }
        elseif ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $text.Substring($start, $i - $start + 1) } }
    }
    return $null
}

# Picks the fresher of two sources for the usage figures, and returns its raw text plus the epoch
# milliseconds it was fetched at:
#
#   * .claude.json's cachedUsageUtilization, which the CLI only refreshes when something asks for
#     usage status -- in practice, when you open /usage. It can be days old.
#   * statusline-usage.json, written by refresh-usage.ps1 on whatever cadence you wired it to.
#
# Neither is required. With no refresher installed this degrades to exactly the old behaviour.
function Get-UsageSource {
    $candidates = @()

    $configPath = Get-GlobalConfigPath
    if (Test-Path -LiteralPath $configPath) {
        $raw = Read-Shared $configPath
        $cacheAt = if ($raw) { $raw.IndexOf('"cachedUsageUtilization"') } else { -1 }
        if ($cacheAt -ge 0) {
            $header = $raw.Substring($cacheAt, [Math]::Min(200, $raw.Length - $cacheAt))
            $stamp = [regex]::Match($header, '"fetchedAtMs"\s*:\s*(\d+)')
            $candidates += [pscustomobject] @{
                Text        = $raw.Substring($cacheAt)
                FetchedAtMs = if ($stamp.Success) { [int64] $stamp.Groups[1].Value } else { 0 }
            }
        }
    }

    $sidePath = Join-Path $ClaudeConfigDir 'statusline-usage.json'
    if (Test-Path -LiteralPath $sidePath) {
        $raw = Read-Shared $sidePath
        if ($raw) {
            $stamp = [regex]::Match($raw, '"fetchedAtMs"\s*:\s*(\d+)')
            $candidates += [pscustomobject] @{
                Text        = $raw
                FetchedAtMs = if ($stamp.Success) { [int64] $stamp.Groups[1].Value } else { 0 }
            }
        }
    }

    if (-not $candidates) { return $null }
    return ($candidates | Sort-Object FetchedAtMs -Descending)[0]
}

# Kicks off a detached refresh when the figures have gone stale.
#
# The trigger lives here rather than in a Stop hook because the status line already pays for a
# process on every render: when nothing is due this costs one file stat, whereas a hook would add
# a whole process start to the end of every turn. It also means refreshes happen while you are
# actually using Claude Code, and never when you are not.
#
# The marker file is touched before spawning, so a burst of renders cannot start a burst of
# fetches, and a failing fetch backs off for the full interval instead of retrying every frame.
function Start-UsageRefresh {
    if (-not $AutoRefreshUsage) { return }

    $script = Join-Path $PSScriptRoot 'refresh-usage.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }

    $attempt = Join-Path $ClaudeConfigDir 'statusline-usage.attempt'
    if (Test-Path -LiteralPath $attempt) {
        $age = ([DateTime]::Now - (Get-Item -LiteralPath $attempt).LastWriteTime).TotalMinutes
        if ($age -lt $UsageRefreshMinutes) { return }
    }
    New-Item -ItemType File -Path $attempt -Force | Out-Null

    # One quoted string, not an array: with an array the quotes are passed through literally and
    # -File rejects them as illegal path characters, while without quotes any space in the path
    # splits the argument. Both paths here can contain spaces.
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoSpawn -Force -ConfigDir "{1}"' -f
                 $script, $ClaudeConfigDir
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arguments | Out-Null
}

# A seat's spend limit (Enterprise usage-based billing) never arrives in the status-line payload;
# it has to be read from whichever cache is freshest.
function Get-SpendSegment {
    $source = Get-UsageSource
    if (-not $source) { return $null }
    $raw = $source.Text

    # Deliberately not ConvertFrom-Json for the .claude.json case: it holds project keys differing
    # only in case, which the parser rejects, and -AsHashtable does not exist in PowerShell 5.1.
    $spendAt = $raw.IndexOf('"spend":')
    if ($spendAt -lt 0) { return $null }

    $block = Get-JsonBlock $raw $raw.IndexOf('{', $spendAt)
    if (-not $block -or $block -notmatch '"enabled"\s*:\s*true') { return $null }

    $used  = [regex]::Match($block, '"used"\s*:\s*\{[^}]*?"amount_minor"\s*:\s*(-?\d+)')
    $limit = [regex]::Match($block, '"limit"\s*:\s*\{[^}]*?"amount_minor"\s*:\s*(-?\d+)')
    if (-not $used.Success -or -not $limit.Success) { return $null }

    $exponent = 2
    $exp = [regex]::Match($block, '"exponent"\s*:\s*(\d+)')
    if ($exp.Success) { $exponent = [int] $exp.Groups[1].Value }
    $scale = [Math]::Pow(10, $exponent)

    $symbol = '$'
    $currency = [regex]::Match($block, '"currency"\s*:\s*"([A-Za-z]{3})"')
    if ($currency.Success) {
        switch ($currency.Groups[1].Value.ToUpperInvariant()) {
            'USD'   { $symbol = '$' }
            'EUR'   { $symbol = [string][char] 0x20AC }
            'GBP'   { $symbol = [string][char] 0x00A3 }
            default { $symbol = $currency.Groups[1].Value + ' ' }
        }
    }

    $usedAmount  = [double] $used.Groups[1].Value  / $scale
    $limitAmount = [double] $limit.Groups[1].Value / $scale

    $percent = if ($limitAmount -gt 0) { 100 * $usedAmount / $limitAmount } else { 0 }
    $reported = [regex]::Match($block, '"percent"\s*:\s*([0-9.]+)')
    if ($reported.Success) { $percent = [double]::Parse($reported.Groups[1].Value, $Inv) }

    $text = '{0}/{1}' -f (Format-Money $symbol $usedAmount), (Format-Money $symbol $limitAmount)
    $segment = 'Spend ' + (Colorize $text (Get-ThresholdColor $percent $Thresholds.spend[0] $Thresholds.spend[1]))

    # Age is worth showing rather than hiding: without a refresher wired up, this figure only moves
    # when you open /usage, and a spend number that silently lags by a day is worse than no number.
    if ($source.FetchedAtMs -gt 0) {
        $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds($source.FetchedAtMs)
        if ($age.TotalHours -ge 1) {
            $label = if ($age.TotalDays -ge 1) { '{0}d old' -f [int] $age.TotalDays }
                     else { '{0}h old' -f [int] $age.TotalHours }
            $segment += ' ' + (Colorize $label (Get-ThresholdColor $age.TotalHours $Thresholds.ageHours[0] $Thresholds.ageHours[1]))
        }
    }

    return $segment
}

# --- line one: identity and session state -------------------------------------------------------

$account = Get-Account
$head = @()

$dir = Split-Path -Leaf $data.workspace.current_dir
if ($dir) { $head += $dir }

$model = Format-Model $data.model.display_name
$effort = $data.effort.level
if ($model) {
    if ($effort) { $head += "$model ($effort)" } else { $head += $model }
}

$usedPercent = $data.context_window.used_percentage
if ($null -ne $usedPercent) {
    $context = 'Context: ' + (Colorize "$([int] $usedPercent)%" (Get-ThresholdColor ([double] $usedPercent) $Thresholds.context[0] $Thresholds.context[1]))
    $totalTokens = [int64] $data.context_window.total_input_tokens + [int64] $data.context_window.total_output_tokens
    if ($totalTokens -gt 0) { $context += " [$(Format-Tokens $totalTokens)]" }
    $head += $context
}

# --- line two: usage ----------------------------------------------------------------------------

$showUsage = switch ($BudgetAccounts) {
    'all'   { $true }
    'none'  { $false }
    default { $account -eq $BudgetAccounts }
}

$usage = @()
if ($showUsage) {
    $cost = $data.cost.total_cost_usd
    if ($null -ne $cost) { $usage += 'Session ' + (Format-Money '$' ([double] $cost)) }

    $spend = Get-SpendSegment
    if ($spend) {
        $usage += $spend
        # Only worth refreshing for a seat that actually has a spend limit; a plain subscription
        # gets its windows live from the payload and has nothing to fetch.
        Start-UsageRefresh
    }

    # Absent for API-key auth, for seats billed against a spend limit, and for subscribers until
    # the first API response of the session.
    foreach ($window in @(@('5h', $data.rate_limits.five_hour), @('7d', $data.rate_limits.seven_day))) {
        $label = $window[0]
        $limit = $window[1]
        if ($null -eq $limit -or $null -eq $limit.used_percentage) { continue }

        $usedPct = [double] $limit.used_percentage
        $left = 100 - [int] [Math]::Round($usedPct)
        $text = (Colorize "$left% left" (Get-ThresholdColor $usedPct $Thresholds.window[0] $Thresholds.window[1]))
        $reset = Format-Reset $limit.resets_at
        if ($reset) { $usage += "$label $text ($reset)" } else { $usage += "$label $text" }
    }
}

# --- render -------------------------------------------------------------------------------------

$join = ' ' + (Colorize ([string][char] 0x00B7) '90') + ' '

# The tag joins with a plain space rather than a separator: it labels the line, it is not one of
# the fields on it.
$lines = @(((Format-AccountTag $account) + ' ' + ($head -join $join)).TrimEnd())
if ($usage.Count -gt 0) { $lines += '  ' + ($usage -join $join) }

[Console]::Out.Write($lines -join "`n")
