<#
.SYNOPSIS
    Install Hermes Factory as an NSSM Windows service for auto-restart and log rotation.
.DESCRIPTION
    Requires NSSM (Non-Sucking Service Manager). Download from https://nssm.cc/download
    Place nssm.exe somewhere in PATH (e.g., C:\Windows\System32\).
    
    Run as Administrator:
    powershell -ExecutionPolicy Bypass -File install-factory-service.ps1
#>

$ErrorActionPreference = "Stop"

$ServiceName = "HermesFactory"
$ServiceDisplay = "AI Software Factory Daemon"
$BashPath = "C:\Program Files\git\usr\bin\bash.exe"
$ScriptPath = "D:\GitRepo\Autonomous-Data-Warehouse\Agent-os\scripts\factory-daemon.sh"
$LogDir = "D:\hermes-factory\logs"

# Check NSSM
$nssm = Get-Command "nssm.exe" -ErrorAction SilentlyContinue
if (-not $nssm) {
    Write-Host "[!] NSSM not found in PATH. Download from https://nssm.cc/download" -ForegroundColor Red
    Write-Host "    Place nssm.exe in C:\Windows\System32\ and try again." -ForegroundColor Yellow
    exit 1
}

# Check if service already exists
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "[!] Service '$ServiceName' already exists. Removing..." -ForegroundColor Yellow
    & $nssm stop $ServiceName 2>$null
    & $nssm remove $ServiceName confirm 2>$null
    Start-Sleep -Seconds 2
}

# Create log directory
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

Write-Host "[+] Installing NSSM service: $ServiceName" -ForegroundColor Green

# Install
& $nssm install $ServiceName $BashPath "--login" "-i" $ScriptPath

# Configure
& $nssm set $ServiceName DisplayName $ServiceDisplay
& $nssm set $ServiceName Start SERVICE_AUTO_START
& $nssm set $ServiceName AppStdout "$LogDir\factory-stdout.log"
& $nssm set $ServiceName AppStderr "$LogDir\factory-stderr.log"
& $nssm set $ServiceName AppRotateFiles 1
& $nssm set $ServiceName AppRotateOnline 1
& $nssm set $ServiceName AppRotateSeconds 86400
& $nssm set $ServiceName AppRotateBytes 10485760
& $nssm set $ServiceName AppEnvironmentExtra "HARNESS_DB=D:\agent-os\harness.db POOL_CONFIG=D:\hermes-factory\config\resource-pool.yaml"

# Restart on crash
& $nssm set $ServiceName AppExit Default Exit
& $nssm set $ServiceName AppThrottle 5000

Write-Host "[+] Service '$ServiceName' installed." -ForegroundColor Green

# Start
Write-Host "[+] Starting service..." -ForegroundColor Green
& $nssm start $ServiceName

Start-Sleep -Seconds 3
$status = Get-Service -Name $ServiceName
if ($status.Status -eq "Running") {
    Write-Host "[+] Service is RUNNING" -ForegroundColor Green
} else {
    Write-Host "[!] Service status: $($status.Status)" -ForegroundColor Yellow
}

Write-Host "`nManage with:" -ForegroundColor Cyan
Write-Host "  nssm start $ServiceName"
Write-Host "  nssm stop $ServiceName"
Write-Host "  nssm status $ServiceName"
Write-Host "  nssm edit $ServiceName   (GUI config)"
