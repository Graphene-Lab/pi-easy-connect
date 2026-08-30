# pi-easy-connect.ps1
# Share this Windows PC's internet with ANY Linux device (Raspberry Pi, Orange Pi,
# Jetson, VM, ...) connected via an Ethernet cable, then open an SSH session to it.
# Built on Windows Internet Connection Sharing (ICS):
#   - PUBLIC adapter  = internet source (default route, usually Wi-Fi) -> ICSSHARINGTYPE_PUBLIC  = 0
#   - PRIVATE adapter = Ethernet port facing the device               -> ICSSHARINGTYPE_PRIVATE = 1
# The private port becomes 192.168.137.1/24 with a built-in DHCP server, so the
# device gets an IP on its own and needs NO manual network configuration.
# Run as Administrator.
#
# Usage:
#   .\pi-easy-connect.ps1                     enable ICS, find the device on 192.168.137.x, open SSH
#   .\pi-easy-connect.ps1 -Undo               disable ICS and restore (safe cleanup)
#   .\pi-easy-connect.ps1 -Force              skip the interactive confirmation
#   .\pi-easy-connect.ps1 -SshUser pi         SSH user of the target device (default: orangepi)
#   .\pi-easy-connect.ps1 -StaticIp 192.168.137.100   fast path for a static-IP device
#   .\pi-easy-connect.ps1 -DiscoveryTimeoutSec 300   longer search window (slow DHCP)
#
# Official Microsoft references:
#   SHARINGCONNECTIONTYPE: ICSSHARINGTYPE_PUBLIC = 0, ICSSHARINGTYPE_PRIVATE = 1
#     https://learn.microsoft.com/en-us/windows/win32/api/netcon/ne-netcon-sharingconnectiontype
#   INetSharingConfiguration::EnableSharing / DisableSharing / SharingEnabled:
#     https://learn.microsoft.com/en-us/windows/win32/api/netcon/nn-netcon-inetsharingconfiguration
#   KB4055559 (the ICS service stops after ~4 minutes without traffic):
#     https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/ics-not-work-after-computer-or-service-restart

param(
    [switch]$Undo,
    [switch]$Force,
    [string]$SshUser = "orangepi",
    [string]$ProbeHost = "1.1.1.1",
    [string]$StaticIp = "",
    [int]$DiscoveryTimeoutSec = 120
)

$ErrorActionPreference = "Stop"

# --- Self-elevate (ICS requires administrator privileges) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Undo)     { $argLine += " -Undo" }
    if ($Force)    { $argLine += " -Force" }
    if ($SshUser -ne "orangepi") { $argLine += " -SshUser $SshUser" }
    if ($StaticIp) { $argLine += " -StaticIp $StaticIp" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine
    exit
}

function Test-HostInternet {
    param([string]$Target = $ProbeHost)
    try {
        return [bool](Test-NetConnection -ComputerName $Target -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Disable-AllIcs {
    # Disable ICS on every connection that has it active (official DisableSharing method).
    $mgr = New-Object -ComObject HNetCfg.HNetShare
    $disabled = @()
    foreach ($conn in @($mgr.EnumEveryConnection)) {
        $props = $mgr.NetConnectionProps.Invoke($conn)
        $cfg   = $mgr.INetSharingConfigurationForINetConnection.Invoke($conn)
        if ($cfg.SharingEnabled) {
            $cfg.DisableSharing()
            $disabled += $props.Name
        }
    }
    return $disabled
}

function Clear-StaleIcsState {
    # Reset leftover IsIcsPublic/IsIcsPrivate flags in the WMI namespace root\Microsoft\HomeNet.
    # Same cleanup as the icsmanager library (CleanupWMISharingEntries): interrupted ICS runs
    # leave dead connections flagged as public/private, which makes EnableSharing fail with
    # 0x80040201 ("an event was unable to invoke any of the subscribers").
    try {
        $scope = New-Object System.Management.ManagementScope("root\Microsoft\HomeNet")
        $scope.Connect()
        $query = New-Object System.Management.ObjectQuery("SELECT * FROM HNet_ConnectionProperties")
        $searcher = New-Object System.Management.ManagementObjectSearcher($scope, $query)
        $cleaned = 0
        foreach ($entry in $searcher.Get()) {
            if ([bool]$entry["IsIcsPrivate"] -or [bool]$entry["IsIcsPublic"]) {
                $entry["IsIcsPrivate"] = $false
                $entry["IsIcsPublic"]  = $false
                $entry.Put() | Out-Null
                $cleaned++
            }
        }
        if ($cleaned -gt 0) { Write-Host ("Stale ICS state cleared: " + $cleaned + " entr(ies) reset.") -ForegroundColor Green }
        else                { Write-Host "No stale ICS state found." -ForegroundColor Green }
    } catch {
        Write-Warning ("Stale ICS cleanup failed: " + $_.Exception.Message)
    }
}

function Reset-IcsRegistryIndexes {
    # Reset the persisted private/public adapter indexes of a previous ICS configuration.
    param([string]$SharedKey)
    try {
        $oldPriv = [int]((Get-ItemProperty $SharedKey -ErrorAction SilentlyContinue).PrivateIndex)
        $oldPub  = [int]((Get-ItemProperty $SharedKey -ErrorAction SilentlyContinue).PublicIndex)
        if ($oldPriv -ne 0 -or $oldPub -ne 0) {
            Set-ItemProperty -Path $SharedKey -Name PrivateIndex -Value 0 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $SharedKey -Name PublicIndex  -Value 0 -ErrorAction SilentlyContinue
            Write-Host ("Resetting leftover ICS indexes (were PrivateIndex=" + $oldPriv + ", PublicIndex=" + $oldPub + ").") -ForegroundColor Yellow
        }
    } catch { }
}

function Enable-IcsPair {
    # Enable ICS using the official constants (0=PUBLIC, 1=PRIVATE) and verify by read-back.
    param($mgr, $pubConn, $privConn, $pubName, $privName)
    $pubCfg  = $mgr.INetSharingConfigurationForINetConnection.Invoke($pubConn)
    $privCfg = $mgr.INetSharingConfigurationForINetConnection.Invoke($privConn)
    if (-not $pubCfg.SharingEnabled)  { $pubCfg.EnableSharing($ICS_PUBLIC) }
    if (-not $privCfg.SharingEnabled) { $privCfg.EnableSharing($ICS_PRIVATE) }
    Start-Sleep -Seconds 4
    if ([int]$pubCfg.SharingConnectionType  -ne $ICS_PUBLIC)  { throw "Wrong type on '$pubName': expected 0 (public), got $($pubCfg.SharingConnectionType)" }
    if ([int]$privCfg.SharingConnectionType -ne $ICS_PRIVATE) { throw "Wrong type on '$privName': expected 1 (private), got $($privCfg.SharingConnectionType)" }
}

function Invoke-IcsRollback {
    param([string]$Reason)
    Write-Host ("AUTO-ROLLBACK: " + $Reason) -ForegroundColor Yellow
    try {
        $off = Disable-AllIcs
        if ($off.Count) { Write-Host ("ICS disabled on: " + ($off -join ", ")) -ForegroundColor Green }
    } catch {
        Write-Warning ("Rollback failed: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 3
    if (Test-HostInternet) {
        Write-Host "Host internet: OK - no damage." -ForegroundColor Green
    } else {
        Write-Host "Host internet: STILL DOWN." -ForegroundColor Red
        Write-Host "Manual recovery:" -ForegroundColor Yellow
        Write-Host "  1. Settings > Network & Internet > Wi-Fi > properties: IP assignment = Automatic (DHCP)" -ForegroundColor White
        Write-Host "  2. Or from an admin PowerShell: Restart-NetAdapter -Name <Wi-Fi name>" -ForegroundColor White
        Write-Host "  3. Or run: ipconfig /release then ipconfig /renew" -ForegroundColor White
    }
}

function Find-DeviceIp {
    param([int]$PortIfIndex, [string]$StaticIp)
    # 0) Known static IP (fastest path)
    if ($StaticIp) {
        $p = New-Object System.Net.NetworkInformation.Ping
        try {
            $r = $p.Send($StaticIp, 500)
            if ($r.Status -eq "Success") { return $StaticIp }
        } catch { }
    }
    # 1) Low addresses first: the ICS DHCP server starts assigning from 192.168.137.2
    foreach ($i in 2..15) {
        $p = New-Object System.Net.NetworkInformation.Ping
        try {
            $r = $p.Send("192.168.137.$i", 400)
            if ($r.Status -eq "Success") { return "192.168.137.$i" }
        } catch { }
    }
    # 2) Parallel sweep of the rest of the subnet (one Ping object PER address:
    #    the Ping class does not support concurrent requests on the same instance)
    $tasks = @()
    for ($i = 16; $i -le 254; $i++) {
        $p = New-Object System.Net.NetworkInformation.Ping
        $tasks += $p.SendPingAsync("192.168.137.$i", 500)
    }
    try { [System.Threading.Tasks.Task]::WaitAll($tasks, 30000) | Out-Null } catch { }
    for ($j = 0; $j -lt $tasks.Count; $j++) {
        try {
            if ($tasks[$j].Result.Status -eq "Success") { return "192.168.137.$($j + 16)" }
        } catch { }
    }
    # 3) ARP/neighbor cache (works even when ICMP is blocked on the device; the ICS
    #    DHCP allocator registers leased clients as Permanent neighbors)
    try {
        $nb = Get-NetNeighbor -InterfaceIndex $PortIfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -like "192.168.137.*" -and $_.State -in @("Reachable", "Stale", "Delay", "Permanent") }
        if ($nb) {
            return ($nb | Sort-Object { [int](($_.IPAddress -split '\.')[-1]) } | Select-Object -First 1).IPAddress
        }
    } catch { }
    return $null
}

# ============================ UNDO ============================
if ($Undo) {
    Write-Host "=== Disabling ICS ===" -ForegroundColor Cyan
    try {
        $off = Disable-AllIcs
        if ($off.Count) { Write-Host ("ICS disabled on: " + ($off -join ", ")) -ForegroundColor Green }
        else            { Write-Host "ICS was not active on any connection." }
    } catch {
        Write-Warning ("Error: " + $_.Exception.Message)
    }
    # Restore DHCP on the device port (belt and braces)
    $eth = Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq "802.3" -and $_.InterfaceDescription -notmatch "Bluetooth|VirtualBox|Hyper-V" } | Select-Object -First 1
    if ($eth) {
        try {
            Set-NetIPInterface -InterfaceIndex $eth.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop | Out-Null
            Write-Host ("DHCP restored on " + $eth.Name) -ForegroundColor Green
        } catch {
            Write-Warning ("DHCP on " + $eth.Name + ": " + $_.Exception.Message)
        }
    }
    # Clear any leftover ICS state (WMI flags + registry indexes of an old configuration)
    Clear-StaleIcsState
    Reset-IcsRegistryIndexes -SharedKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedAccess"
    $ok = Test-HostInternet
    Write-Host ("Host internet: " + $(if ($ok) { "OK" } else { "manual check recommended" })) -ForegroundColor $(if ($ok) { "Green" } else { "Yellow" })
    exit
}

# ============================ MAIN ============================
Write-Host "=== Pi Easy Connect (ICS bridge) ===" -ForegroundColor Cyan

# 1) Internet source = adapter with the IPv4 default route (NOT guessed by name)
$route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) {
    Write-Error "No IPv4 default route found: this PC does not seem to be connected to the internet. Aborting without changes."
    exit 1
}
$pub = Get-NetAdapter -InterfaceIndex $route.ifIndex
Write-Host ("Internet via: '" + $pub.Name + "' (" + $pub.InterfaceDescription + ")") -ForegroundColor Green

# 2) Device port = physical Ethernet adapter that is NOT the internet adapter
$priv = Get-NetAdapter -Physical | Where-Object {
    $_.MediaType -eq "802.3" -and
    $_.InterfaceDescription -notmatch "Bluetooth|VirtualBox|Hyper-V" -and
    $_.ifIndex -ne $pub.ifIndex
} | Select-Object -First 1
if (-not $priv) {
    Write-Error "No free physical Ethernet port found (if internet comes over Ethernet you need a second port or a USB-Ethernet adapter)."
    exit 1
}
Write-Host ("Device port: '" + $priv.Name + "' (" + $priv.InterfaceDescription + ") [" + $priv.Status + "]") -ForegroundColor Green

# 3) Safety guards
$conflict = $pub | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "192.168.137.*" } | Select-Object -First 1
if ($conflict) {
    Write-Error "The internet source already uses the 192.168.137.x subnet: ICS cannot be used. Switch network and retry."
    exit 1
}
if ($priv.Status -ne "Up") {
    Write-Host ("WARNING: the device port is '" + $priv.Status + "'. Connect the Ethernet cable to the device and power it on.") -ForegroundColor Yellow
    if (-not $Force) { Read-Host "Press ENTER to continue anyway, or Ctrl+C to exit" }
}

# 4) Internet status (before touching anything)
$hadInternet = Test-HostInternet
Write-Host ("Host internet (before): " + $(if ($hadInternet) { "OK" } else { "DOWN - check the internet connection first" })) -ForegroundColor $(if ($hadInternet) { "Green" } else { "Red" })

# 5) Plan + confirmation
Write-Host ""
Write-Host "Plan:" -ForegroundColor Cyan
Write-Host ("  - Share the internet of '" + $pub.Name + "' (public) toward '" + $priv.Name + "' (private, 192.168.137.1).") -ForegroundColor White
Write-Host "  - The public adapter keeps its IP (DHCP): it is not modified." -ForegroundColor White
Write-Host "  - If the host loses internet after activation, the script disables everything automatically." -ForegroundColor White
if (-not $Force) {
    $r = Read-Host "Proceed? [Y/N]"
    if ($r -notmatch "^[yY]") { Write-Host "Aborted. No changes made."; exit 0 }
}

# 6) Enable ICS via the HNetCfg COM API (Set-NetConnectionShared does not exist on current builds)
Write-Host "`nEnabling internet sharing (SharedAccess service)..."

# 6a) Clean leftover state: WMI flags + registry indexes of an old configuration
#     (the cause of 0x80040201: dead connections still flagged public/private in WMI)
Clear-StaleIcsState
Reset-IcsRegistryIndexes -SharedKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedAccess"

# 6b) Restart SharedAccess: re-registers the event subscribers from scratch
#     (interrupted runs leave the service in an inconsistent state)
$svc = Get-Service SharedAccess -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Error "SharedAccess service missing: ICS is not supported on this system."
    exit 1
}
try {
    if ($svc.Status -eq "Running") { Restart-Service SharedAccess -ErrorAction Stop }
    else                           { Start-Service SharedAccess -ErrorAction Stop }
    Write-Host "SharedAccess service restarted."
    Start-Sleep -Seconds 4
} catch {
    Write-Warning ("SharedAccess restart failed (continuing anyway): " + $_.Exception.Message)
}

$ICS_PUBLIC  = 0  # ICSSHARINGTYPE_PUBLIC  = adapter that provides internet
$ICS_PRIVATE = 1  # ICSSHARINGTYPE_PRIVATE = adapter facing the device

$mgr = New-Object -ComObject HNetCfg.HNetShare
$pubConn = $null
$privConn = $null
foreach ($conn in @($mgr.EnumEveryConnection)) {
    $props = $mgr.NetConnectionProps.Invoke($conn)
    if ($props.Name -eq $pub.Name)   { $pubConn  = $conn }
    if ($props.Name -eq $priv.Name)  { $privConn = $conn }
}
if (-not $pubConn)  { Write-Error "Public adapter '$($pub.Name)' not found via COM"; exit 1 }
if (-not $privConn) { Write-Error "Private adapter '$($priv.Name)' not found via COM"; exit 1 }

try {
    Enable-IcsPair -mgr $mgr -pubConn $pubConn -privConn $privConn -pubName $pub.Name -privName $priv.Name
    Write-Host ("ICS active: '" + $pub.Name + "' public -> '" + $priv.Name + "' private (192.168.137.1)") -ForegroundColor Green
} catch {
    Write-Warning ("First attempt failed (" + $_.Exception.Message + ") - retrying in 5 seconds...")
    Start-Sleep -Seconds 5
    try {
        Enable-IcsPair -mgr $mgr -pubConn $pubConn -privConn $privConn -pubName $pub.Name -privName $priv.Name
        Write-Host ("ICS active (2nd attempt): '" + $pub.Name + "' public -> '" + $priv.Name + "' private (192.168.137.1)") -ForegroundColor Green
    } catch {
        Write-Error ("Error enabling ICS: " + $_.Exception.Message)
        Invoke-IcsRollback -Reason "ICS activation failed"
        exit 1
    }
}

# 7) Wait for the device port to take 192.168.137.1 (confirms ICS is operational)
Write-Host "Waiting for the device port to take 192.168.137.1..."
$icsUp = $false
for ($i = 0; $i -lt 30 -and -not $icsUp; $i++) {
    $a = Get-NetIPAddress -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq "192.168.137.1" }
    if ($a) { $icsUp = $true } else { Start-Sleep -Seconds 1 }
}
if (-not $icsUp) {
    Invoke-IcsRollback -Reason "ICS did not configure 192.168.137.1 on the device port"
    exit 1
}
Write-Host "192.168.137.1 is active on the device port." -ForegroundColor Green

# 8) Post-check: the host MUST still have internet, otherwise auto-rollback
if ($hadInternet) {
    Write-Host "Verifying that the host still has internet..."
    if (-not (Test-HostInternet)) {
        Invoke-IcsRollback -Reason "the host lost internet after enabling ICS"
        exit 1
    }
    Write-Host "Host still online. No damage to the connection." -ForegroundColor Green
}

# 9) Discovery: find the device on the ICS subnet
#    (the ICS DHCP server can take a minute to start serving after the service restart)
Write-Host "`nLooking for the device on 192.168.137.x (be patient, DHCP can take a minute)..."
$dev = $null
$deadline = (Get-Date).AddSeconds($DiscoveryTimeoutSec)
while (-not $dev -and (Get-Date) -lt $deadline) {
    $dev = Find-DeviceIp -PortIfIndex $priv.ifIndex -StaticIp $StaticIp
    if (-not $dev) { Write-Host "." -NoNewline; Start-Sleep -Seconds 3 }
}
Write-Host ""

# 10) SSH
if ($dev) {
    Write-Host ("Device found at IP: " + $dev) -ForegroundColor Green
    $pingOk = $false
    try { $pingOk = [bool](Test-Connection $dev -Count 2 -Quiet -ErrorAction SilentlyContinue) } catch { }
    if ($pingOk) { Write-Host "Ping OK." -ForegroundColor Green }
    else         { Write-Host "Ping failed (maybe ICMP is blocked) - trying SSH anyway." -ForegroundColor Yellow }

    $sshReady = $false
    for ($k = 0; $k -lt 10 -and -not $sshReady; $k++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($dev, 22, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) { $tcp.EndConnect($iar); $sshReady = $true }
            $tcp.Close()
        } catch { }
        if (-not $sshReady) { Start-Sleep -Seconds 2 }
    }

    if ($sshReady) {
        Write-Host ("`nConnecting via SSH to " + $SshUser + "@" + $dev) -ForegroundColor Cyan
        ssh $SshUser@$dev
        Write-Host "`nSSH session ended. To disable the internet sharing:" -ForegroundColor Yellow
        Write-Host "  .\pi-easy-connect.ps1 -Undo" -ForegroundColor White
    } else {
        Write-Host ("SSH not reachable on " + $dev + ":22 - try manually.") -ForegroundColor Yellow
    }
} else {
    # 11) Final diagnostics
    Write-Host "`nDevice not found within the timeout." -ForegroundColor Red
    Write-Host "Device port state:" -ForegroundColor Yellow
    Get-NetIPAddress -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table IPAddress, PrefixLength -AutoSize | Out-String
    Write-Host "ARP table on 192.168.137.x:" -ForegroundColor Yellow
    arp -a | Select-String "192.168.137."
    Write-Host "Suggestions: cable connected? device powered on? DHCP enabled on the device?" -ForegroundColor Yellow
    Write-Host "ICS stays active: the device already has internet. To disable it: .\pi-easy-connect.ps1 -Undo" -ForegroundColor White
}
