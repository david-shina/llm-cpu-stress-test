<#
.SYNOPSIS
    Thermal governor. Auto-halts the llm-stress container if CPU package temp
    reaches HALT_TEMP_C (default 83). Warns in the log at WARN_TEMP_C (default 80).
.DESCRIPTION
    Tails docker/out/thermal.csv (written every 1s by collect_thermal.ps1). If any
    row reports a temp >= HALT_TEMP_C, immediately runs `docker stop llm-stress`
    and writes docker/out/halt_event.csv with the offending row(s).
    This script runs on the host so the container load cannot starve it.
    Writes a debug log to docker/out/watch.log so its actions are observable
    even when invoked as a background Start-Job.
.NOTES
    The 85C disqual cap is the hard limit; 83C halt leaves a 2C safety margin.
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "out"),
    [string]$Container = "llm-stress",
    [double]$WarnTempC = 80,
    [double]$HaltTempC = 83
)
$ErrorActionPreference = "Continue"

$csv      = Join-Path $OutDir "thermal.csv"
$haltFile = Join-Path $OutDir "halt_event.csv"
$stopFile = Join-Path $OutDir "STOP.collect"
$logFile  = Join-Path $OutDir "watch.log"

function Log {
    param([string]$Msg)
    $line = "{0:O} {1}" -f (Get-Date), $Msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding ascii
    Write-Host $line
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
"watch_and_halt: starting; OutDir=$OutDir; csv=$csv; warn=$WarnTempC; halt=$HaltTempC; container=$Container" | Out-File -FilePath $logFile -Encoding ascii -Force

if (-not (Test-Path -LiteralPath $csv)) {
    Log "watch_and_halt: thermal.csv not found. Waiting up to 20s for collector to create it..."
    $waited = 0
    while (-not (Test-Path -LiteralPath $csv) -and $waited -lt 20) { Start-Sleep -Milliseconds 500; $waited += 0.5 }
    if (-not (Test-Path -LiteralPath $csv)) { Log "watch_and_halt: thermal.csv still absent. Exiting."; exit 1 }
}

Log "watch_and_halt: monitoring."

$halted = $false
$warned = $false
$lastPos = 0
$sampleSeen = 0

while (-not (Test-Path -LiteralPath $stopFile)) {
    if (-not (Test-Path -LiteralPath $csv)) { Start-Sleep -Milliseconds 700; continue }

    try {
        $fs = [System.IO.File]::Open($csv, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($lastPos -gt $fs.Length) { $lastPos = 0 }
        $fs.Seek($lastPos, [System.IO.SeekOrigin]::Begin) | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $chunk = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
    } catch {
        Start-Sleep -Milliseconds 700; continue
    }

    if ([string]::IsNullOrEmpty($chunk)) { Start-Sleep -Milliseconds 700; continue }

    $lastPos += $chunk.Length
    # Split on LF (collector writes ASCII; CRLF becomes "...\r" at end of last field, harmless for $parts[1]).
    $lines = $chunk -split "`n"
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split ","
        if ($parts.Count -lt 2) { continue }
        $tempStr = $parts[1].Trim()
        # Strip any trailing \r (from CRLF on Windows) defensively.
        $tempStr = $tempStr -replace "`r$", ""
        if (-not ($tempStr -match '^[-+]?[0-9]*\.?[0-9]+$')) { continue }
        $temp = [double]$tempStr
        $sampleSeen++
        if ($sampleSeen -le 3) { Log ("watch_and_halt: first samples - temp=" + ("{0:F1}" -f $temp) + " C") }

        if (-not $warned -and $temp -ge $WarnTempC -and $temp -lt $HaltTempC) {
            Log ("watch_and_halt: WARN temp=" + ("{0:F1}" -f $temp) + " C >= $WarnTempC")
            $warned = $true
        }
        if ($temp -lt $WarnTempC) { $warned = $false }

        if ($temp -ge $HaltTempC -and -not $halted) {
            Log ("watch_and_halt: HALT temp=" + ("{0:F1}" -f $temp) + " C >= $HaltTempC - stopping container '$Container'")
            $sensorName = if ($parts.Count -ge 3) { $parts[2].Trim() -replace "`r$","" } else { "" }
            $hdr = "timestamp_iso,temp_c,sensor_name,halted_at_iso"
            $haltRow = "{0},{1:F1},{2},{3:O}" -f $parts[0].Trim(), $temp, $sensorName, (Get-Date)
            "$hdr`n$haltRow" | Out-File -FilePath $haltFile -Encoding ascii -Force
            Log "watch_and_halt: halt_event.csv written: $haltRow"
            try { docker stop -t 0 $Container 2>&1 | Out-Null } catch { Log "watch_and_halt: docker stop threw: $_" }
            $halted = $true
            Log "watch_and_halt: container stop issued. Test FAILED."
            exit 2
        }
    }
    Start-Sleep -Milliseconds 700
}

Log "watch_and_halt: stop signal received. halted=$halted"
if ($halted) { exit 2 } else { exit 0 }