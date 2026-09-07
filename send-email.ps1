<#
  send-email.ps1 — sends an email via the Brevo transactional API.

  The API key is read from brevo.key in this same folder. It is never placed on a
  command line (which would expose it to the local process list) — it is passed to
  curl through a temporary config file that is deleted afterwards.

  Requests are forced onto IPv4 (-4) because Brevo's "Authorised IPs" allowlist is
  per-address, and Windows rotates temporary IPv6 addresses. The stable IPv4 address
  must be allowlisted at https://app.brevo.com/security/authorised_ips

  Usage:
    .\send-email.ps1 -Subject "Hello" -Html "<p>body</p>"
    .\send-email.ps1 -Subject "Weekly digest" -HtmlPath .\digest.html
#>
param(
    [Parameter(Mandatory = $true)][string]$Subject,
    [string]$Html,
    [string]$HtmlPath,
    [string]$To        = "nakulbharadwaj@gmail.com",
    [string]$FromEmail = "nakulbharadwaj@gmail.com",
    [string]$FromName  = "Portfolio Digest"
)

$ErrorActionPreference = "Stop"

$keyPath = Join-Path $PSScriptRoot "brevo.key"
if (-not (Test-Path $keyPath)) { throw "API key not found at $keyPath" }
$apiKey = [System.IO.File]::ReadAllText($keyPath).Trim()
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "API key file is empty" }

if ($HtmlPath) {
    if (-not (Test-Path $HtmlPath)) { throw "HTML file not found: $HtmlPath" }
    $body = [System.IO.File]::ReadAllText($HtmlPath)
} elseif ($Html) {
    $body = $Html
} else {
    throw "Provide either -Html or -HtmlPath"
}

$payload = @{
    sender      = @{ name = $FromName; email = $FromEmail }
    to          = @(@{ email = $To })
    subject     = $Subject
    htmlContent = $body
} | ConvertTo-Json -Depth 6

$stamp    = [Guid]::NewGuid().ToString("N")
$bodyFile = Join-Path $env:TEMP "brevo-body-$stamp.json"
$cfgFile  = Join-Path $env:TEMP "brevo-cfg-$stamp.txt"

try {
    # UTF-8 without BOM; a BOM would corrupt the JSON.
    [System.IO.File]::WriteAllText($bodyFile, $payload, (New-Object System.Text.UTF8Encoding($false)))

    # curl config uses backslash as an escape character inside quotes, so use forward slashes.
    $bodyFwd = $bodyFile -replace '\\', '/'
    $cfg = @(
        "header = `"api-key: $apiKey`""
        "header = `"content-type: application/json`""
        "header = `"accept: application/json`""
        "url = `"https://api.brevo.com/v3/smtp/email`""
        "data = `"@$bodyFwd`""
    )
    [System.IO.File]::WriteAllLines($cfgFile, $cfg)

    $out  = & curl.exe -4 -s -S --config $cfgFile -w "`nHTTP_CODE:%{http_code}"
    $text = ($out | Out-String)
    $code = 0
    if ($text -match 'HTTP_CODE:(\d+)') { $code = [int]$Matches[1] }

    if ($code -ge 200 -and $code -lt 300) {
        $msgId = ""
        if ($text -match '"messageId"\s*:\s*"([^"]+)"') { $msgId = $Matches[1] }
        "SENT ok  http=$code  messageId=$msgId"
    }
    else {
        "FAILED  http=$code"
        ($text -replace 'HTTP_CODE:\d+', '').Trim()
        if ($text -match 'unrecognised IP address ([0-9a-fA-F:.]+)') {
            "HINT: allowlist $($Matches[1]) at https://app.brevo.com/security/authorised_ips"
        }
        exit 1
    }
}
finally {
    if (Test-Path $cfgFile)  { Remove-Item $cfgFile  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
}
