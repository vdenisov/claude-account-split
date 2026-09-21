# Template for profiles.config.ps1 — the only file you edit to adapt the split to your machine.
#
# Copy this to profiles.config.ps1 and fill it in, or let install.ps1 generate it for you.
# Both claude-switch.ps1 and statusline-command.ps1 dot-source the real file when present, and
# each carries the same values as its own defaults, so they still work if it is missing.

# Directory tree owned by the work account. The `claude` wrapper routes anything at or under this
# path to the work profile, and everything else to the personal one.
$ClaudeWorkRoot = 'C:\Dev\Work'

# Config directory for the work account.
#
# The personal account deliberately has no entry here: it keeps the default (~\.claude) with
# CLAUDE_CONFIG_DIR left unset, because setting the variable changes the Windows Credential Manager
# service name. See README.md.
$ClaudeWorkDir = Join-Path $HOME '.claude-work'

# Labels shown in the status-line tag.
$ClaudeAccountLabels = @{ personal = 'Personal'; work = 'Work' }

# User-scope MCP servers that migrate-workspaces.ps1 copies from the personal profile into the work
# one, by name, with their headers intact. Leave empty to copy none.
#
# Think about what each server authenticates as before listing it: a server holding a personal
# access token should usually stay on the personal account.
$ClaudeMcpServersToCopy = @()
