<#
  run-check.ps1 - invoked by Task Scheduler every 15 minutes during market hours.

  Runs Claude headlessly against check-prompt.md. Claude reads the portfolio,
  computes the day's move, and emails an alert only if it crosses +/-1%.

  The claude binary lives inside the VS Code extension folder and is NOT on PATH,
  and its version folder changes on every extension update - so the newest one is
  resolved at runtime rather than hardcoded.

  This script ALSO watches its own health (see "Health check" below) and emails a
  separate alert if the checker itself stops working - added 2026-10-11, after an
  Avast TLS-interception bug silently broke the Robinhood connection for about two
  weeks (2026-09-28 to 2026-10-11) with no emails and no way to know it had happened
  short of noticing the silence and digging through logs.

  Test manually with:
    powershell -ExecutionPolicy Bypass -File run-check.ps1 -ForceBandOverride 0   # force a real alert
    powershell -ExecutionPolicy Bypass -File run-check.ps1 -HealthTest            # force a down-alert
#>
param(
    # For testing: pass 0 to force a portfolio alert regardless of the real move.
    [int]$ForceBandOverride = -1,

    # For testing: simulates a failed run (no claude invocation at all) so the
    # down-alert path can be exercised without a real outage.
    [switch]$HealthTest
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

# ---------------------------------------------------------------------------
# Run the actual check (or simulate a failure, for -HealthTest). Either way,
# $text and $exitCode end up holding the outcome for the health check below.
# ---------------------------------------------------------------------------
if ($HealthTest) {
    Write-Log "start (HEALTH TEST - simulated failure, claude not invoked)"
    $text = "SIMULATED FAILURE: this is a manual test of the down-alert path via -HealthTest. No real check ran, nothing about your actual portfolio or connection is wrong."
    $exitCode = 1
    Write-Log "  $text"
    Write-Log "end exit=$exitCode"
}
else {
    $text = $null
    $exitCode = 1

    $candidates = Get-ChildItem "$env:USERPROFILE\.vscode\extensions\anthropic.claude-code-*-win32-x64\resources\native-binary\claude.exe" -ErrorAction SilentlyContinue
    if (-not $candidates) {
        $text = "FATAL: no claude.exe found under the VS Code extensions folder"
        Write-Log $text
    }
    else {
        $exe = ($candidates | Sort-Object { [version](($_.FullName -split 'claude-code-')[1] -split '-win32')[0] } | Select-Object -Last 1).FullName
        $promptFile = Join-Path $root "check-prompt.md"

        if (-not (Test-Path $promptFile)) {
            $text = "FATAL: check-prompt.md missing"
            Write-Log $text
        }
        else {
            $prompt = [System.IO.File]::ReadAllText($promptFile)
            if ($ForceBandOverride -ge 0) {
                $prompt += "`n`n## TEST OVERRIDE`nThis is a manual test of the email path.`n- Ignore the threshold in Step 2 and ignore the state file entirely.`n- Ignore the 'SKIP stale data' rule: if the market is closed, use the most recent session's data and say so in the email.`n- Produce the alert email exactly as you normally would, so the full path is exercised.`n- Put 'TEST' at the start of the EMAIL SUBJECT LINE only.`n- Still print your final confirmation using the exact format from Step 5 (e.g. `ALERT SENT pct=X.XX band=N`) so this test run is verifiable the same way a real alert is - do not rename or reword that line.`n- Do not update the state file."
            }

            # Only the read tools this job needs. Trading tools are deliberately absent,
            # so an order-placement call would be denied rather than silently permitted.
            $tools = @(
                "mcp__robinhood-trading__get_equity_positions"
                "mcp__robinhood-trading__get_equity_quotes"
                "mcp__robinhood-trading__get_equity_news"
                "mcp__robinhood-trading__get_earnings_calendar"
                "Read"
                "Write"
                "Edit"
                "Bash"
            ) -join ","

            $exeVersion = Split-Path (Split-Path (Split-Path (Split-Path $exe -Parent) -Parent) -Parent) -Leaf
            Write-Log "start (claude: $exeVersion)"
            try {
                $out = $prompt | & $exe -p --allowedTools $tools --output-format text 2>&1
                $text = ($out | Out-String).Trim()
                $exitCode = $LASTEXITCODE
                if ($text) { foreach ($l in ($text -split "`r?`n")) { Write-Log "  $l" } }
                Write-Log "end exit=$exitCode"
            }
            catch {
                $text = "ERROR: $($_.Exception.Message)"
                $exitCode = 1
                Write-Log $text
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Health check: alert if THE CHECKER ITSELF is failing, independent of any
# portfolio move.
#
# This is deliberately plain PowerShell, not something the agent decides to
# do. If the agent or the MCP connection is what's broken - exactly what
# happened 2026-09-28 to 2026-10-11 - it may never get far enough to report
# its own failure. This block runs no matter what happened above, so it
# cannot be silenced by the same failure it exists to catch.
#
# A run counts as healthy only if it exited 0 AND its final output matches
# one of the known-good outcomes (an allowlist). Anything else - including a
# new failure message never seen before - is treated as unhealthy by
# default. That matters: during the Avast incident alone we saw at least
# four different phrasings for "the connector is down" ("Failed to
# authenticate: OAuth session expired...", "SKIP data unavailable: the
# robinhood-trading MCP server failed to connect...", "SKIP: no data...",
# plain InvalidHTTPResponse text). A denylist of exact phrases would have
# missed most of those. "SKIP stale data" (a closed market) is the one
# failure-shaped message that is actually healthy, so it's explicitly
# allowed alongside the two real success outcomes.
# ---------------------------------------------------------------------------
$FAIL_THRESHOLD = 3   # consecutive failed polls (45 min at 15-min cadence) before the first alert
$REMINDER_HOURS = 4   # how long to wait before re-alerting on a still-ongoing outage

$GOOD_PATTERN = 'NO ALERT pct=|ALERT SENT pct=|TEST SENT pct=|SKIP stale data'
$isHealthy = ($exitCode -eq 0) -and ($text -match $GOOD_PATTERN)

$healthFile = Join-Path $root "health.json"
$health = [pscustomobject]@{ consecutive_fails = 0; alert_sent_at = $null }
if (Test-Path $healthFile) {
    try {
        $loaded = Get-Content $healthFile -Raw | ConvertFrom-Json
        $health.consecutive_fails = [int]$loaded.consecutive_fails
        $health.alert_sent_at     = $loaded.alert_sent_at
    }
    catch { Write-Log "health.json unreadable, resetting" }
}
# A single -HealthTest run should be enough to demonstrate the alert, not require
# three real invocations - so it starts one short of the threshold.
if ($HealthTest) { $health.consecutive_fails = $FAIL_THRESHOLD - 1 }

function Send-HealthEmail {
    param([string]$Subject, [string]$BodyHtml)
    $tmp = Join-Path $env:TEMP ("portfolio-health-" + [Guid]::NewGuid().ToString("N") + ".html")
    try {
        [System.IO.File]::WriteAllText($tmp, $BodyHtml)
        $sendOut = (& (Join-Path $root "send-email.ps1") -Subject $Subject -HtmlPath $tmp 2>&1 | Out-String)
        foreach ($l in ($sendOut.Trim() -split "`r?`n")) { Write-Log "  health-email: $l" }
        return ($sendOut -match "SENT ok")
    }
    catch {
        Write-Log "health-email ERROR: $($_.Exception.Message)"
        return $false
    }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

if ($isHealthy) {
    if ($health.consecutive_fails -ge $FAIL_THRESHOLD) {
        Write-Log "health: RECOVERED after $($health.consecutive_fails) consecutive failures"
        $html = "<div style='font-family:sans-serif;padding:20px;max-width:480px'>" +
                "<div style='background:#0f6b5c;color:#fff;padding:14px 18px;border-radius:6px 6px 0 0'><strong>Portfolio Compass is back up</strong></div>" +
                "<div style='border:1px solid #e6ebe9;border-top:none;padding:16px 18px;border-radius:0 0 6px 6px'>" +
                "<p style='margin:0 0 10px'>The checker failed for $($health.consecutive_fails) consecutive polls and has now recovered. Alerts are resuming normally.</p>" +
                "<p style='margin:0;color:#7a8683;font-size:13px'>Automated health notice from the Portfolio Compass checker.</p></div></div>"
        Send-HealthEmail -Subject "Portfolio Compass - checker is back up" -BodyHtml $html | Out-Null
    }
    $health.consecutive_fails = 0
    $health.alert_sent_at = $null
}
else {
    $health.consecutive_fails += 1
    Write-Log "health: unhealthy run (consecutive=$($health.consecutive_fails), exit=$exitCode)"

    $shouldAlert = $false
    if ($health.consecutive_fails -eq $FAIL_THRESHOLD) {
        $shouldAlert = $true
    }
    elseif ($health.consecutive_fails -gt $FAIL_THRESHOLD -and $health.alert_sent_at) {
        $hoursSince = ((Get-Date) - [datetime]$health.alert_sent_at).TotalHours
        if ($hoursSince -ge $REMINDER_HOURS) { $shouldAlert = $true }
    }

    if ($shouldAlert) {
        $snippet = (($text -split "`r?`n") | Select-Object -Last 4) -join "<br>"
        $hoursDown = [math]::Round($health.consecutive_fails * 15 / 60.0, 1)
        $html = "<div style='font-family:sans-serif;padding:20px;max-width:480px'>" +
                "<div style='background:#b83a2e;color:#fff;padding:14px 18px;border-radius:6px 6px 0 0'><strong>Portfolio Compass checker is DOWN</strong></div>" +
                "<div style='border:1px solid #e6ebe9;border-top:none;padding:16px 18px;border-radius:0 0 6px 6px'>" +
                "<p style='margin:0 0 10px'>$($health.consecutive_fails) consecutive polls have failed (about $hoursDown hours). It is NOT currently reporting on your portfolio.</p>" +
                "<p style='margin:0 0 10px;font-family:monospace;font-size:12px;background:#f5f7f6;padding:8px;border-radius:4px'>$snippet</p>" +
                "<p style='margin:0;color:#7a8683;font-size:13px'>Check %LOCALAPPDATA%\portfolio-digest\logs for detail. You will not get another reminder for $REMINDER_HOURS hours unless it recovers first.</p></div></div>"
        $sent = Send-HealthEmail -Subject "Portfolio Compass checker is DOWN ($($health.consecutive_fails) failed polls)" -BodyHtml $html
        if ($sent) { $health.alert_sent_at = (Get-Date).ToString("o") }
    }
}

($health | ConvertTo-Json -Compress) | Set-Content -Path $healthFile -Encoding utf8 -NoNewline

if ($HealthTest) { Write-Log "HEALTH TEST complete" }
exit $exitCode
