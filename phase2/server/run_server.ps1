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

$Port = if ($env:PORT) { $env:PORT } else { "9000" }
# STREAM_SECONDS is intentionally NOT defaulted here: if you leave it unset the
# server auto-paces at the video's real duration (via ffprobe). Set it to
# override (e.g. $env:STREAM_SECONDS="30" for a bigger buffer).

if (-not (Test-Path $ServerPy)) { Write-Error "$ServerPy not found (copy the whole repo to this machine)"; exit 1 }

# We STREAM MPEG-TS (.ts): it plays progressively in a live player, and a copy
# truncated by the RST still plays up to the cut. $Src is the SOURCE video (your
# own file, or set $env:MEDIA); the launcher converts it to a .ts we stream. If
# $Src is missing it generates a 120s test clip.
$Src     = if ($env:MEDIA) { $env:MEDIA } else { Join-Path $MediaDir "Brawl_Stars_x_Duolingo.mp4" }
$MediaTs = Join-Path $MediaDir "stream.ts"
New-Item -ItemType Directory -Force $MediaDir | Out-Null
$HaveFfmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)

function Remux-ToTs([string]$InFile, [string]$OutTs) {
    ffmpeg -y -hide_banner -loglevel error -i "$InFile" -c copy -bsf:v h264_mp4toannexb -f mpegts "$OutTs" 2>$null
    if ($LASTEXITCODE -ne 0) {
        ffmpeg -y -hide_banner -loglevel error -i "$InFile" -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -f mpegts "$OutTs"
    }
}

if ($Src -like "*.ts") {
    if (-not (Test-Path $Src)) { Write-Error "media $Src not found"; exit 1 }
    $Media = $Src
    Write-Host "[server] streaming MPEG-TS: $Media"
} elseif (Test-Path $Src) {
    if (-not $HaveFfmpeg) { Write-Error "need ffmpeg to convert $Src to MPEG-TS (winget install Gyan.FFmpeg)"; exit 1 }
    Write-Host "[server] converting $Src to MPEG-TS -> $MediaTs ..."
    Remux-ToTs $Src $MediaTs
    $Media = $MediaTs
} elseif ($HaveFfmpeg) {
    Write-Host "[server] source video not found; generating a 120s MPEG-TS test clip -> $MediaTs ..."
    ffmpeg -y -hide_banner -loglevel error `
        -f lavfi -i "testsrc=size=640x360:rate=25:duration=120" `
        -f lavfi -i "sine=frequency=1000:duration=120" `
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac `
        -f mpegts "$MediaTs"
    $Media = $MediaTs
} else {
    $Mb = if ($env:MEDIA_MB) { [int]$env:MEDIA_MB } else { 8 }
    Write-Host "[server] ffmpeg not found; generating a $Mb MB placeholder (NOT playable - install ffmpeg)"
    $fs  = [System.IO.File]::Create($MediaTs)
    $buf = New-Object byte[] 1048576
    $rng = [System.Random]::new()
    for ($i = 0; $i -lt $Mb; $i++) { $rng.NextBytes($buf); $fs.Write($buf, 0, $buf.Length) }
    $fs.Close()
    $Media = $MediaTs
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
# Leave $env:STREAM_SECONDS untouched: if you set it, the server honours it;
# if not, the server auto-paces at the video's real duration.
python "$ServerPy"
