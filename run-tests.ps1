<#
  run-tests.ps1 - test suite for the Portfolio +/-1% Alert system.

  Two modes:
    (default)  13 fast checks. Reads files, validates config and the scheduled
               task, and confirms Brevo accepts the API key. Sends NO email.
    -Live      adds T12 (a real email), T13 (a full end-to-end alert run), and
               T16 (a full end-to-end health DOWN-alert run) - about 2.5 min,
               three real emails sent.

  Usage:
    powershell -ExecutionPolicy Bypass -File run-tests.ps1
    powershell -ExecutionPolicy Bypass -File run-tests.ps1 -Live

  Exit code is 0 when every test passes and 1 otherwise, so this can gate a change.

  NOTE: this file is deliberately pure ASCII. Windows PowerShell 5.1 reads .ps1
  files as ANSI unless they carry a BOM, so a stray non-ASCII character inside a
  quoted string corrupts parsing.
#>
param(
    [switch]$Live
)

$root = $PSScriptRoot
$script:results = @()

function Test-Case {
    param(
        [string]$Id,
        [string]$Name,
        [scriptblock]$Body,
        [switch]$Skip,
        [string]$SkipReason
    )

    if ($Skip) {
        $script:results += [pscustomobject]@{ Id = $Id; Name = $Name; Status = "SKIP"; Detail = $SkipReason }
        Write-Host ("  {0}  {1,-44} SKIP  {2}" -f $Id, $Name, $SkipReason) -ForegroundColor DarkGray
        return
    }
    try {
        $detail = & $Body               # a test returns a detail string, or throws to fail
        $script:results += [pscustomobject]@{ Id = $Id; Name = $Name; Status = "PASS"; Detail = $detail }
        Write-Host ("  {0}  {1,-44} PASS  {2}" -f $Id, $Name, $detail) -ForegroundColor Green
    }
    catch {
        $msg = $_.Exception.Message
        $script:results += [pscustomobject]@{ Id = $Id; Name = $Name; Status = "FAIL"; Detail = $msg }
        Write-Host ("  {0}  {1,-44} FAIL  {2}" -f $Id, $Name, $msg) -ForegroundColor Red
    }
}

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Write-Host ""
Write-Host "Portfolio 1% Alert - test suite" -ForegroundColor Cyan
if ($Live) { Write-Host "mode: LIVE (will send email)" } else { Write-Host "mode: safe (no email sent)" }
Write-Host ""

# ---------------------------------------------------------------- structure --

Test-Case -Id "T01" -Name "all expected files present" -Body {
    $need = @("check-prompt.md", "run-check.ps1", "send-email.ps1", "brevo.key", "README.md")
    $missing = @($need | Where-Object { -not (Test-Path (Join-Path $root $_)) })
    Assert ($missing.Count -eq 0) ("missing: " + ($missing -join ", "))
    "$($need.Count) files"
}

Test-Case -Id "T02" -Name "API key is well-formed" -Body {
    $p = Join-Path $root "brevo.key"
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    Assert (-not $hasBom) "file has a UTF-8 BOM, which corrupts the key"
    $k = [System.IO.File]::ReadAllText($p)
    Assert ($k -eq $k.Trim()) "key has leading or trailing whitespace"
    Assert ($k.StartsWith("xkeysib-")) "key does not start with xkeysib-"
    Assert ($k.Length -ge 60) ("key is implausibly short: " + $k.Length + " chars")
    "" + $k.Length + " chars, no BOM"
}

Test-Case -Id "T03" -Name "secrets are not inside OneDrive" -Body {
    Assert ($root -notmatch "OneDrive") "folder is inside OneDrive and would sync the API key to the cloud"
    "stored at $root"
}

Test-Case -Id "T04" -Name "claude.exe resolves to newest version" -Body {
    $c = @(Get-ChildItem "$env:USERPROFILE\.vscode\extensions\anthropic.claude-code-*-win32-x64\resources\native-binary\claude.exe" -ErrorAction SilentlyContinue)
    Assert ($c.Count -gt 0) "no claude.exe found under the VS Code extensions folder"
    $newest = $c | Sort-Object { [version](($_.FullName -split 'claude-code-')[1] -split '-win32')[0] } | Select-Object -Last 1
    Assert (Test-Path $newest.FullName) "resolved path does not exist"
    $ver = (($newest.FullName -split 'claude-code-')[1] -split '-win32')[0]
    "v$ver of $($c.Count) installed"
}

# ------------------------------------------------------------ prompt config --

Test-Case -Id "T05" -Name "prompt has required sections and account" -Body {
    $p = Get-Content (Join-Path $root "check-prompt.md") -Raw
    foreach ($s in @("## Step 1", "## Step 2", "## Step 3", "## Step 4", "## Step 5")) {
        Assert ($p -match [regex]::Escape($s)) "missing section $s"
    }
    Assert ($p -match "659319982") "the monitored account number is absent"
    Assert ($p -match [regex]::Escape("abs(band) >= 1")) "the 1% threshold rule is absent"
    Assert ($p -match "Never place trades") "the no-trading instruction is absent"
    "5 steps, account + threshold + trading ban present"
}

Test-Case -Id "T06" -Name "no trading tools are allowlisted" -Body {
    $r = Get-Content (Join-Path $root "run-check.ps1") -Raw
    $forbidden = @("place_equity_order", "place_option_order", "cancel_equity_order",
                   "cancel_option_order", "exercise_option", "place_crypto_order",
                   "dangerously-skip-permissions", "bypassPermissions")
    $found = @($forbidden | Where-Object { $r -match [regex]::Escape($_) })
    Assert ($found.Count -eq 0) ("DANGER - found: " + ($found -join ", "))
    # get_equity_news is deliberately absent from the ALLOWLIST ITSELF - Robinhood
    # removed it from the MCP server upstream (confirmed gone 2026-10-24); these
    # are its replacements. This checks for an actual "mcp__...__get_equity_news"
    # allowlist entry, not just the substring anywhere in the file - the script's
    # own explanatory comment about the removal necessarily contains that name too.
    Assert ($r -notmatch [regex]::Escape('"mcp__robinhood-trading__get_equity_news"')) "get_equity_news is allowlisted but no longer exists on the server - remove it"
    foreach ($t in @("get_equity_positions", "get_equity_quotes", "get_earnings_calendar", "get_equity_fundamentals", "get_equity_analyst_ratings", "get_earnings_results", "get_sec_filing_index")) {
        Assert ($r -match $t) "read tool $t is not allowlisted"
    }
    # Regression guard: a run on 2026-09-10 tried to use Edit to update the alert
    # HTML file, hit a permission wall because only Write was allowlisted, and
    # missed sending on time. Edit must stay present alongside Read/Write.
    foreach ($t in @("Read", "Write", "Edit")) {
        Assert ($r -match [regex]::Escape('"' + $t + '"')) "file tool $t is not allowlisted"
    }
    "7 read tools + Read/Write/Edit, no order or bypass flags, no dead get_equity_news"
}

# ------------------------------------------------------------------- runtime --

Test-Case -Id "T07" -Name "scheduled task registered and correct" -Body {
    $t = Get-ScheduledTask -TaskName "Portfolio 1pct Alert" -ErrorAction Stop
    Assert ($t.State -ne "Disabled") "task exists but is Disabled"
    $trig = $t.Triggers[0]
    Assert ($trig.Repetition.Interval -eq "PT15M") ("poll interval is " + $trig.Repetition.Interval + ", expected PT15M")
    Assert ($trig.Repetition.Duration -eq "PT6H30M") ("poll window is " + $trig.Repetition.Duration + ", expected PT6H30M")
    Assert ($trig.DaysOfWeek -eq 62) ("days bitmask is " + $trig.DaysOfWeek + ", expected 62 for Mon-Fri")
    $next = (Get-ScheduledTaskInfo -TaskName "Portfolio 1pct Alert").NextRunTime
    "$($t.State), every 15m, next $next"
}

Test-Case -Id "T08" -Name "state file round-trips" -Body {
    $p = Join-Path $root "state.json"
    $backup = $null
    if (Test-Path $p) { $backup = [System.IO.File]::ReadAllText($p) }
    try {
        $probe = '{"date":"1999-01-01","last_band":-3}'
        [System.IO.File]::WriteAllText($p, $probe, (New-Object System.Text.UTF8Encoding($false)))
        $back = Get-Content $p -Raw | ConvertFrom-Json
        Assert ($back.date -eq "1999-01-01") "date did not round-trip"
        Assert ([int]$back.last_band -eq -3) "last_band did not round-trip"
        "write, read and parse ok"
    }
    finally {
        if ($null -ne $backup) { [System.IO.File]::WriteAllText($p, $backup, (New-Object System.Text.UTF8Encoding($false))) }
        elseif (Test-Path $p) { Remove-Item $p -Force }
    }
}

# ------------------------------------------------------- sender validation ---

Test-Case -Id "T09" -Name "sender rejects a call with no body" -Body {
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "send-email.ps1") -Subject "unit test - should not send" 2>&1 | Out-String)
    Assert ($out -match "Provide either") ("expected a missing-body error, got: " + $out.Trim())
    Assert ($out -notmatch "SENT ok") "script sent an email despite having no body"
    "rejected, nothing sent"
}

Test-Case -Id "T10" -Name "sender rejects a missing HTML file" -Body {
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "send-email.ps1") -Subject "unit test - should not send" -HtmlPath "Z:\definitely\not\here.html" 2>&1 | Out-String)
    Assert ($out -match "not found") ("expected a not-found error, got: " + $out.Trim())
    Assert ($out -notmatch "SENT ok") "script sent an email despite a missing file"
    "rejected, nothing sent"
}

Test-Case -Id "T11" -Name "Brevo accepts the key from this IP" -Body {
    $k = [System.IO.File]::ReadAllText((Join-Path $root "brevo.key")).Trim()
    $cfgFile = Join-Path $env:TEMP ("brevo-test-" + [Guid]::NewGuid().ToString("N") + ".txt")
    try {
        [System.IO.File]::WriteAllLines($cfgFile, @("header = `"api-key: $k`"", "url = `"https://api.brevo.com/v3/account`""))
        $res  = (& curl.exe -4 -s -S --config $cfgFile -w "`nHTTP_CODE:%{http_code}" | Out-String)
        $code = 0
        if ($res -match 'HTTP_CODE:(\d+)') { $code = [int]$Matches[1] }
        if ($code -eq 401 -and $res -match 'unrecognised IP address ([0-9a-fA-F:.]+)') {
            throw ("IP " + $Matches[1] + " is not allowlisted. Add it at https://app.brevo.com/security/authorised_ips")
        }
        Assert ($code -eq 200) ("expected HTTP 200, got " + $code)
        "HTTP 200, key valid and IP allowlisted"
    }
    finally { if (Test-Path $cfgFile) { Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue } }
}

# ------------------------------------------------------------- live delivery --

Test-Case -Id "T12" -Name "sends a real email" -Skip:(-not $Live) -SkipReason "pass -Live to run" -Body {
    $tmp = Join-Path $env:TEMP "suite-test-email.html"
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $html = "<div style='font-family:sans-serif;padding:16px'><h3 style='margin:0 0 8px'>Test suite delivery check</h3><p style='margin:0;color:#4d5a57'>Generated by run-tests.ps1 at $stamp. If you are reading this, the Brevo send path works.</p></div>"
    [System.IO.File]::WriteAllText($tmp, $html)
    try {
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "send-email.ps1") -Subject "TEST suite - delivery check" -HtmlPath $tmp 2>&1 | Out-String)
        Assert ($out -match "SENT ok") ("send failed: " + $out.Trim())
        $id = "unknown"
        if ($out -match 'messageId=(\S+)') { $id = $Matches[1] }
        "delivered, messageId=$id"
    }
    finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

Test-Case -Id "T13" -Name "end-to-end alert run" -Skip:(-not $Live) -SkipReason "pass -Live to run" -Body {
    $logFile = Join-Path (Join-Path $root "logs") ("check-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
    $before = 0
    if (Test-Path $logFile) { $before = @(Get-Content $logFile).Count }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "run-check.ps1") -ForceBandOverride 0 | Out-Null
    Assert (Test-Path $logFile) "no log file was written"
    $new = (@(Get-Content $logFile) | Select-Object -Skip $before) -join " "
    Assert ($new -notmatch "FAILED|error validating|permission") ("run reported a failure. Log tail: " + $new)
    Assert ($new -match "SENT|http=2") ("run completed but showed no send confirmation of any kind. Log tail: " + $new)
    "alert composed and delivered"
}

# ------------------------------------------------------- health check -----

Test-Case -Id "T14" -Name "health-check code present and uses an allowlist" -Body {
    $r = Get-Content (Join-Path $root "run-check.ps1") -Raw
    Assert ($r -match [regex]::Escape('$GOOD_PATTERN')) "the health allowlist pattern is missing"
    Assert ($r -match [regex]::Escape('$FAIL_THRESHOLD')) "the failure threshold constant is missing"
    Assert ($r -match [regex]::Escape('$REMINDER_HOURS')) "the reminder-interval constant is missing"
    Assert ($r -match "HealthTest") "the -HealthTest switch is missing"
    Assert ($r -match [regex]::Escape('SKIP stale data')) "a closed market must still count as healthy, not a failure"
    "allowlist, thresholds and -HealthTest switch all present"
}

Test-Case -Id "T15" -Name "health.json round-trips" -Body {
    $p = Join-Path $root "health.json"
    $backup = $null
    if (Test-Path $p) { $backup = [System.IO.File]::ReadAllText($p) }
    try {
        $probe = '{"consecutive_fails":2,"alert_sent_at":"2026-01-01T00:00:00.0000000Z"}'
        [System.IO.File]::WriteAllText($p, $probe, (New-Object System.Text.UTF8Encoding($false)))
        $back = Get-Content $p -Raw | ConvertFrom-Json
        Assert ([int]$back.consecutive_fails -eq 2) "consecutive_fails did not round-trip"
        Assert ($back.alert_sent_at -eq "2026-01-01T00:00:00.0000000Z") "alert_sent_at did not round-trip"
        "write, read and parse ok"
    }
    finally {
        if ($null -ne $backup) { [System.IO.File]::WriteAllText($p, $backup, (New-Object System.Text.UTF8Encoding($false))) }
        elseif (Test-Path $p) { Remove-Item $p -Force }
    }
}

Test-Case -Id "T16" -Name "HealthTest triggers a real DOWN alert" -Skip:(-not $Live) -SkipReason "pass -Live to run" -Body {
    $healthFile = Join-Path $root "health.json"
    $backup = $null
    if (Test-Path $healthFile) { $backup = [System.IO.File]::ReadAllText($healthFile) }
    $logFile = Join-Path (Join-Path $root "logs") ("check-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
    $before = 0
    if (Test-Path $logFile) { $before = @(Get-Content $logFile).Count }
    try {
        # Start from a clean slate so this run is guaranteed to cross the threshold
        # and actually send, rather than depending on whatever state happens to be
        # sitting there from real production polling.
        [System.IO.File]::WriteAllText($healthFile, '{"consecutive_fails":0,"alert_sent_at":null}', (New-Object System.Text.UTF8Encoding($false)))
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "run-check.ps1") -HealthTest | Out-Null
        $new = (@(Get-Content $logFile) | Select-Object -Skip $before) -join " "
        Assert ($new -match "health-email.*SENT ok") ("no down-alert email was confirmed sent. Log tail: " + $new)
        $after = Get-Content $healthFile -Raw | ConvertFrom-Json
        Assert ([int]$after.consecutive_fails -ge 3) "health.json was not updated to reflect the failure"
        Assert ($null -ne $after.alert_sent_at) "alert_sent_at was not stamped after a successful send"
        "down-alert sent and health.json updated"
    }
    finally {
        if ($null -ne $backup) { [System.IO.File]::WriteAllText($healthFile, $backup, (New-Object System.Text.UTF8Encoding($false))) }
        elseif (Test-Path $healthFile) { Remove-Item $healthFile -Force }
    }
}

# --------------------------------------------------- explanation quality ----

Test-Case -Id "T17" -Name "move explanation distinguishes ETFs from stocks" -Body {
    $p = Get-Content (Join-Path $root "check-prompt.md") -Raw
    Assert ($p -match "breadth read") "the breadth-read step (broad day vs idiosyncratic day) is missing"
    Assert ($p -match [regex]::Escape("STOCK (an individual company) or ETF/FUND")) "the per-mover type classification step is missing"
    Assert ($p -match "get_equity_fundamentals") "the fallback classifier for unrecognized tickers is missing"
    foreach ($etf in @("QQQ", "GLD", "COPX")) {
        Assert ($p -match [regex]::Escape("| $etf |")) "the classification table is missing $etf"
    }
    Assert ($p -match "Commodity ETFs") "commodity-specific reasoning (rates/dollar for gold, copper prices for COPX) is missing"
    Assert ($p -match [regex]::Escape("Stock-specific moves")) "the email's Why section no longer groups stock moves separately from ETF moves"
    Assert ($p -match [regex]::Escape("ETF / fund moves")) "the email's Why section no longer groups ETF moves separately from stock moves"
    "breadth read, type classification, and grouped Why section all present"
}

# ---------------------------------------------------------------- summary ----

$pass = @($script:results | Where-Object { $_.Status -eq "PASS" }).Count
$fail = @($script:results | Where-Object { $_.Status -eq "FAIL" }).Count
$skip = @($script:results | Where-Object { $_.Status -eq "SKIP" }).Count

Write-Host ""
if ($fail -gt 0) {
    Write-Host ("{0} passed, {1} failed, {2} skipped" -f $pass, $fail, $skip) -ForegroundColor Red
    Write-Host ""
    Write-Host "failures:" -ForegroundColor Red
    $script:results | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host ("  {0} {1}: {2}" -f $_.Id, $_.Name, $_.Detail) -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}
Write-Host ("{0} passed, {1} failed, {2} skipped" -f $pass, $fail, $skip) -ForegroundColor Green
Write-Host ""
exit 0
