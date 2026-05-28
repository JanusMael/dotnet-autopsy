# chainguard/build.ps1 — PowerShell equivalent of chainguard/build.sh.
# Builds the Chainguard variant of dotnet-autopsy-base, optionally followed
# by a per-case sibling image via the root build.ps1.
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('','sos','trace','gcdump')]
    [string]$Sibling = '',
    [string]$DumpArch = 'amd64',
    [string[]]$BuildArgs = @()
)
$ErrorActionPreference = 'Stop'
$Dir  = $PSScriptRoot
$Root = (Resolve-Path (Join-Path $Dir '..')).Path

Write-Host "Building Chainguard dotnet-autopsy-base (linux/$DumpArch)..." -ForegroundColor Cyan
docker build `
    --platform "linux/$DumpArch" `
    -f (Join-Path $Dir 'base.dockerfile') `
    -t dotnet-autopsy-base `
    --build-arg "DUMP_ARCH=$DumpArch" `
    @BuildArgs `
    $Root
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }

if ($Sibling) {
    Write-Host "`nBuilding per-image sibling on top of Chainguard base..." -ForegroundColor Cyan
    & (Join-Path $Root 'build.ps1') $Sibling -DumpArch $DumpArch -BuildArgs $BuildArgs
}

Write-Host "`nChainguard base ready: dotnet-autopsy-base" -ForegroundColor Green
