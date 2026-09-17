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
$OutFile = if ($env:OUTFILE) { $env:OUTFILE } else { Join-Path $OutDir "received.mp4" }
New-Item -ItemType Directory -Force $OutDir | Out-Null

Write-Host "[client] connecting to ${ServerIp}:$Port, saving to $OutFile"
$env:SERVER_IP = $ServerIp
$env:SERVER_PORT = $Port
$env:OUTFILE = $OutFile
python "$ClientPy"
