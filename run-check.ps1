<#
  run-check.ps1 — invoked by Task Scheduler every 15 minutes during market hours.

  Runs Claude headlessly against check-prompt.md. Claude reads the portfolio,
  computes the day's move, and emails an alert only if it crosses +/-1%.

  The claude binary lives inside the VS Code extension folder and is NOT on PATH,
  and its version folder changes on every extension update — so the newest one is
  resolved at runtime rather than hardcoded.

  Test manually with:  powershell -ExecutionPolicy Bypass -File run-check.ps1 -WhatIfThreshold 0
#>
param(
    # For testing: pass 0 to force an alert regardless of the real move.
    [int]$ForceBandOverride = -1
)

$ErrorActionPreference = "Stop"
$root   = $PSScriptRoot
$logDir = Join-Path $root "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ("check-" + (Get-Date -Format "yyyy-MM-dd") + ".log")

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Add-Content -Path $log -Value $line -Encoding utf8
}

# Resolve the newest installed claude.exe.
$candidates = Get-ChildItem "$env:USERPROFILE\.vscode\extensions\anthropic.claude-code-*-win32-x64\resources\native-binary\claude.exe" -ErrorAction SilentlyContinue
if (-not $candidates) { Write-Log "FATAL: no claude.exe found"; exit 1 }
$exe = ($candidates | Sort-Object { [version](($_.FullName -split 'claude-code-')[1] -split '-win32')[0] } | Select-Object -Last 1).FullName

$promptFile = Join-Path $root "check-prompt.md"
if (-not (Test-Path $promptFile)) { Write-Log "FATAL: check-prompt.md missing"; exit 1 }
$prompt = [System.IO.File]::ReadAllText($promptFile)
if ($ForceBandOverride -ge 0) {
    $prompt += "`n`n## TEST OVERRIDE`nThis is a manual test of the email path.`n- Ignore the threshold in Step 2 and ignore the state file entirely.`n- Ignore the 'SKIP stale data' rule: if the market is closed, use the most recent session's data and say so in the email.`n- Produce the alert email exactly as you normally would, so the full path is exercised.`n- Put 'TEST' at the start of the subject line.`n- Do not update the state file."
}

# Only the read tools this job needs. Trading tools are deliberately absent, so an
# order-placement call would be denied rather than silently permitted.
$tools = @(
    "mcp__robinhood-trading__get_equity_positions"
    "mcp__robinhood-trading__get_equity_quotes"
    "mcp__robinhood-trading__get_equity_news"
    "mcp__robinhood-trading__get_earnings_calendar"
    "Read"
    "Write"
    "Bash"
) -join ","

$exeVersion = Split-Path (Split-Path (Split-Path (Split-Path $exe -Parent) -Parent) -Parent) -Leaf
Write-Log "start (claude: $exeVersion)"
try {
    $out = $prompt | & $exe -p --allowedTools $tools --output-format text 2>&1
    $text = ($out | Out-String).Trim()
    if ($text) { foreach ($l in ($text -split "`r?`n")) { Write-Log "  $l" } }
    Write-Log "end exit=$LASTEXITCODE"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
