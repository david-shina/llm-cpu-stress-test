<#
.SYNOPSIS
    Build the llm-cpu-test Docker image.
.DESCRIPTION
    Wraps `docker build` so we pin the llama.cpp commit and use the canonical
    image tag used by run_test.ps1. Re-run this after editing the Dockerfile
    or after bumping LLAMA_COMMIT. Safe to invoke from docker/ or the repo root.
.EXAMPLE
    .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$LlamaCommit = "HEAD",
    [string]$Tag         = "llm-cpu-test:latest"
)

$ErrorActionPreference = "Stop"

# Resolve dockerfile path relative to this script so callers can run from anywhere.
$here         = Split-Path -Parent $MyInvocation.MyCommand.Path
$dockerfile   = Join-Path $here "Dockerfile"

if (-not (Test-Path -LiteralPath $dockerfile)) {
    throw "Dockerfile not found at $dockerfile"
}

Write-Host "Building image '$Tag' with LLAMA_COMMIT=$LlamaCommit ..." -ForegroundColor Cyan
# Docker writes progress to stderr; merge streams so PowerShell doesn't surface
# each progress line as a NativeCommandError under ErrorActionPreference=Stop.
$exit = & { docker build --build-arg "LLAMA_COMMIT=$LlamaCommit" -t $Tag -f $dockerfile $here 2>&1 | ForEach-Object { Write-Host $_ } ; $LASTEXITCODE }
if ($exit -ne 0) {
    throw "docker build failed (exit $exit)"
}
Write-Host "OK: image '$Tag' built." -ForegroundColor Green