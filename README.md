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
| `health.json` | Written by the health check: `{"consecutive_fails":N,"alert_sent_at":"<ISO-8601>"}`. Tracks the checker's own uptime, separate from `state.json`. |
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

## Why a move happened (ETFs and stocks are explained differently)

Added 2026-10-24. Earlier, every mover got the same treatment: look up news on the
ticker, and if nothing turned up, say "likely index/sector move" and stop. That's
roughly right for a stock and close to useless for an ETF — a fund doesn't have
earnings or a CEO, so "no company news found" was true of literally every ETF,
every time, and told you nothing about what actually drove it.

**Breadth read, first.** Before looking at any single ticker, the checker counts
how many of your ~19 positions moved up, down, or stayed flat that day. Most of
them moving together means a market/macro day — Fed, rates, a broad risk-on or
risk-off move — not a story about any one holding. One or two positions doing
almost all the work while the rest sit flat means a real single-name event worth
digging into. This framing comes first in the email and free of charge — it's
built from data Step 1 already has, not an extra tool call.

**Then, type-aware research** on the top 5 dollar contributors, classified as
stock or ETF/fund (a hardcoded table of your known holdings, with
`get_equity_fundamentals` as a fallback for anything new):

- **Stocks** get the obvious treatment — earnings, guidance, analyst actions,
  M&A, legal/regulatory news.
- **Broad or growth-tilt ETFs** (QQQ, SPY, SPYG, IVV, VONG, SPMO, DIA, AOA, IJH)
  get tied back to their dominant constituents (QQQ/SPYG/VONG all ride mega-cap
  tech — if NVDA or AAPL moved sharply, that's usually the real driver) or to the
  breadth read, rather than a shrug.
- **Commodity ETFs** (GLD, COPX) get explained through the actual commodity
  driver — rates/dollar/safe-haven flows for gold, copper prices and industrial
  demand for COPX — not "earnings," which commodities don't have.

The email's "Why" section is now two groups, not one flat list: stock-specific
moves and ETF/fund moves, each explained in the vocabulary that actually fits it.

---

## Health check (watching the checker itself)

Added 2026-10-11, after an Avast antivirus bug silently broke the Robinhood
connection for about two weeks (2026-09-28 to 2026-10-11) with zero emails and no
way to notice short of realizing the silence yourself and digging through logs.
The portfolio-alert logic above only ever fires when it *can* measure a move — it
has no way to tell you when it can't measure anything at all. This closes that gap.

**How it works.** `run-check.ps1` classifies every single run as healthy or
unhealthy using an **allowlist**, not a denylist: a run only counts as healthy if
it exits 0 *and* its final line matches one of `NO ALERT pct=`, `ALERT SENT pct=`,
`TEST SENT pct=`, or `SKIP stale data` (a closed market — correctly healthy, not a
failure). Anything else — including a brand-new failure message never seen before —
is treated as unhealthy by default. That matters: the Avast incident alone produced
at least four different failure phrasings ("OAuth session expired...", "the
robinhood-trading MCP server failed to connect...", plain `InvalidHTTPResponse`
text, and others). A fixed list of known-bad strings would have missed most of
them; the allowlist can't be fooled by a new one.

**Escalation, same banding idea as the portfolio alert:**

| Consecutive failed polls | Elapsed | Action |
|---|---|---|
| 1–2 | up to 30 min | silent (rules out a single transient blip) |
| 3 | 45 min | **first DOWN alert** |
| 4+ | — | silent until 4 hours since the last alert, then **reminder** |
| back to healthy | — | **one RECOVERED email**, counters reset |

This logic lives entirely in `run-check.ps1`'s own PowerShell, deliberately *not*
decided by the Claude agent — if the agent or the MCP connection is what's broken
(exactly what happened in October), it may never get far enough to report its own
failure. The health check runs unconditionally after every invocation, succeed or
fail, so it can't be silenced by the same failure it exists to catch.

**Test it:**
```powershell
powershell -ExecutionPolicy Bypass -File run-check.ps1 -HealthTest
```
Simulates one failure landing exactly on the threshold (no real outage needed, no
real check runs) and sends a genuine DOWN email. Run a normal check afterward (or
just wait for the next poll) to see the RECOVERED email too.

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
# fast, safe, sends nothing (13 checks)
powershell -ExecutionPolicy Bypass -File run-tests.ps1

# adds 3 real email sends and two full end-to-end runs (~2.5 min)
powershell -ExecutionPolicy Bypass -File run-tests.ps1 -Live
```

Manual end-to-end portfolio alert, bypassing the threshold and the market-closed guard:
```powershell
powershell -ExecutionPolicy Bypass -File run-check.ps1 -ForceBandOverride 0
```

Manual end-to-end health DOWN-alert, no real outage needed:
```powershell
powershell -ExecutionPolicy Bypass -File run-check.ps1 -HealthTest
```

---

## Safety properties

- **No trading tools are reachable.** `run-check.ps1` allowlists exactly seven
  read tools (`get_equity_positions`, `get_equity_quotes`, `get_earnings_calendar`,
  `get_equity_fundamentals`, `get_equity_analyst_ratings`, `get_earnings_results`,
  `get_sec_filing_index`) plus `Read`, `Write`, `Edit`, `Bash`. An order call
  would be denied, not silently permitted. Test T06 enforces this — and also
  asserts `get_equity_news` is absent, since Robinhood removed that tool from
  the MCP server upstream (confirmed gone 2026-10-24).
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
working and the market simply hasn't moved 1%. If you've gone 45+ minutes during
market hours without a log entry matching the healthy pattern, the health check
(above) should have already emailed you a DOWN alert — if even *that* never
arrived, the failure is in email delivery itself (see the Brevo IP item below) or
the task isn't running at all (`Get-ScheduledTask -TaskName "Portfolio 1pct Alert"`).

**A "checker is DOWN" email arrived** — the system detected and reported its own
failure, which is the point. Check the log snippet in the email, then the full log
file, for the actual error. The 2026-10-11 incident (an antivirus TLS-interception
bug breaking the Robinhood OAuth connection) is the reference case — see git history
around that date for the full diagnostic trail if a new failure looks similar.

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
   should report 13 passed. Add `-Live` for the full 16.

## Known limitations

- Main brokerage only. Crypto, IRA, and the managed account are not included.
- Requires the laptop powered on and logged in during market hours. A missed window
  is simply not polled; there is no catch-up alert for a move you slept through.
- Intraday moves are measured against the previous close, not against the intraday
  high or your cost basis.
- News attribution is best-effort. When no company-specific story exists, the email
  says so rather than guessing.
- **The health check shares its only delivery channel with everything else.** If
  Brevo itself is down, or this machine has no internet at all, the DOWN alert
  can't be sent either — there's no second channel to fall back to. A silent
  multi-day outage would most likely be a total network/power loss, which the
  health check can't phone home about by definition.
- The health check has no visibility into *why* the market data might be wrong in
  a way that still exits 0 and matches the allowlist (e.g. a quote that's stale by
  a few minutes rather than a full session) — it only catches hard failures where
  the connector couldn't be reached or auth couldn't complete at all.
