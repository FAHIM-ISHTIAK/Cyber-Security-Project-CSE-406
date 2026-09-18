# run_client.ps1 - Phase 2 (physical) launcher for the victim client on Windows.
#
# Runs the SAME client code as Phase 1 (client\stream_client.py) natively, no
# Docker. Connects over the LAN/Wi-Fi to the server's real IP.
#
# Usage (PowerShell):
#   .\run_client.ps1 192.168.1.10
#   $env:SERVER_IP="192.168.1.10"; .\run_client.ps1
#   $env:RECONNECT="1"; .\run_client.ps1 192.168.1.10   # measure auto-retry
param([string]$ServerIp)
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path "$ScriptDir\..\..").Path
$ClientPy  = Join-Path $RepoRoot "client\stream_client.py"
$OutDir    = Join-Path $RepoRoot "phase2\output"

if (-not $ServerIp) { $ServerIp = $env:SERVER_IP }
if (-not $ServerIp) { Write-Error "usage: .\run_client.ps1 <server_ip>  (or set `$env:SERVER_IP)"; exit 1 }
if (-not (Test-Path $ClientPy)) { Write-Error "$ClientPy not found (copy the whole repo to this machine)"; exit 1 }

$Port    = if ($env:SERVER_PORT) { $env:SERVER_PORT } else { "9000" }
# The server streams MPEG-TS, so save as .ts (a truncated .ts still plays).
$OutFile = if ($env:OUTFILE) { $env:OUTFILE } else { Join-Path $OutDir "received.ts" }
$Player  = if ($env:PLAYER) { $env:PLAYER } else { "auto" }   # auto | ffplay | mpv | none
New-Item -ItemType Directory -Force $OutDir | Out-Null

Write-Host "[client] connecting to ${ServerIp}:$Port, saving to $OutFile (player=$Player)"
$env:SERVER_IP = $ServerIp
$env:SERVER_PORT = $Port
$env:OUTFILE = $OutFile
$env:PLAYER = $Player
python "$ClientPy"

# Also produce a playable .mp4 from the saved .ts (works even if truncated).
if ($OutFile -like "*.ts" -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0) -and (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    $Mp4 = [System.IO.Path]::ChangeExtension($OutFile, ".mp4")
    Write-Host "[client] remuxing $OutFile -> $Mp4 ..."
    ffmpeg -y -hide_banner -loglevel error -i "$OutFile" -c copy "$Mp4" 2>$null
    if ($LASTEXITCODE -ne 0) { ffmpeg -y -hide_banner -loglevel error -i "$OutFile" -c:v libx264 -c:a aac "$Mp4" 2>$null }
    if ($LASTEXITCODE -ne 0) { Write-Host "[client] (could not make .mp4; the .ts still plays)" }
}
