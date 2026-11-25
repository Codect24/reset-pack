# thermal-log.ps1 — 1 ligne CSV par appel (tâche ResetPack-ThermalLog : toutes les 5 min, 1re semaine).
# GPU via nvidia-smi ; CPU via LibreHardwareMonitor s'il tourne (WMI root\LibreHardwareMonitor), sinon vide.
# Alerte (alerts.log) si GPU >= -GpuAlertC ou CPU >= -CpuAlertC. Lecture seule, ne modifie rien d'autre.
param([int]$GpuAlertC = 83, [int]$CpuAlertC = 95)
$dir = Join-Path $env:LOCALAPPDATA 'ResetPack\thermal'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$csv = Join-Path $dir ("thermal-{0:yyyyMMdd}.csv" -f (Get-Date))
if (-not (Test-Path $csv)) { 'time,gpu_c,gpu_w,gpu_util,gpu_fan,vram_mb,cpu_c' | Set-Content $csv -Encoding ASCII }

$g = @('', '', '', '', '')
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $line = nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,fan.speed,memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($line) { $g = @($line -split ',\s*') }
}
$cpu = ''
try {
    $s = Get-CimInstance -Namespace 'root\LibreHardwareMonitor' -ClassName Sensor -ErrorAction Stop |
        Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU Package|Core \(Tctl|Core Max' } |
        Sort-Object Value -Descending | Select-Object -First 1
    if ($s) { $cpu = [math]::Round($s.Value, 0) }
} catch { $cpu = '' }   # LibreHardwareMonitor non lancé : pas de température CPU

$now = Get-Date -Format 's'
Add-Content $csv -Value ("{0},{1},{2},{3},{4},{5},{6}" -f $now, $g[0], $g[1], $g[2], $g[3], $g[4], $cpu) -Encoding ASCII
$alerts = @()
if ("$($g[0])" -match '^\d+$' -and [int]$g[0] -ge $GpuAlertC) { $alerts += "GPU $($g[0]) C" }
if ("$cpu" -match '^\d+$' -and [int]$cpu -ge $CpuAlertC) { $alerts += "CPU $cpu C" }
if ($alerts) { Add-Content (Join-Path $dir 'alerts.log') -Value "$now  $($alerts -join ' | ')" -Encoding UTF8 }
