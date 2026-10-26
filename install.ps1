# ====================================================================
# Automated Installer: Secure Remote Access Client (wstunnel + WireGuard)
# Repository: https://github.com/goodbrat-lab/home-access-client
# ====================================================================

# 1. Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] This installer MUST be executed with Administrator privileges." -ForegroundColor Red
    Write-Host "Please right-click Start -> 'Terminal (Administrator)' or 'PowerShell (Run as administrator)' and re-run." -ForegroundColor Yellow
    exit 1
}

# 2. Proxy Setup for current session
$proxyUrl = "http://10.26.254.42:3128"
$env:HTTP_PROXY = $proxyUrl
$env:HTTPS_PROXY = $proxyUrl
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($proxyUrl, $true)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls12,Tls13'

Write-Host "=== Setting up Secure Remote Access Client ===" -ForegroundColor Cyan

# 3. Target Directory
$targetDir = "$env:USERPROFILE\wstunnel"
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

# 4. Download Files from GitHub Release (with raw fallback)
$releaseBase = "https://github.com/goodbrat-lab/home-access-client/releases/download/v1.0.0"
$rawBase = "https://raw.githubusercontent.com/goodbrat-lab/home-access-client/main"

function Download-Asset {
    param([string]$FileName, [string]$OutPath)
    Write-Host "[*] Downloading $FileName..." -NoNewline
    $success = $false
    foreach ($url in @("$releaseBase/$FileName", "$rawBase/$FileName")) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $OutPath -Proxy $proxyUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $success = $true
            break
        } catch {}
    }
    if ($success) {
        Write-Host " OK" -ForegroundColor Green
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        throw "Could not download $FileName through proxy $proxyUrl."
    }
}

Download-Asset -FileName "wstunnel.exe" -OutPath "$targetDir\wstunnel.exe"
Download-Asset -FileName "start-wstunnel.bat" -OutPath "$targetDir\start-wstunnel.bat"
Download-Asset -FileName "config.enc" -OutPath "$targetDir\config.enc"
Download-Asset -FileName "config.sha256" -OutPath "$targetDir\config.sha256"

# 5. Integrity Check (SHA-256 of config.enc)
Write-Host "[*] Verifying config.enc integrity..." -NoNewline
$expectedHash = (Get-Content "$targetDir\config.sha256").Trim().ToLower()
$sha = [System.Security.Cryptography.SHA256]::Create()
$actualHashBytes = $sha.ComputeHash([System.IO.File]::ReadAllBytes("$targetDir\config.enc"))
$actualHash = [System.BitConverter]::ToString($actualHashBytes).Replace('-', '').ToLower()

if ($expectedHash -ne $actualHash) {
    Write-Host " INTEGRITY ERROR" -ForegroundColor Red
    Write-Error "SHA-256 mismatch for config.enc! Downloaded: $actualHash, Expected: $expectedHash"
    exit 1
}
Write-Host " OK (SHA-256 verified)" -ForegroundColor Green

# 6. Install WireGuard for Windows if not present
$wgExe = "C:\Program Files\WireGuard\wireguard.exe"
if (-not (Test-Path $wgExe)) {
    Write-Host "[*] WireGuard is not installed. Installing WireGuard for Windows..." -ForegroundColor Yellow
    $installed = $false
    
    # Try winget first
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            Write-Host "[*] Trying winget installation..."
            winget install --id WireGuard.WireGuard --silent --accept-package-agreements --accept-source-agreements --proxy $proxyUrl 2>&1 | Out-Null
            if (Test-Path $wgExe) { $installed = $true }
        } catch {}
    }
    
    # Fallback to direct installer
    if (-not $installed) {
        Write-Host "[*] Downloading official WireGuard installer..."
        $installerPath = "$env:TEMP\wireguard-installer.exe"
        Invoke-WebRequest -Uri "https://download.wireguard.com/windows-client/wireguard-installer.exe" -OutFile $installerPath -Proxy $proxyUrl -UseBasicParsing
        Write-Host "[*] Running WireGuard installer (please confirm UAC if prompted)..."
        $proc = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
        Start-Sleep -Seconds 3
        Remove-Item -Force $installerPath -ErrorAction SilentlyContinue
    }
    
    if (-not (Test-Path $wgExe)) {
        Write-Host "[ERROR] WireGuard installation failed or pending UAC approval. Please install WireGuard from https://www.wireguard.com/install/ manually and re-run this script." -ForegroundColor Red
        exit 1
    }
    Write-Host "[*] WireGuard installed successfully." -ForegroundColor Green
} else {
    Write-Host "[*] WireGuard for Windows already installed: $wgExe" -ForegroundColor Green
}

# 7. Decrypt config.enc using $env:WG_PASS
$password = $env:WG_PASS
if ([string]::IsNullOrWhiteSpace($password)) {
    Write-Host "[ERROR] Environment variable WG_PASS is missing or empty! Decryption cannot proceed." -ForegroundColor Red
    exit 1
}

Write-Host "[*] Decrypting WireGuard configuration..." -NoNewline
try {
    $data = [System.IO.File]::ReadAllBytes("$targetDir\config.enc")
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $mac = New-Object byte[] 32
    $cipherBytes = New-Object byte[] ($data.Length - 64)

    [System.Buffer]::BlockCopy($data, 0, $salt, 0, 16)
    [System.Buffer]::BlockCopy($data, 16, $iv, 0, 16)
    [System.Buffer]::BlockCopy($data, 32, $mac, 0, 32)
    [System.Buffer]::BlockCopy($data, 64, $cipherBytes, 0, $cipherBytes.Length)

    # Derive keys
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($password, $salt, 100000)
    $derived = $kdf.GetBytes(64)
    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    [System.Buffer]::BlockCopy($derived, 0, $encKey, 0, 32)
    [System.Buffer]::BlockCopy($derived, 32, $macKey, 0, 32)

    # Verify HMAC
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($macKey)
    $payload = [System.IO.MemoryStream]::new()
    $payload.Write($salt, 0, 16)
    $payload.Write($iv, 0, 16)
    $payload.Write($cipherBytes, 0, $cipherBytes.Length)
    $calcMac = $hmac.ComputeHash($payload.ToArray())

    $match = $true
    for ($i = 0; $i -lt 32; $i++) {
        if ($calcMac[$i] -ne $mac[$i]) { $match = $false }
    }
    if (-not $match) {
        throw "Invalid password or corrupted configuration file."
    }

    # Decrypt AES-256-CBC
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $encKey
    $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    $ms = [System.IO.MemoryStream]::new($cipherBytes)
    $cs = [System.Security.Cryptography.CryptoStream]::new($ms, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
    $reader = [System.IO.StreamReader]::new($cs, [System.Text.Encoding]::UTF8)
    $decryptedText = $reader.ReadToEnd()
    $cs.Close()
    $ms.Close()

    $confPath = "$targetDir\wireguard-client.conf"
    [System.IO.File]::WriteAllText($confPath, $decryptedText, [System.Text.Encoding]::UTF8)
    
    # Restrict permissions with icacls (current user only)
    icacls $confPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    Write-Host " OK" -ForegroundColor Green
} catch {
    Write-Host " FAILED" -ForegroundColor Red
    Write-Error "Decryption failed: $_"
    exit 1
} finally {
    Remove-Item Env:\WG_PASS -ErrorAction SilentlyContinue
}

# 8. Import / Activate WireGuard Tunnel
$tunnelName = "wireguard-client"
Write-Host "[*] Configuring WireGuard tunnel service '$tunnelName'..."
# Idempotent: uninstall existing tunnel service if already present
$existingService = Get-Service -Name "WireGuardTunnel`$$tunnelName" -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "[*] Reinstalling existing tunnel service..."
    & $wgExe /uninstalltunnelservice $tunnelName 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

& $wgExe /installtunnelservice "$targetDir\wireguard-client.conf"
Start-Sleep -Seconds 2

# 9. Start wstunnel client in background
Write-Host "[*] Starting wstunnel client in background..."
taskkill /IM wstunnel.exe /F 2>&1 | Out-Null
Start-Sleep -Seconds 1

Start-Process -WindowStyle Hidden -FilePath "$targetDir\wstunnel.exe" -ArgumentList @(
    "client",
    "-L", "udp://51820:localhost:51820?timeout_sec=0",
    "-p", $proxyUrl,
    "wss://home.guseynovia.ru:443"
)

Write-Host "[*] Waiting 5 seconds for tunnel negotiation..."
Start-Sleep -Seconds 5

# 10. Verification of processes and services
$wstunnelProc = Get-Process wstunnel -ErrorAction SilentlyContinue
$wgService = Get-Service -Name "WireGuardTunnel`$$tunnelName" -ErrorAction SilentlyContinue

if (-not $wstunnelProc) {
    Write-Host "[WARNING] wstunnel.exe process is not running. It might have exited due to proxy or TLS issues." -ForegroundColor Yellow
}
if (-not $wgService -or $wgService.Status -ne 'Running') {
    Write-Host "[WARNING] WireGuard tunnel service is not in 'Running' state." -ForegroundColor Yellow
}

# 11. Connectivity check
Write-Host "[*] Testing connectivity to home infrastructure..." -ForegroundColor Cyan
$pingServer = Test-Connection -ComputerName 10.10.10.1 -Count 3 -Quiet
$pingMiniPC = Test-Connection -ComputerName 192.168.1.229 -Count 3 -Quiet

if ($pingServer -and $pingMiniPC) {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "                CONNECTION OK                            " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "WireGuard tunnel is active and routing successfully!" -ForegroundColor Green
    Write-Host "- WireGuard Server (10.10.10.1): REACHABLE" -ForegroundColor Green
    Write-Host "- Mini-PC LAN (192.168.1.229):   REACHABLE" -ForegroundColor Green
    Write-Host ""
    Write-Host "Files installed at: $targetDir" -ForegroundColor Gray
    Write-Host "To stop the tunnel later, run:" -ForegroundColor Gray
    Write-Host "  taskkill /IM wstunnel.exe /F" -ForegroundColor White
    Write-Host "  & 'C:\Program Files\WireGuard\wireguard.exe' /uninstalltunnelservice wireguard-client" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "              CONNECTION DIAGNOSTICS                      " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "Ping 10.10.10.1:    $(if ($pingServer) { 'OK' } else { 'FAIL' })" -ForegroundColor $(if ($pingServer) { 'Green' } else { 'Red' })
    Write-Host "Ping 192.168.1.229: $(if ($pingMiniPC) { 'OK' } else { 'FAIL' })" -ForegroundColor $(if ($pingMiniPC) { 'Green' } else { 'Red' })
    Write-Host ""
    Write-Host "Troubleshooting steps:" -ForegroundColor Cyan
    Write-Host "1. Check wstunnel output in visible window:"
    Write-Host "   & '$targetDir\start-wstunnel.bat'"
    Write-Host "2. If 'certificate verify failed', edit start-wstunnel.bat and add: --tls-verify-certificate=false"
    Write-Host "3. Check WireGuard log:"
    Write-Host "   & '$wgExe' /dumplog"
    Write-Host "4. Check proxy CONNECT directly:"
    Write-Host "   curl.exe -x $proxyUrl -I https://home.guseynovia.ru"
}