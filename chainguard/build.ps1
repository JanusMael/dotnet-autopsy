# chainguard/build.ps1 — PowerShell equivalent of chainguard/build.sh.
# Builds the Chainguard variant of dotnet-autopsy-base, optionally followed
# by a per-case sibling image built directly on it. It deliberately does NOT
# call the root build.ps1, which rebuilds dotnet-autopsy-base from the
# canonical dockerfile and would silently replace the Chainguard base under
# the same tag.
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
    $images = @{
        sos    = @{ Dockerfile = Join-Path $Root 'sos/dotnet-sos.dockerfile';       Tag = 'dotnet-autopsy-sos' }
        trace  = @{ Dockerfile = Join-Path $Root 'trace/dotnet-trace.dockerfile';   Tag = 'dotnet-autopsy-trace' }
        gcdump = @{ Dockerfile = Join-Path $Root 'gcdump/dotnet-gcdump.dockerfile'; Tag = 'dotnet-autopsy-gcdump' }
    }
    $image = $images[$Sibling]
    Write-Host "`nBuilding $($image.Tag) on top of the Chainguard base..." -ForegroundColor Cyan
    docker build `
        --platform "linux/$DumpArch" `
        -f $image.Dockerfile `
        -t $image.Tag `
        --build-arg "DUMP_ARCH=$DumpArch" `
        @BuildArgs `
        $Root
    if ($LASTEXITCODE -ne 0) { throw "docker build of $($image.Tag) failed (exit $LASTEXITCODE)" }
    Write-Host "`nChainguard $Sibling image ready: $($image.Tag) (FROM the Chainguard dotnet-autopsy-base)" -ForegroundColor Green
}
else {
    Write-Host "`nChainguard base ready: dotnet-autopsy-base" -ForegroundColor Green
}
