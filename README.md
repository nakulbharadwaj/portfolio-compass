# Portfolio Compass

*Know where you stand, and when the ground shifts.*

Portfolio analytics and swing alerting for a Robinhood brokerage account.

Polls the account during US market hours and emails an alert **only** when the
day's move crosses ±1%. Silent on every ordinary day. Alerts are graded by
magnitude band — 1, 2, 3 — so a deepening move escalates instead of spamming.

Built 2026-09-06. Account monitored: **••••9982** (main individual brokerage only —
the IRA, managed and Agentic accounts are deliberately excluded).

> **Private repository.** The prompt contains a real brokerage account number and
> the sender script contains a real email address. Do not make this public without
> moving both into an ignored config file first.

---

## How it works

```
Task Scheduler  ──every 15 min, 09:30–16:00, Mon–Fri──►  run-check.ps1
                                                              │
                                    resolves newest claude.exe │
                                                              ▼
                                            claude -p  +  check-prompt.md
                                                              │
                          reads positions & quotes via Robinhood MCP (OAuth)
                                                              │
                                          computes today's move vs prev close
                                                              │
                                        ┌─────────────────────┴───────────────┐
                                    < ±1%                                  ≥ ±1%
                                        │                                     │
                              write state, log,                     research news,
                                  send nothing                    write HTML, then
                                                                    send-email.ps1
                                                                          │
                                                              Brevo API ──► inbox
```

The **baseline** is each quote's `adjusted_previous_close`, so no overnight
snapshot file is needed — the previous close arrives with the quote.

---

## Files

| File | Role |
|---|---|
| `check-prompt.md` | The instructions Claude follows on each poll. Plain English — edit this to change the threshold, email layout, or what gets researched. |
| `run-check.ps1` | Wrapper invoked by Task Scheduler. Resolves the Claude binary, feeds it the prompt, writes the log. |
| `send-email.ps1` | Sends one email through the Brevo API. Used by the alert path and reusable standalone. |
| `brevo.key` | Brevo API key. Send-only scope. Never printed, never placed on a command line. |
| `state.json` | Written by the alert logic: `{"date":"YYYY-MM-DD","last_band":N}`. Suppresses duplicate alerts within a day. |
| `run-tests.ps1` | Test suite. See below. |
| `logs\check-YYYY-MM-DD.log` | One line per run, one file per day. |

Everything lives in `%LOCALAPPDATA%\portfolio-digest\` — deliberately **outside**
OneDrive, so the API key is not synced to the cloud.

---

## Alert banding (why it won't spam you)

`band` = the integer part of the percentage move, signed. An alert fires only when
`abs(band) >= 1` **and** the band has deepened past the last one sent today, or the
sign flipped.

| Time | Move | Band | Action |
|---|---|---|---|
| 10:00 | −0.7% | 0 | silent |
| 11:15 | −1.3% | −1 | **alert sent** |
| 13:00 | −1.8% | −1 | silent (same band) |
| 14:30 | −2.4% | −2 | **alert sent** (deepened) |
| 15:45 | −1.1% | −1 | silent (already covered) |

State resets automatically each day.

---

## Configuration

**Threshold** — `check-prompt.md`, Step 2. The `1` in "abs(band) >= 1" is the only
place it appears.

**Schedule** — Task Scheduler task **"Portfolio 1pct Alert"**:
```powershell
Get-ScheduledTask   -TaskName "Portfolio 1pct Alert"    # inspect
Disable-ScheduledTask -TaskName "Portfolio 1pct Alert"  # pause
Enable-ScheduledTask  -TaskName "Portfolio 1pct Alert"  # resume
Start-ScheduledTask   -TaskName "Portfolio 1pct Alert"  # run now
```
Currently: every 15 minutes for 6h30m from 09:30, Mon–Fri, hidden window, runs
while logged in.

**Recipient / sender** — the `$To`, `$FromEmail`, `$FromName` defaults at the top of
`send-email.ps1`. The sender address must be verified in Brevo first
(Senders, Domains & Dedicated IPs → Senders → Add a Sender → 6-digit code).

---

## Testing

```powershell
# fast, safe, sends nothing (11 checks)
powershell -ExecutionPolicy Bypass -File run-tests.ps1

# adds a real email send and a full end-to-end alert run (~2 min)
powershell -ExecutionPolicy Bypass -File run-tests.ps1 -Live
```

Manual end-to-end alert, bypassing the threshold and the market-closed guard:
```powershell
powershell -ExecutionPolicy Bypass -File run-check.ps1 -ForceBandOverride 0
```

---

## Safety properties

- **No trading tools are reachable.** `run-check.ps1` allowlists exactly four read
  tools (`get_equity_positions`, `get_equity_quotes`, `get_equity_news`,
  `get_earnings_calendar`) plus `Read`, `Write`, `Bash`. An order call would be
  denied, not silently permitted. Test T06 enforces this.
- **The API key never appears on a command line** (which would expose it in the
  process list). It is passed to curl through a temp config file, deleted in a
  `finally` block.
- **Market-closed guard.** If quotes carry stale timestamps or every position shows
  no change, the run prints `SKIP stale data` and exits without emailing.
- **No mailbox access.** The Brevo key can only send. Nothing in this system can
  read your email.

---

## Troubleshooting

**No emails at all** — check today's log first. If runs are absent entirely, the
task may be disabled or you were logged out; if they say `NO ALERT`, the system is
working and the market simply hasn't moved 1%.

**`FAILED http=401` with "unrecognised IP address"** — your public IP changed. The
error prints the exact address; allowlist it at
https://app.brevo.com/security/authorised_ips. The script forces IPv4 (`curl -4`)
because Windows rotates temporary IPv6 addresses and Brevo allowlists per address.

**Alerts landing in spam** — mark one "not spam" and add the sender to contacts.

**`FATAL: no claude.exe found`** — the VS Code extension was removed or relocated.
The path glob is in `run-check.ps1`; the version is resolved at runtime, so ordinary
extension updates are handled automatically.

**Emails stopped after a Windows reinstall / user change** — re-register the task
and re-allowlist the IP.

---

## Setting this up on a new machine

1. Clone the repo to `%LOCALAPPDATA%\portfolio-digest`. The absolute paths inside
   `check-prompt.md` assume that location; change them if you clone elsewhere.
2. Create `brevo.key` in the repo root containing only the API key, UTF-8 **without
   a BOM** and no trailing newline:
   ```powershell
   [System.IO.File]::WriteAllText("$PWD\brevo.key", "xkeysib-your-key", (New-Object System.Text.UTF8Encoding($false)))
   ```
3. Verify the sender address in Brevo (Senders, Domains & Dedicated IPs → Senders →
   Add a Sender → enter the 6-digit code emailed to you).
4. Allowlist the machine's public IPv4 address at
   https://app.brevo.com/security/authorised_ips
5. Connect the Robinhood MCP server at **user scope** so headless runs can see it:
   ```
   claude mcp add robinhood-trading --transport http https://agent.robinhood.com/mcp/trading
   ```
   Then `/mcp` and sign in. User scope matters — a project-scoped server can be
   invisible to a run started from a different working directory.
6. Register the scheduled task:
   ```powershell
   $a = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$env:LOCALAPPDATA\portfolio-digest\run-check.ps1`""
   $t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At 9:30am
   $t.Repetition = (New-ScheduledTaskTrigger -Once -At 9:30am `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Hours 6 -Minutes 30)).Repetition
   Register-ScheduledTask -TaskName "Portfolio 1pct Alert" -Action $a -Trigger $t `
        -Settings (New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable) -Force
   ```
7. Confirm everything: `powershell -ExecutionPolicy Bypass -File run-tests.ps1`
   should report 11 passed. Add `-Live` for the full 13.

## Known limitations

- Main brokerage only. Crypto, IRA, and the managed account are not included.
- Requires the laptop powered on and logged in during market hours. A missed window
  is simply not polled; there is no catch-up alert for a move you slept through.
- Intraday moves are measured against the previous close, not against the intraday
  high or your cost basis.
- News attribution is best-effort. When no company-specific story exists, the email
  says so rather than guessing.
