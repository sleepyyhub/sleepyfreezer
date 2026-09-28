# Roblox Studio MCP -> public HTTPS bridge (Windows / PowerShell 5.1+)
# stdio mcp.bat -> supergateway (:8000) -> auth-proxy (:8001, bearer token) -> Cloudflare quick tunnel
# Needs: Node.js (npx), cloudflared (winget install --id Cloudflare.cloudflared)
# Run:   powershell -ExecutionPolicy Bypass -File .\bridge\start-bridge.ps1

param([int]$Port = 8000, [int]$ProxyPort = 8001)

$ErrorActionPreference = 'Stop'
$robloxDir = Join-Path $env:LOCALAPPDATA 'Roblox'
if (-not (Test-Path (Join-Path $robloxDir 'mcp.bat'))) { throw "mcp.bat not found in $robloxDir" }
foreach ($tool in 'npx', 'node', 'cloudflared') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH" }
}

# Token persists across runs so the cloud secret only has to be set once.
$tokenFile = Join-Path $PSScriptRoot '.token'
if (-not (Test-Path $tokenFile)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [BitConverter]::ToString($bytes).Replace('-', '').ToLower() | Set-Content -NoNewline $tokenFile
}
$token = (Get-Content -Raw $tokenFile).Trim()

# mcp.bat expects to run from its own folder, so the gateway starts there.
$gateway = Start-Process -PassThru -NoNewWindow -WorkingDirectory $robloxDir -FilePath 'cmd.exe' `
    -ArgumentList '/c', "npx -y supergateway --stdio `"cmd /c mcp.bat`" --outputTransport streamableHttp --port $Port"

$env:MCP_TOKEN = $token; $env:PROXY_PORT = $ProxyPort; $env:TARGET_PORT = $Port
$proxy = Start-Process -PassThru -NoNewWindow -FilePath 'node' -ArgumentList "`"$(Join-Path $PSScriptRoot 'auth-proxy.js')`""

$log = Join-Path $env:TEMP 'roblox-mcp-tunnel.log'
Remove-Item $log -ErrorAction SilentlyContinue
$tunnel = Start-Process -PassThru -WindowStyle Hidden -FilePath 'cloudflared' `
    -ArgumentList 'tunnel', '--url', "http://127.0.0.1:$ProxyPort", '--logfile', "`"$log`""

try {
    $url = $null
    for ($i = 0; $i -lt 60 -and -not $url; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $log) {
            $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Value }
        }
    }
    if (-not $url) { throw "tunnel didn't come up, check $log" }

    Write-Host ""
    Write-Host "ROBLOX_MCP_URL   = $url/mcp" -ForegroundColor Green
    Write-Host "ROBLOX_MCP_TOKEN = $token" -ForegroundColor Green
    Write-Host "Put both in the cloud environment's variables, then start a new session. Ctrl+C closes the bridge." -ForegroundColor Yellow
    Wait-Process -Id $tunnel.Id
}
finally {
    foreach ($p in $tunnel, $proxy, $gateway) { if ($p -and -not $p.HasExited) { taskkill /PID $p.Id /T /F | Out-Null } }
}
