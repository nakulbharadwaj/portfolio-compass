<#
  run-tests.ps1 - test suite for the Portfolio +/-1% Alert system.

  Two modes:
    (default)  11 fast checks. Reads files, validates config and the scheduled
               task, and confirms Brevo accepts the API key. Sends NO email.
    -Live      adds T12 (a real email) and T13 (a full end-to-end alert run,
               about 90 seconds) so the delivery path is exercised for real.

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
    foreach ($t in @("get_equity_positions", "get_equity_quotes", "get_equity_news", "get_earnings_calendar")) {
        Assert ($r -match $t) "read tool $t is not allowlisted"
    }
    "4 read tools only, no order or bypass flags"
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
    Assert ($new -match "ALERT SENT|SENT ok|http=201") ("run did not report a successful send. Log tail: " + $new)
    "alert composed and delivered"
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
