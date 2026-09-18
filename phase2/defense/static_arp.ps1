<#
static_arp.ps1 - Phase 2 ARP-layer defense for a WINDOWS victim (proposal §6.2).
Run on the CLIENT and/or the SERVER machine, in an ELEVATED PowerShell (Admin).

The attack only works because ARP poisoning puts the attacker on-path so it can
read the live TCP sequence numbers. Pinning a peer's real IP->MAC as a STATIC
neighbour makes Windows ignore the attacker's forged ARP replies, so the MITM
never forms and the attack collapses to the far-harder blind case.

This can LEARN the peer's real MAC for you (do it BEFORE the attacker starts), or
you can pass it explicitly (read it ON the peer: `getmac /v`, or Linux
`cat /sys/class/net/<iface>/address`).

Usage (Admin PowerShell):
  .\static_arp.ps1 pin   <peer_ip> [peer_mac]   # learn (or use given) MAC, pin it
  .\static_arp.ps1 unpin <peer_ip>              # remove the static entry
  .\static_arp.ps1 show                         # print the neighbour table
  .\static_arp.ps1 verify <peer_ip> [peer_mac]  # is peer_ip pinned (to peer_mac)?

Typical: on the CLIENT pin the SERVER's IP; on the SERVER pin the CLIENT's IP.
Pinning the gateway too is good practice.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action = "",
    [Parameter(Position=1)][string]$Ip = "",
    [Parameter(Position=2)][string]$Mac = ""
)

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Need-Admin {
    if (-not (Test-Admin)) {
        Write-Error "Run this in an ELEVATED PowerShell (Right-click -> Run as administrator)."
        exit 1
    }
}
# Normalise a MAC to lowercase colon form (accepts aa-bb.. / AA:BB.. / aabb..).
function Normalize-Mac([string]$m) {
    if (-not $m) { return "" }
    $h = ($m -replace '[^0-9A-Fa-f]', '').ToLower()
    if ($h.Length -ne 12) { return $m.ToLower().Replace('-',':') }
    return ($h -split '(.{2})' | Where-Object { $_ } ) -join ':'
}
# The netsh/route table key by interface index; resolve it from the route to $ip.
function Get-IfIndex([string]$ip) {
    try { return (Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop)[0].InterfaceIndex }
    catch { return (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).InterfaceIndex }
}
function Get-IfAlias([int]$idx) { (Get-NetAdapter -InterfaceIndex $idx).Name }

# Read the cached MAC for an IP (dynamic or static) from the neighbour table.
function Get-CachedMac([string]$ip) {
    try {
        $n = Get-NetNeighbor -IPAddress $ip -ErrorAction Stop | Where-Object { $_.LinkLayerAddress } | Select-Object -First 1
        if ($n) { return (Normalize-Mac $n.LinkLayerAddress) }
    } catch {}
    return ""
}

function Learn-Mac([string]$ip) {
    # Force ARP resolution, then read the table. Must be BEFORE the attacker poisons.
    Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Milliseconds 300
    return (Get-CachedMac $ip)
}

function Do-Pin([string]$ip, [string]$mac) {
    if (-not $ip) { Write-Error "usage: .\static_arp.ps1 pin <peer_ip> [peer_mac]"; exit 1 }
    Need-Admin
    $idx = Get-IfIndex $ip
    if (-not $idx) { Write-Error "could not determine interface to reach $ip"; exit 1 }
    $alias = Get-IfAlias $idx
    if (-not $mac) {
        Write-Host "[defense] no MAC given; learning $ip's real MAC (do this BEFORE the attack) ..."
        $mac = Learn-Mac $ip
        if (-not $mac) { Write-Error "could not learn MAC for $ip. Is it up on the same LAN? Or pass it: .\static_arp.ps1 pin $ip <mac>"; exit 1 }
        Write-Host "[defense] learned $ip -> $mac"
    }
    $mac = Normalize-Mac $mac
    # Remove any existing (poisoned/dynamic) entry first, then add the static one.
    netsh interface ipv4 delete neighbors interface="$alias" "$ip" 2>$null | Out-Null
    $out = netsh interface ipv4 add neighbors interface="$alias" address="$ip" neighbor="$mac"
    if ($LASTEXITCODE -ne 0) {
        # Fallback to the modern cmdlet form (mac must use dashes here).
        New-NetNeighbor -InterfaceIndex $idx -IPAddress $ip -LinkLayerAddress ($mac.Replace(':','-')) -State Permanent -ErrorAction Stop | Out-Null
    }
    Write-Host "[defense] PINNED $ip -> $mac (static) on '$alias'"
    Write-Host "[defense] forged ARP replies for $ip will now be IGNORED by this host."
    Do-Verify $ip $mac | Out-Null
}

function Do-Unpin([string]$ip) {
    if (-not $ip) { Write-Error "usage: .\static_arp.ps1 unpin <peer_ip>"; exit 1 }
    Need-Admin
    $idx = Get-IfIndex $ip
    $alias = Get-IfAlias $idx
    netsh interface ipv4 delete neighbors interface="$alias" "$ip" 2>$null | Out-Null
    Remove-NetNeighbor -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[defense] removed static entry for $ip (ARP resolution reverts to dynamic)"
}

function Do-Show() { Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.LinkLayerAddress } |
    Sort-Object IPAddress | Format-Table IPAddress, LinkLayerAddress, State, InterfaceAlias -AutoSize }

function Do-Verify([string]$ip, [string]$want) {
    $have = Get-CachedMac $ip
    if (-not $have) { Write-Host "[defense] verify: $ip has NO entry"; return $false }
    if ($want) {
        $want = Normalize-Mac $want
        if ($have -eq $want) { Write-Host "[defense] verify: OK  $ip -> $have (matches expected)"; return $true }
        else { Write-Host "[defense] verify: !! $ip -> $have  BUT expected $want  (POSSIBLE POISONING)"; return $false }
    }
    Write-Host "[defense] verify: $ip -> $have"; return $true
}

switch ($Action.ToLower()) {
    "pin"    { Do-Pin $Ip $Mac }
    "unpin"  { Do-Unpin $Ip }
    "show"   { Do-Show }
    "verify" { Do-Verify $Ip $Mac | Out-Null }
    default  { Write-Host "usage: .\static_arp.ps1 {pin <ip> [mac] | unpin <ip> | show | verify <ip> [mac]}" }
}
