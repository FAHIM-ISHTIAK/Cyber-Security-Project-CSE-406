<#
defend.ps1 - Phase 2 one-shot defense driver for a WINDOWS victim (§6.2).
Run in an ELEVATED PowerShell (Admin), BEFORE launching the attacker.

Ties the two ARP-layer defenses together for one victim machine:
  1) PREVENT - pin the peer's real IP->MAC as a static neighbour so forged ARP
     replies are ignored and the MITM never forms (static_arp.ps1 pin).
  2) DETECT  - run arp_watch.py so any poisoning attempt is flagged at once.

Run on the CLIENT (pin the SERVER) and, ideally, on the SERVER (pin the CLIENT).
Best practice: read the peer's real MAC on the peer itself and pass -PeerMac.

Usage (Admin PowerShell):
  .\defend.ps1 -Peer <peer_ip> [-PeerMac <mac>] [-Gateway <gw_ip|auto>]
               [-Watch] [-PinWatch] [-NoPin]
    -Peer      machine to protect against being spoofed (server IP on the client;
               client IP on the server). REQUIRED.
    -PeerMac   the peer's real MAC (skip auto-learn; most trustworthy).
    -Gateway   also pin+watch the gateway ('auto' to detect it).
    -Watch     after pinning, run the arp_watch monitor in the foreground.
    -PinWatch  like -Watch but auto-heals (re-pins) on detection.
    -NoPin     detection only: skip static pinning, just run arp_watch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Peer,
    [string]$PeerMac = "",
    [string]$Gateway = "",
    [switch]$Watch,
    [switch]$PinWatch,
    [switch]$NoPin,
    [switch]$Off
)

$here   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$static = Join-Path $here "static_arp.ps1"
$watchpy= Join-Path $here "arp_watch.py"
$py     = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { Write-Error "Run this in an ELEVATED PowerShell (Run as administrator)."; exit 1 }

if ($Gateway -eq "auto") {
    $Gateway = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } |
        Select-Object -First 1).IPv4DefaultGateway.NextHop
    if ($Gateway) { Write-Host "[defense] auto-detected gateway: $Gateway" }
}

# -Off: turn the defense OFF again (remove the static entries) to re-show the attack.
if ($Off) {
    Write-Host "[defense] === turning defense OFF on this host: unpinning peer=$Peer $(if($Gateway){"gateway=$Gateway"}) ==="
    & powershell -ExecutionPolicy Bypass -File $static unpin $Peer
    if ($Gateway) { & powershell -ExecutionPolicy Bypass -File $static unpin $Gateway }
    Write-Host "[defense] static entries removed; ARP is dynamic again. (Ctrl+C the arp_watch monitor if running.)"
    exit 0
}

$expectArgs = @()
function Pin-One([string]$ip, [string]$mac) {
    if (-not $NoPin) {
        if ($mac) { & powershell -ExecutionPolicy Bypass -File $static pin $ip $mac }
        else      { & powershell -ExecutionPolicy Bypass -File $static pin $ip }
    }
    $line = & powershell -ExecutionPolicy Bypass -File $static verify $ip
    $m = [regex]::Match(($line -join " "), '([0-9a-f]{2}:){5}[0-9a-f]{2}')
    if ($m.Success) { $script:expectArgs += @("--expect", "$ip=$($m.Value)") }
}

Write-Host "[defense] === protecting this host: peer=$Peer $(if($Gateway){"gateway=$Gateway"}) pin=$(if($NoPin){'no'}else{'yes'}) ==="
Pin-One $Peer $PeerMac
if ($Gateway) { Pin-One $Gateway "" }

if ($Watch -or $PinWatch) {
    if (-not $py) { Write-Error "python not found; install Python 3 to run the arp_watch monitor."; exit 1 }
    Write-Host "[defense] starting ARP monitor (Ctrl+C to stop) ..."
    if ($PinWatch) { & $py $watchpy @expectArgs --pin }
    else           { & $py $watchpy @expectArgs }
} else {
    Write-Host "[defense] static entries in place. Verify with: .\static_arp.ps1 show"
    Write-Host "[defense] to also monitor: $py $watchpy $($expectArgs -join ' ')"
}
