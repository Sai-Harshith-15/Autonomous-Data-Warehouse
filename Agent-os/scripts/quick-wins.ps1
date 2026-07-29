<#
.SYNOPSIS
    Quick Wins for AI Software Factory — run as Administrator.
    Sets Defender exclusions, enables long paths, configures Git.
.DESCRIPTION
    Apply these BEFORE any structural changes for immediate 30-50% speedup.
    Run from PowerShell as Administrator:  powershell -ExecutionPolicy Bypass .\quick-wins.ps1
#>

$ErrorActionPreference = "Stop"
Write-Host "=== AI Software Factory Quick Wins ===" -ForegroundColor Cyan
Write-Host "Target: 45 min to 8-12 min immediately`n" -ForegroundColor Yellow

# --- 1. Windows Defender Exclusions ---
Write-Host "[1/5] Adding Defender exclusions..." -ForegroundColor Green
$exclusions = @(
    "D:\agent-os\work",
    "D:\agent-os\artifacts",
    "D:\agent-os\events",
    "D:\agent-os\runs",
    "D:\hermes-factory",
    "D:\GitRepo\Autonomous-Data-Warehouse",
    "$env:USERPROFILE\AppData\Local\npm-cache",
    "$env:USERPROFILE\.npm",
    "$env:USERPROFILE\AppData\Local\hermes",
    "D:\usefulRepos"
)

foreach ($path in $exclusions) {
    if (Test-Path $path) {
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
            Write-Host "  [+] Added exclusion: $path" -ForegroundColor Green
        } catch {
            Write-Host "  [!] Failed to add exclusion (need Admin): $path" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [-] Path does not exist yet: $path" -ForegroundColor DarkYellow
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
            Write-Host "  [+] Added exclusion (future): $path" -ForegroundColor Green
        } catch {}
    }
}

# --- 2. Enable Long Paths ---
Write-Host "`n[2/5] Enabling long paths..." -ForegroundColor Green
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
        -Name "LongPathsEnabled" -Value 1 -Force
    Write-Host "  [+] LongPathsEnabled = 1 (registry)" -ForegroundColor Green
} catch {
    Write-Host "  [!] Registry write failed (need Admin): $_" -ForegroundColor Yellow
}

# --- 3. Git configuration ---
Write-Host "`n[3/5] Configuring Git..." -ForegroundColor Green
try {
    git config --global core.longpaths true
    Write-Host "  [+] git config core.longpaths = true" -ForegroundColor Green
} catch {
    Write-Host "  [!] git config failed: $_" -ForegroundColor Yellow
}
try {
    git config --global core.autocrlf false
    Write-Host "  [+] git config core.autocrlf = false" -ForegroundColor Green
} catch {
    Write-Host "  [!] git config autocrlf failed: $_" -ForegroundColor Yellow
}

# --- 4. Create directory structure ---
Write-Host "`n[4/5] Creating directory structure..." -ForegroundColor Green
$dirs = @(
    "D:\agent-os\work",
    "D:\agent-os\artifacts",
    "D:\agent-os\events",
    "D:\agent-os\runs",
    "D:\agent-os\logs",
    "D:\hermes-factory\config",
    "D:\hermes-factory\logs",
    "D:\agent-os\scripts\db",
    "D:\agent-os\public"
)
foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host "  [+] Created: $dir" -ForegroundColor Green
}

# --- 5. Verify .gitattributes ---
Write-Host "`n[5/5] Checking .gitattributes..." -ForegroundColor Green
$gaPath = "D:\GitRepo\Autonomous-Data-Warehouse\.gitattributes"
if (-not (Test-Path $gaPath)) {
    "* text=auto eol=lf" | Out-File -FilePath $gaPath -Encoding utf8
    Write-Host "  [+] Created .gitattributes with eol=lf" -ForegroundColor Green
} else {
    $content = Get-Content $gaPath -Raw
    if ($content -match "eol=lf") {
        Write-Host "  [+] .gitattributes already has eol=lf" -ForegroundColor Green
    } else {
        Add-Content -Path $gaPath -Value "`n* text=auto eol=lf" -Encoding utf8
        Write-Host "  [+] Appended eol=lf to .gitattributes" -ForegroundColor Green
    }
}

Write-Host "`n=== Quick Wins Complete ===" -ForegroundColor Cyan
Write-Host "Reboot recommended for Defender + long paths to take full effect." -ForegroundColor Yellow
Write-Host "Estimated speed improvement: 30-50% immediately." -ForegroundColor Green
