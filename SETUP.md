# Setting up the split

Two separately authenticated Claude Code accounts on one Windows machine, both logged in at the
same time, selected automatically by working directory.

Nothing below needs an elevated prompt.

## Requirements

- Claude Code (any recent version; verified against 2.1.234, native install at `~\.local\bin\claude.exe`)
- PowerShell 7 (`winget install Microsoft.PowerShell`) **for `migrate-workspaces.ps1` only** — it
  needs `ConvertFrom-Json -AsHashtable`, which Windows PowerShell 5.1 does not have. The installer,
  the switcher and the status line all run under 5.1 too, which matters because an IDE's built-in
  terminal may launch either edition.
- Two accounts you can log into.

The scripts run from wherever you put this directory; they locate each other and
`profiles.config.ps1` relative to themselves. Keep them together and leave them somewhere stable —
the PowerShell profile will hold an absolute path to `claude-switch.ps1`.

## Fast path

```powershell
# From wherever you unpacked this directory:
.\install.ps1 -WorkRoot 'C:\Dev\YourWorkTree' -Seed
```

Then, in order:

1. Open a **new** terminal so the PowerShell profile loads.
2. `claude-work` → complete onboarding → `/login` with the second account. Exit cleanly.
3. Put a work-appropriate `CLAUDE.md` in the work config dir — see *Two CLAUDE.md files* below.
4. Optionally, close every Claude Code session and run `pwsh -File .\migrate-workspaces.ps1` to
   bring existing project state across.

That is the whole setup. The rest of this file explains what the installer did and how to do it by
hand.

## What gets created

| Path | |
| --- | --- |
| `~\.claude\` + `~\.claude.json` | personal profile — unchanged apart from `statusLine` in `settings.json` |
| `~\.claude-work\` + `~\.claude-work\.claude.json` | work profile |
| `~\.claude-work\settings.json` | seeded from the personal one, or created with just the status line |
| `<this directory>\profiles.config.ps1` | the only file you edit to adapt the split |
| `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` | one dot-source line |
| `Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | the same line, for the 5.1 host |

`~\.local\bin\claude.exe` is shared by both accounts and is not touched.

## Manual setup

If you would rather not run the installer, or want to understand it:

1. **Pick the work root and config dir.** Edit `profiles.config.ps1`:

   ```powershell
   $ClaudeWorkRoot = 'C:\Dev\YourWorkTree'
   $ClaudeWorkDir  = Join-Path $HOME '.claude-work'
   ```

2. **Load the switcher from both PowerShell profiles.** Append to each of
   `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` and
   `Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`:

   ```powershell
   . "C:\path\to\claude-account-split\claude-switch.ps1"
   ```

   Both editions, because an IDE terminal may launch either. If your `Documents` folder is
   redirected to OneDrive, that is where these live.

   If a line naming `claude-switch.ps1` is already there from an earlier layout, **delete it**
   rather than adding a second one. A dot-source pointing at a path that no longer exists throws on
   every shell start, and `install.ps1` reports it instead of installing over it.

3. **Point both `settings.json` files at the shared status line** — `~\.claude\settings.json` and
   `~\.claude-work\settings.json`. Optional, but it is what tells you which account you are on, so
   skipping it on the work profile defeats the point:

   ```json
   "statusLine": {
     "type": "command",
     "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\claude-account-split\\statusline-command.ps1\""
   }
   ```

4. **Log the work account in**: open a new terminal, run `claude-work`, complete onboarding,
   `/login`, then exit cleanly so `.claude.json` is written.

5. **Migrate existing project state** (optional). With every Claude Code session closed:

   ```powershell
   pwsh -File .\migrate-workspaces.ps1
   ```

   It copies — never moves — the session transcripts, per-project memories, directory-trust and
   `allowedTools` state for projects under the work root, plus any MCP servers named in
   `$ClaudeMcpServersToCopy`. The personal profile keeps everything and can still `/resume` the
   same sessions.

## How selection works

| Where you are | What `claude` uses |
| --- | --- |
| at or under `$ClaudeWorkRoot` | work |
| anywhere else | personal |
| `CLAUDE_CONFIG_DIR` already set | whatever it points at, unchanged |

`claude-work` and `claude-personal` force it regardless of directory.

The third row matters for nested invocations: a `claude -p` spawned from inside a session inherits
the parent's account instead of re-deciding from the directory it happens to be in.

## Two CLAUDE.md files

Each profile has its own `CLAUDE.md`, and this is the main reason to think rather than copy.

Rules that are *conditional* on which account you are using — "for work repos do X, for personal
repos do Y" — should stay **whole and unedited in the personal profile**, and be **collapsed to the
work branch only** in the work profile. Typical examples: which GitHub credential to use, which git
identity to commit under, which internal tooling exists.

The asymmetry is deliberate. The work profile only ever sees work repositories, so carrying the
personal branch there is dead weight that can only misfire. The personal profile, on the other
hand, may still be pointed at a work directory by mistake or on purpose, so it needs the full
conditional intact to do the right thing. Trimming both would leave the personal account with no
guidance for the case it can actually encounter.

## Verifying

1. **Routing, without launching anything:**

   ```powershell
   Get-ClaudeAccountForPath 'C:\Dev\YourWorkTree\some-repo'   # -> work
   Get-ClaudeAccountForPath 'C:\Dev\personal-thing'           # -> personal
   Get-ClaudeAccountForPath 'C:\Dev\YourWorkTreeOther'        # -> personal, not a prefix match
   ```

2. **Isolation:** two terminals side by side, `claude` in a work repo and `claude` in a personal
   one. `/status` shows a different account in each, and neither logs the other out. Each profile
   runs its own daemon, with its own `daemon.lock` inside its config dir.

3. **Work bootstrap:** inside `claude-work`, check `/status`, `/memory`, `/mcp`, `/plugin`.

4. **Migration:** `/resume` inside a migrated project lists its old sessions, and starting one does
   not re-prompt for directory trust.

5. **IDE:** open a work project, open the built-in terminal, run `claude`. The status line should
   show `[Work]`, and IDE-backed tools should still resolve — Claude Code looks for the IDE lock
   file in `<config dir>\ide` *and*, whenever `CLAUDE_CONFIG_DIR` is set, additionally in
   `~\.claude\ide`, which is where the IDE plugin writes it.

## Troubleshooting

**The `claude` function is not defined in a new terminal.** The profile did not load. Check
`Test-Path $PROFILE`, and check your IDE's terminal settings for a `-NoProfile` argument, which
bypasses it.

**The work account looks logged out after setting `CLAUDE_CONFIG_DIR` by hand.** Do not set it to
the personal default path. See the credential-service note in `README.md`.

**`migrate-workspaces.ps1` refuses to run.** It will not touch `.claude.json` while any
`claude.exe` is alive, because the CLI rewrites that file on exit and would discard the merge.
Close every session, including ones in IDE terminals.

**`ConvertFrom-Json` fails on `.claude.json`.** Expected: it contains keys differing only in case.
Use `-AsHashtable`, which needs PowerShell 7.

## Uninstalling

1. Remove the dot-source line from both PowerShell profiles.
2. Delete the work config dir.
3. Revert `statusLine.command` in the personal `settings.json` (the installer leaves a `.bak`
   beside any settings file it rewrote).
4. Delete this directory.

The personal profile has no other modifications.
