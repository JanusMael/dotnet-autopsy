# build.ps1 — build a dotnet-autopsy image (sos | trace | gcdump) on Windows.
# Canonical path: docker compose build  (works on all OSes identically).
# Thin wrapper for Windows users who prefer a direct docker build. Builds the
# shared base (dotnet-autopsy-base) first, then the per-image image FROM it.
#
# Usage:
#   .\build.ps1                                                   # sos (default)
#   .\build.ps1 -Image sos    -BuildArgs @("--build-arg","DUMP_FILE=myapp.dump")
#   .\build.ps1 -Image sos    -DumpArch arm64
#   .\build.ps1 -Image sos    -BuildArgs @("--build-arg","INNER_EXCEPTION_DEPTH=20")
#   .\build.ps1 -Image trace  -BuildArgs @("--build-arg","TRACE_FILE=mytrace.nettrace")
#   .\build.ps1 -Image gcdump -BuildArgs @("--build-arg","GCDUMP_FILE=myheap.gcdump")
#   .\build.ps1 -Image trace  -BuildArgs @("--build-arg","SMOKE_TEST=1")
#
# Note: DumpArch defaults to amd64. Apple Silicon Mac users (cross-compiling)
#       should leave it as amd64 for x64 production dumps.

param(
    [ValidateSet("sos","trace","gcdump")]
    [string]$Image    = "sos",
    [string]$DumpArch = "amd64",
    [string[]]$BuildArgs = @()
)

$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

switch ($Image) {
    "sos" {
        $ImageDockerfile = "$Dir\sos\dotnet-sos.dockerfile"
        $ImageTag        = "dotnet-autopsy-sos"
    }
    "trace" {
        $ImageDockerfile = "$Dir\trace\dotnet-trace.dockerfile"
        $ImageTag        = "dotnet-autopsy-trace"
    }
    "gcdump" {
        $ImageDockerfile = "$Dir\gcdump\dotnet-gcdump.dockerfile"
        $ImageTag        = "dotnet-autopsy-gcdump"
    }
}

Write-Host "Building dotnet-autopsy/$Image (platform: linux/$DumpArch)"
Write-Host "  Context : $Dir"
Write-Host "  Base    : $Dir\common\base.dockerfile      -> dotnet-autopsy-base"
Write-Host "  Image   : $ImageDockerfile -> $ImageTag"
Write-Host ""

$BaseArgs = @(
    "build",
    "--platform", "linux/$DumpArch",
    "-f", "$Dir\common\base.dockerfile",
    "-t", "dotnet-autopsy-base",
    "--build-arg", "DUMP_ARCH=$DumpArch",
    $Dir
)
& docker @BaseArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "base build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

$DockerArgs = @(
    "build",
    "--platform", "linux/$DumpArch",
    "-f", $ImageDockerfile,
    "-t", $ImageTag,
    "--build-arg", "DUMP_ARCH=$DumpArch"
) + $BuildArgs + @($Dir)

& docker @DockerArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "docker build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
