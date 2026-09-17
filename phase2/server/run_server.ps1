# run_server.ps1 - Phase 2 (physical) launcher for the video server on Windows.
#
# Runs the SAME server code as Phase 1 (server\stream_server.py) natively, no
# Docker. Binds 0.0.0.0:9000 so the client (over Wi-Fi/LAN) can connect. If no
# media file exists it bakes a 120s test video with ffmpeg (if installed).
#
# Usage (PowerShell):
#   .\run_server.ps1
#   $env:MEDIA="C:\path\to\video.mp4"; .\run_server.ps1
#   $env:PORT="9000"; $env:STREAM_SECONDS="120"; .\run_server.ps1
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path "$ScriptDir\..\..").Path
$ServerPy  = Join-Path $RepoRoot "server\stream_server.py"
$MediaDir  = Join-Path $RepoRoot "phase2\media"

$Port          = if ($env:PORT) { $env:PORT } else { "9000" }
$StreamSeconds = if ($env:STREAM_SECONDS) { $env:STREAM_SECONDS } else { "120" }
$Media         = if ($env:MEDIA) { $env:MEDIA } else { Join-Path $MediaDir "sample.mp4" }

if (-not (Test-Path $ServerPy)) { Write-Error "$ServerPy not found (copy the whole repo to this machine)"; exit 1 }

if (-not (Test-Path $Media)) {
    if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
        Write-Host "[server] no media file; generating a 120s test video at $Media ..."
        New-Item -ItemType Directory -Force (Split-Path $Media) | Out-Null
        ffmpeg -hide_banner -loglevel error `
            -f lavfi -i "testsrc=size=640x360:rate=25:duration=120" `
            -f lavfi -i "sine=frequency=1000:duration=120" `
            -c:v libx264 -preset veryfast -pix_fmt yuv420p `
            -c:a aac -shortest "$Media"
    } else {
        Write-Error "media file $Media missing and ffmpeg not installed. Install ffmpeg or set `$env:MEDIA to a video path."
        exit 1
    }
}

Write-Host "[server] ------------------------------------------------------------"
Write-Host "[server] This machine's LAN IPv4 address(es) - tell the CLIENT & ATTACKER:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
    ForEach-Object { "    $($_.InterfaceAlias)  $($_.IPAddress)" }
Write-Host "[server] Serving $Media on 0.0.0.0:$Port (Ctrl+C to stop)"
Write-Host "[server] If the client cannot connect, allow inbound TCP $Port through Windows Firewall:"
Write-Host "[server]   New-NetFirewallRule -DisplayName 'RST demo $Port' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow"
Write-Host "[server] ------------------------------------------------------------"

$env:BIND_ADDR = "0.0.0.0"
$env:PORT = $Port
$env:MEDIA = $Media
$env:STREAM_SECONDS = $StreamSeconds
python "$ServerPy"
