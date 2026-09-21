# Claude Code account split

Two separately authenticated Claude Code accounts on one Windows machine, both logged in at the
same time, selected automatically by working directory.

**To set this up, read [SETUP.md](SETUP.md).** This file explains why it is built the way it is —
the findings that shaped it, and the decisions that look arbitrary until you know what they avoid.

| | Personal | Work |
| --- | --- | --- |
| Config dir | `~\.claude` (`CLAUDE_CONFIG_DIR` unset) | `~\.claude-work` |
| Global config | `~\.claude.json` | `~\.claude-work\.claude.json` |
| Selected when | anywhere outside the work root | CWD at or under the work root |
| Forced by | `claude-personal` | `claude-work` |
| Status line tag | `[Personal]`, cyan | `[Work]`, yellow |

Both accounts share one binary (`~\.local\bin\claude.exe`) and one IDE lock-file directory
(`~\.claude\ide`, which the CLI falls back to whenever `CLAUDE_CONFIG_DIR` is set).

## Files

| | |
| --- | --- |
| `SETUP.md` | how to install it, verify it, and remove it |
| `install.ps1` | does the mechanical setup steps; idempotent |
| `profiles.config.ps1` | **local, not shared** — the only file you edit to adapt the split |
| `profiles.config.example.ps1` | the template the recipient fills in |
| `claude-switch.ps1` | the `claude` / `claude-work` / `claude-personal` functions |
| `statusline-command.ps1` | shared two-line status line for both profiles |
| `migrate-workspaces.ps1` | one-shot copy of work project state from personal to work |
| `statusline-payload.sample.json` | a captured status-line payload, for testing edits |
| `package.ps1` | builds a shareable zip of everything except the local config |
| `tests/ci-smoke.ps1` | end-to-end install check; **CI only** — it writes to the real user profile |
| `.github/workflows/ci.yml` | lint, then the smoke test under both 5.1 and 7 |
| `LICENSE` | MIT |

To try a status-line change without restarting a session:

```powershell
Get-Content statusline-payload.sample.json -Raw | powershell -NoProfile -File statusline-command.ps1
```

## Sharing this

Every file here except `profiles.config.ps1` is written to be handed to someone else — the scripts
carry neutral placeholder defaults and take their real values from that one config file.

```powershell
.\package.ps1                                     # -> claude-account-split.zip
.\package.ps1 -ExtraPatterns 'acmecorp', 'jdoe'   # also refuse on these
```

It excludes `profiles.config.ps1`, ships `profiles.config.example.ps1` in its place, then greps
what it staged for your Windows user name plus any extra patterns you name, and refuses to write
the zip if anything matches. Add your employer, internal hostnames, or anything else you would
rather not send — the check is only as good as the patterns you give it.

## Why `CLAUDE_CONFIG_DIR`, and not a fake `$USERPROFILE`

The widely circulated approach to this problem reassigns `$USERPROFILE` per instance. It works, but
it relocates *everything* keyed off the home directory — `.gitconfig`, `.ssh`, `.m2`, `.gradle`,
`.jdks`, `~\.local\bin` — which then has to be clawed back one tool at a time with symlinks, which
need an elevated prompt, and which the CLI's own updater keeps breaking.

`CLAUDE_CONFIG_DIR` is the narrow, supported knob. Verified against the shipped binary:

- `.claude.json` resolves to `path.join(process.env.CLAUDE_CONFIG_DIR || homedir(), ".claude.json")`
- `.credentials.json` resolves to `path.join(configDir, ".credentials.json")`
- the Windows Credential Manager service name gets a `-<sha256(configDir)[0:8]>` suffix when the
  variable is set, so credentials isolate under either storage backend
- IDE lock-file discovery searches `<configDir>\ide` **and**, when the variable is set, additionally
  `%USERPROFILE%\.claude\ide` — which is why IDE integration survives on the work account

One variable does the whole job, nothing else in the home directory moves, and no step needs
elevation.

## Why the personal account leaves the variable unset

This is the one piece of the design that looks like an oversight and is not.

Because the credential-service name is suffixed with a hash *of the config directory path* whenever
`CLAUDE_CONFIG_DIR` is set, pinning it to the default `~\.claude` would address a **different**
credential entry than the one you are already logged in under. The account would appear logged out
the first time that storage backend is used. So `claude-personal` and the auto-routing path both
*remove* the variable rather than setting it.

The cost is that an unset variable is ambiguous: it means "personal", but it also means "the
switcher never ran". A shell started before the profile was installed, or an IDE terminal
configured with `-NoProfile`, lands on the personal account and looks identical to a correct
personal session. If that ambiguity ever matters, the fix is a *separate* marker variable set by
`Invoke-ClaudeAs` — never `CLAUDE_CONFIG_DIR` itself.

## Status line

    [Work] acme-api · Opus 5 1M (high) · Context: 16% [156.4k]
      Session $1.84 · Spend $37.20/$500

    [Personal] my-side-project · Opus 5 1M (high) · Context: 16% [156.4k]
      Session $1.84 · 5h 68% left (2h13m) · 7d 43% left (2d8h)

### Why two lines

The renderer splits the command's output on `\n`, lays the pieces out as a flex column, and carries
the active ANSI state forward onto each subsequent line so styling survives the break. Multi-line
is a supported shape, not a tolerated one.

The reason to use it is the single-line branch: one line renders as `<Text dimColor wrap="truncate">`
— **truncated, not wrapped**. An over-wide single line silently loses its tail, and the tail is
where usage sits. Two lines keep both halves visible in a narrow terminal. The longest line here is
63 columns, against about 90 and 134 for the single-line equivalents.

### Colour

ANSI passes through untouched — there is no stripping anywhere in the CLI — and costs nothing in
width, since the renderer measures with `Bun.stringWidth`. Two rules the script follows:

- **End colour runs with SGR 39, never SGR 0.** The host wraps every status line in `dimColor`; a
  full reset would cancel that dim for the remainder of the line.
- **The account tag uses the standard `3x` set, not the bright `9x` one.** The host's dim does not
  knock `9x` back far enough, and a bright tag shouts at you on every render for information you
  only glance at. Alerts are the exception: threshold colours stay bright, because being noticed is
  their whole job.

`[Personal]` is cyan, `[Work]` yellow, any other config dir magenta under its own directory name —
all configurable via `$TagColors` / `$TagReset` at the top of the script. Separators are dim. The
two numbers worth reacting to change colour as they approach a limit: context (yellow at 70%, red
at 85%) and spend or window usage (yellow at 50/70%, red at 80/90%).

If the tag is still too present, the next step down is faint plus colour — `$TagColors.personal =
'2;36'` with `$TagReset = '22;39'`, since faint unwinds with 22, separately from the foreground.

Width is measured with `ambiguousIsNarrow: true`, so East-Asian-ambiguous glyphs — `·` included —
count as one column here but may draw two wide in some terminals and fonts. Anything beyond the
middot separator is worth checking before adopting.

### Where the numbers come from

`cost.total_cost_usd` and `rate_limits.{five_hour,seven_day}` arrive in the payload on stdin.
`rate_limits` is absent under API-key auth and until the first API response of a session, and
`cost` is not listed in the schema the built-in status-line setup agent documents even though it is
passed — the script treats every field as optional and omits what is missing rather than rendering
a blank. The session dollar figure is the notional API-equivalent cost of the session, not a charge
against the seat.

The **spend limit** is the one figure that does not arrive on stdin. It lives in the CLI's own usage
cache, `cachedUsageUtilization.utilization.spend`, inside the profile's `.claude.json` — so
`Get-SpendSegment` locates that file exactly the way the CLI does and reads it. Three details shape
that code:

- The file is **not** parsed with `ConvertFrom-Json`: it holds project keys differing only in case,
  which the parser rejects outright, and `-AsHashtable` does not exist in Windows PowerShell 5.1,
  which is what `settings.json` invokes the status line with. It is brace-scanned instead.
- The cache is refreshed off API responses, throttled to once per five minutes, and the CLI stops
  trusting it after an hour — so the figure lags slightly, and anything older than an hour is
  labelled `stale` rather than shown as current.
- It costs about 4 ms per render against a 69 KB file, next to roughly 160 ms for the
  `powershell.exe` spawn the status line already pays.

Which windows appear depends on how the seat is billed. An Enterprise usage-based seat has
`five_hour` / `seven_day` set to `null` and a real `spend` block; a personal Max/Pro subscription
has the reverse (`spend.enabled: false`). The script renders whichever exists and omits the rest, so
one shared file covers both accounts.

The monthly reset date the web UI shows is not in the cache, so it is not displayed.

## The CLAUDE.md asymmetry

Conditional rules — "for work repos do X, for personal repos do Y" — stay **whole in the personal
profile** and are **collapsed to the work branch only** in the work profile.

That is not an oversight either. The work profile only ever sees work repositories, so the personal
branch there is dead weight that can only misfire. The personal profile can still be pointed at a
work directory, deliberately or by accident, so it needs the full conditional intact to behave
correctly when that happens. Trimming both would leave the personal account with no guidance for
the one case it can actually encounter.

Concretely: the personal `CLAUDE.md` is not edited by this setup at all.

## License

MIT — see [LICENSE](LICENSE).
