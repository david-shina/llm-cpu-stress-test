<#
.SYNOPSIS
    Reset script: stops and removes the llm-stress container plus any collector
    artifacts in docker/out. Safe to call any time, even when previous run is idle.
.EXAMPLE
    .\clean.ps1
#>
[CmdletBinding()]
$ErrorActionPreference = "Continue"

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $here "out"

Write-Host "Stopping and removing llm-stress container (if any) ..." -ForegroundColor Cyan
docker rm -f llm-stress 2>&1 | Out-Null

Write-Host "Removing STOP and halt artifacts ..." -ForegroundColor Cyan
New-Item -ItemType File -Path (Join-Path $outDir "STOP.collect") -Force | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item -LiteralPath (Join-Path $outDir "STOP.collect") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "Done." -ForegroundColor Green