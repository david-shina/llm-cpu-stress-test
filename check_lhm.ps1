<#
.SYNOPSIS
    Pre-flight check: confirm LibreHardwareMonitor is running and its web API
    is reachable so collect_thermal.ps1 can read CPU package temperature.
.DESCRIPTION
    Hits the LHM /data.json endpoint (default http://localhost:8085; override
    with -ApiUrl). LibreHardwareMonitor exposes a NESTED tree:
        root
          Children[0]  (DAVID-PC)
            Children[i]  "12th Gen Intel Core i7-12700H"  HardwareId=/intelcpu/0
              Children[j]  "Temperatures"  (group node)
                Children[k]  "CPU Package"  Value=61.0
    Note: the SensorType field on individual sensor rows is empty in LHM's JSON;
    the sensor family is encoded in the IMMEDIATE parent's Text field
    ("Temperatures", "Powers", "Clocks", ...). We therefore locate the CPU
    node via HardwareId and walk to its Temperatures group.
    Prints one sample reading so the operator can sanity-check the value.
    Exits 0 on success, 1 on any failure. run_test.ps1 aborts if this non-zero.
.EXAMPLE
    .\check_lhm.ps1
    .\check_lhm.ps1 -ApiUrl "http://192.168.1.223:8085/data.json"
#>
[CmdletBinding()]
param(
    [string]$ApiUrl = "http://localhost:8085/data.json"
)
$ErrorActionPreference = "Stop"

Write-Host "LHM preflight: querying $ApiUrl ..." -ForegroundColor Cyan
try {
    $resp = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 5 -ErrorAction Stop
} catch {
    Write-Host "FAIL: cannot reach LibreHardwareMonitor API at $ApiUrl." -ForegroundColor Red
    Write-Host "Tip: open LHM, ensure Web Server is enabled, and confirm the URL matches (use a network IP if accessing across a host)." -ForegroundColor Yellow
    exit 1
}

function Find-CpuPackageTemp {
    param($Node)
    if (-not $Node) { return $null }

    # Match CPU node by HardwareId (preferred) or by Text containing "Intel"/"AMD"/"Ryzen" + "Core"/"EPYC".
    $isCpu = $false
    if ($Node.HardwareId -and $Node.HardwareId -match '/intelcpu/|/amdcpu/') { $isCpu = $true }
    elseif ($Node.Text -match 'Intel Core|AMD Ryzen|AMD EPYC|12th Gen|13th Gen|11th Gen|10th Gen') { $isCpu = $true }

    if ($isCpu -and $Node.Children) {
        $tempGroup = $null
        foreach ($c in $Node.Children) {
            if ($c.Text -and $c.Text -match '^Temperatures$') { $tempGroup = $c; break }
        }
        if ($tempGroup -and $tempGroup.Children) {
            # Intel: "CPU Package" | AMD: "Tctl/Tdie", "Tctl", "Tdie" | Generic: "CPU"
            # Use contains match so "Tctl/Tdie" is caught (AMD names it that way).
            foreach ($s in $tempGroup.Children) {
                if ($s.Text -and $s.Text -match 'CPU Package') { return $s }
            }
            foreach ($s in $tempGroup.Children) {
                if ($s.Text -and $s.Text -match 'Tctl') { return $s }
            }
            foreach ($s in $tempGroup.Children) {
                if ($s.Text -and $s.Text -match 'Tdie') { return $s }
            }
            foreach ($s in $tempGroup.Children) {
                if ($s.Text -and $s.Text -match 'Package') { return $s }
            }
        }
    }

    # Recurse into all Children.
    if ($Node.Children) {
        foreach ($child in $Node.Children) {
            $hit = Find-CpuPackageTemp -Node $child
            if ($hit) { return $hit }
        }
    }
    return $null
}

$pkg = Find-CpuPackageTemp -Node $resp

if (-not $pkg) {
    Write-Host "FAIL: API reachable but no CPU package temperature sensor found in the tree." -ForegroundColor Red
    Write-Host "Tip: open LHM, confirm 'CPU Package' (Intel) or 'Tctl'/'Tdie' (AMD Ryzen) is visible under the CPU's Temperatures group, then retry." -ForegroundColor Yellow
    exit 1
}

# LHM's Value field can be either a bare number ("61.0") or a string with a unit suffix ("72.0 °C").
# Extract the leading numeric portion defensively.
$raw = [string]$pkg.Value
$m = [regex]::Match($raw, '^[-+]?[0-9]*\.?[0-9]+')
if (-not $m.Success) {
    Write-Host "FAIL: CPU package sensor found but Value '$raw' is not numeric." -ForegroundColor Red
    exit 1
}
$tempVal = [double]$m.Value
Write-Host ("OK: CPU package temp sensor = '{0}' -> {1:F1} C" -f $pkg.Text, $tempVal) -ForegroundColor Green
if ($tempVal -lt 20 -or $tempVal -gt 110) {
    Write-Host "WARN: reading looks bogus ($tempVal C). Check LHM renders temperature correctly before relying on this." -ForegroundColor Yellow
} else {
    Write-Host "Reading is in a plausible range (20-110 C). Preflight PASSED." -ForegroundColor Green
}
Write-Host "LHM preflight PASSED." -ForegroundColor Green
exit 0