$ErrorActionPreference = 'SilentlyContinue'
$json = [Console]::In.ReadToEnd()
$data = $json | ConvertFrom-Json

# --- appearance ---------------------------------------------------------------------------------

# Colour the account tag, the separators, and the numbers that matter as they approach a limit.
# Set to $false for plain text.
$UseColor = $true

# Which accounts get the usage line: 'all', 'work', 'personal' or 'none'.
$BudgetAccounts = 'all'

# SGR foreground codes for the account tag. The standard 3x set rather than the bright 9x one:
# the tag is a label, not an alert, and the host's dim does not knock 9x back far enough to stop
# it shouting. Step down further with '2;36' (faint cyan) if it is still too present; that needs
# '22;39' to unwind, so change $TagReset with it.
$TagColors = @{ personal = '36'; work = '33'; other = '35' }
$TagReset  = '39'

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

# Mirrors how the CLI resolves its global config file:
#   <CLAUDE_CONFIG_DIR>\.config.json when that exists, otherwise
#   <CLAUDE_CONFIG_DIR, or $HOME when unset>\.claude.json
function Get-GlobalConfigPath {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
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

# A seat's spend limit (Enterprise usage-based billing) is not part of the status-line payload,
# only of the CLI's own usage cache in .claude.json. That cache is refreshed off API responses at
# most once every five minutes, so it lags a little; the CLI stops trusting it after an hour.
function Get-SpendSegment {
    $path = Get-GlobalConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    # Deliberately not ConvertFrom-Json: .claude.json holds project keys differing only in case,
    # which the parser rejects, and -AsHashtable does not exist in Windows PowerShell 5.1.
    $raw = Read-Shared $path
    if (-not $raw) { return $null }

    $cacheAt = $raw.IndexOf('"cachedUsageUtilization"')
    if ($cacheAt -lt 0) { return $null }

    $spendAt = $raw.IndexOf('"spend":', $cacheAt)
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
    $segment = 'Spend ' + (Colorize $text (Get-ThresholdColor $percent 50 80))

    $header = $raw.Substring($cacheAt, [Math]::Min(200, $raw.Length - $cacheAt))
    $fetched = [regex]::Match($header, '"fetchedAtMs"\s*:\s*(\d+)')
    if ($fetched.Success) {
        $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds([int64] $fetched.Groups[1].Value)
        if ($age.TotalHours -ge 1) { $segment += ' stale' }
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
    $context = 'Context: ' + (Colorize "$([int] $usedPercent)%" (Get-ThresholdColor ([double] $usedPercent) 70 85))
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
    if ($spend) { $usage += $spend }

    # Absent for API-key auth, for seats billed against a spend limit, and for subscribers until
    # the first API response of the session.
    foreach ($window in @(@('5h', $data.rate_limits.five_hour), @('7d', $data.rate_limits.seven_day))) {
        $label = $window[0]
        $limit = $window[1]
        if ($null -eq $limit -or $null -eq $limit.used_percentage) { continue }

        $usedPct = [double] $limit.used_percentage
        $left = 100 - [int] [Math]::Round($usedPct)
        $text = (Colorize "$left% left" (Get-ThresholdColor $usedPct 70 90))
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
