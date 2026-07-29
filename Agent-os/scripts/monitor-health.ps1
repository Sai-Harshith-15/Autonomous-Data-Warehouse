<#
.SYNOPSIS
    Health monitor for AI Software Factory.
    Polls dashboard /api/health every 60s, logs to health.log, alerts on anomalies.
.DESCRIPTION
    Run as a scheduled task: powershell -ExecutionPolicy Bypass -File monitor-health.ps1
    Or run manually in a terminal window.
#>

param(
    [int]$IntervalSeconds = 60,
    [string]$DashboardUrl = "http://127.0.0.1:8199",
    [string]$LogDir = "D:\agent-os\logs"
)

$HealthLog = Join-Path $LogDir "health.log"
$AlertLog = Join-Path $LogDir "alerts.log"

# Ensure log directory
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

Write-Host "[health-monitor] Starting — polling $DashboardUrl/api/health every ${IntervalSeconds}s"
Write-Host "[health-monitor] Log: $HealthLog"

# Write header if new file
if (-not (Test-Path $HealthLog)) {
    "timestamp|queue_depth|running|failed|avg_duration_ms|total_runs|total_events|status" | Out-File -FilePath $HealthLog -Encoding utf8
}

$previousFailedCount = 0
$previousQueueDepth = 0

while ($true) {
    $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    try {
        $response = Invoke-RestMethod -Uri "${DashboardUrl}/api/health" -TimeoutSec 10 -ErrorAction Stop
        
        $line = "$ts|$($response.queue_depth)|$($response.running_count)|$($response.failed_count)|$($response.avg_task_duration_ms)|$($response.total_runs)|$($response.total_events)|$($response.status)"
        $line | Out-File -FilePath $HealthLog -Encoding utf8 -Append
        
        # Check for anomalies
        $alerts = @()
        
        if ($response.queue_depth -gt 10) {
            $alerts += "Queue depth $($response.queue_depth) exceeds threshold 10"
        }
        
        if ($response.failed_count -gt ($previousFailedCount + 2) -and $previousFailedCount -gt 0) {
            $alerts += "Failed count spike: $($previousFailedCount) → $($response.failed_count)"
        }
        
        if ($response.status -ne "healthy") {
            $alerts += "Dashboard status: $($response.status)"
        }
        
        if ($alerts.Count -gt 0) {
            $alertMsg = "[$ts] ALERT: $($alerts -join ' | ')"
            Write-Host $alertMsg -ForegroundColor Red
            $alertMsg | Out-File -FilePath $AlertLog -Encoding utf8 -Append
        }
        
        # Log rotation: keep last 10000 lines
        $lineCount = (Get-Content $HealthLog -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($lineCount -gt 10000) {
            $keep = Get-Content $HealthLog -Tail 5000
            $keep | Set-Content $HealthLog -Encoding utf8
        }
        
        $previousFailedCount = $response.failed_count
        $previousQueueDepth = $response.queue_depth
        
    } catch {
        $errorMsg = "[$ts] ERROR: $_"
        Write-Host $errorMsg -ForegroundColor Yellow
        $errorMsg | Out-File -FilePath $AlertLog -Encoding utf8 -Append
    }
    
    Start-Sleep -Seconds $IntervalSeconds
}
