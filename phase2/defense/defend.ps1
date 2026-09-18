<#
defend.ps1 - Phase 2 one-shot defense driver for a WINDOWS victim (section 6.2).
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
# Resolve a REAL Python, skipping the Windows Store stub (the fake python.exe in
# WindowsApps that prints "Python was not found"). Prefer the 'py' launcher.
$py = $null; $pyPre = @()
$launcher = (Get-Command py -ErrorAction SilentlyContinue).Source
if ($launcher) {
    try { & $launcher -3 --version *> $null; if ($LASTEXITCODE -eq 0) { $py = $launcher; $pyPre = @('-3') } } catch {}
}
if (-not $py) {
    foreach ($name in 'python', 'python3') {
        foreach ($c in (Get-Command $name -All -ErrorAction SilentlyContinue)) {
            if ($c.Source -and $c.Source -notmatch '\\WindowsApps\\') {
                try { & $c.Source --version *> $null; if ($LASTEXITCODE -eq 0) { $py = $c.Source; break } } catch {}
            }
        }
        if ($py) { break }
    }
}
if (-not $py) {
    $guess = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($guess) { $py = $guess.FullName }
}

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
    if (-not $py) { Write-Error "No real Python found (only the Windows Store stub). Install Python 3 from python.org, or run: winget install Python.Python.3.12"; exit 1 }
    Write-Host "[defense] using Python: $py $($pyPre -join ' ')"
    Write-Host "[defense] starting ARP monitor (Ctrl+C to stop) ..."
    if ($PinWatch) { & $py @pyPre $watchpy @expectArgs --pin }
    else           { & $py @pyPre $watchpy @expectArgs }
} else {
    Write-Host "[defense] static entries in place. Verify with: .\static_arp.ps1 show"
    Write-Host "[defense] to also monitor: $py $($pyPre -join ' ') $watchpy $($expectArgs -join ' ')"
}
