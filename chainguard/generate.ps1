# chainguard/generate.ps1 — PowerShell equivalent of chainguard/generate.sh.
#
# Generates a Chainguard/Wolfi-flavored variant of common/base.dockerfile
# with the few build-time tweaks the README's "Adapting the base image"
# section calls out (SDK image, apt→apk, USER root). The transformation
# rules are identical to the bash script — see generate.sh for the full
# design notes. The PowerShell version exists so Windows developers (no
# WSL required) can run the same workflow.
#
# Single output: chainguard/base.dockerfile. The build wrappers and the
# README in chainguard/ are hand-edited repo files this script does not
# touch — edit them freely; -Force only affects base.dockerfile.
#
# Usage:
#   .\chainguard\generate.ps1                                # interactive
#   .\chainguard\generate.ps1 -NonInteractive                # all defaults
#   .\chainguard\generate.ps1 -SdkImage 'cgr.dev/chainguard/dotnet-sdk:latest-dev'
#   .\chainguard\generate.ps1 -SdkImage <ref> -NonInteractive -Force

[CmdletBinding()]
param(
    [string]$SdkImage = '',
    [switch]$NonInteractive,
    [switch]$Force,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'

$Dir  = $PSScriptRoot
$Root = (Resolve-Path (Join-Path $Dir '..')).Path
$Src  = Join-Path $Root 'common\base.dockerfile'
$Out  = Join-Path $Dir 'base.dockerfile'

$SdkDefault = 'cgr.dev/chainguard/dotnet-sdk:latest-dev'

if ($Help) {
    @"
Generate a Chainguard/Wolfi variant of common/base.dockerfile.

Usage: .\chainguard\generate.ps1 [parameters]

Parameters:
  -SdkImage <ref>    Chainguard SDK image to use
                     (default: $SdkDefault).
                     Pin by digest with image@sha256:<hex>.
  -NonInteractive    Use defaults (no prompts). Required for CI.
  -Force             Overwrite existing outputs without prompting.
  -Help              Show this help.
"@ | Write-Host
    return
}

# ── Interactive prompts ───────────────────────────────────────────────────────
if (-not $NonInteractive -and -not $SdkImage) {
    $ans = Read-Host "Chainguard .NET SDK image [$SdkDefault]"
    if ($ans) { $SdkImage = $ans }
}
if (-not $SdkImage) { $SdkImage = $SdkDefault }

if ((Test-Path -LiteralPath $Out) -and -not $Force -and -not $NonInteractive) {
    $ans = Read-Host "$Out exists. Overwrite? [y/N]"
    if ($ans -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "Aborted (no files written)."
        return
    }
}

Write-Host ""
Write-Host "Generating Chainguard adaptation..."
Write-Host "  source : $Src"
Write-Host "  output : $Out"
Write-Host "  sdk    : $SdkImage"
Write-Host ""

if (-not (Test-Path -LiteralPath $Src)) {
    throw "Source not found: $Src"
}

# ── Transform base.dockerfile ─────────────────────────────────────────────────
# Same three transformations as the bash version (see generate.sh comments
# for the full rationale).
$lines = Get-Content -LiteralPath $Src
$out = [System.Collections.Generic.List[string]]::new()
$inApt = $false

$aptPackages = @(
    'lldb','gdb','elfutils','binutils',
    'file','less','nano','procps','btop',
    'curl','ca-certificates',
    'tar','gzip','unzip'
)

foreach ($line in $lines) {
    # (1) Both DOTNET_SDK_IMAGE ARG defaults → Chainguard
    if ($line -match '^ARG DOTNET_SDK_IMAGE=') {
        $out.Add("ARG DOTNET_SDK_IMAGE=$SdkImage")
        continue
    }

    # (2) After FROM, insert USER root + a marker block
    if ($line -eq 'FROM --platform=linux/${DUMP_ARCH} ${DOTNET_SDK_IMAGE} AS base') {
        $out.Add($line)
        $out.Add('')
        $out.Add('# -- Chainguard adaptation ----------------------------------------------------')
        $out.Add('# Chainguard images run as nonroot by default. apk + the global dotnet')
        $out.Add('# tool installs that follow need root, so switch explicitly. If you want')
        $out.Add('# the final image to drop to nonroot, add a USER nonroot near the end')
        $out.Add('# (after all installs) and write the PATH/MOTD snippet from the canonical')
        $out.Add('# base to /home/nonroot/.bashrc as well as /root/.bashrc.')
        $out.Add('USER root')
        continue
    }

    # (2b) After ENV DOTNET_EnableEventLog=1, insert DOTNET_ROLL_FORWARD=Major.
    # The pinned dotnet-monitor 9.0.0 targets Microsoft.NETCore.App 9.0.0-rc.2
    # which is NOT shipped by Chainguard SDK images (.NET 10 only). The
    # Microsoft SDK image keeps 9.x and 10.x runtimes side-by-side so this is
    # never needed there; on Chainguard the host has only 10.x.
    if ($line -eq 'ENV DOTNET_EnableEventLog=1') {
        $out.Add($line)
        $out.Add('')
        $out.Add('# Chainguard adaptation: roll forward across major framework versions so')
        $out.Add('# dotnet-monitor 9.0.0 (which targets Microsoft.NETCore.App 9.0.0-rc) can')
        $out.Add("# run on the .NET 10 runtime that Chainguard ships. Microsoft's SDK")
        $out.Add('# image keeps 9.x and 10.x runtimes side-by-side so this is never needed')
        $out.Add("# there; Chainguard's image is leaner and has 10.x only.")
        $out.Add('ENV DOTNET_ROLL_FORWARD=Major')
        continue
    }

    # (3a) Start of the apt-get block — emit the apk replacement, then swallow
    # The Chainguard curated feed omits lldb/btop; pull in the public Wolfi
    # feed (same key chain). lldb is REQUIRED — discover it dynamically and
    # fail hard with diagnostic output if no candidate is found.
    if ($line -match '^RUN apt-get update \\$') {
        $inApt = $true
        $out.Add('# Chainguard adaptation: apt-get replaced with apk add.')
        $out.Add("# Chainguard's curated feed omits some diagnostic tools (lldb, btop).")
        $out.Add('# Pull in the public Wolfi feed for those — Chainguard images are built')
        $out.Add('# on top of Wolfi and share the same package keychain.')
        $out.Add('#')
        $out.Add('# lldb: empirically NOT in the free Chainguard or Wolfi feeds (as of')
        $out.Add('# the 2026 builds we verified — `apk search lldb` returns only rust')
        $out.Add('# packages that mention LLDB in their description). It is available')
        $out.Add("# in Chainguard's paid Production tier; if you have that, append")
        $out.Add('# apk.cgr.dev/extra-packages to /etc/apk/repositories before this RUN.')
        $out.Add('#')
        $out.Add('# The block below still attempts dynamic discovery — if Wolfi ever')
        $out.Add('# adds an lldb package, it gets picked up automatically. If not, we')
        $out.Add('# log a clear INFO and continue: delve-lldb is optional; delve')
        $out.Add('# (dotnet-dump) is the documented primary interactive path.')
        $out.Add('#')
        $out.Add('# tar is typically pre-installed in the Chainguard SDK image and is not')
        $out.Add('# in either curated feed by that exact name; verify-then-install.')
        $out.Add('RUN wget -qO /etc/apk/keys/wolfi-signing.rsa.pub \')
        $out.Add('        https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \')
        $out.Add("    && echo 'https://packages.wolfi.dev/os' >> /etc/apk/repositories \")
        $out.Add('    && apk update \')
        $out.Add('    && apk add --no-cache \')
        # Drop lldb + tar from the main list — handled specially below.
        $corePackages = $aptPackages | Where-Object { $_ -notin @('lldb','tar') }
        for ($i = 0; $i -lt $corePackages.Count; $i++) {
            $out.Add("        $($corePackages[$i]) \")
        }
        $out.Add('    && apk update \')
        $out.Add("    && LLDB_PKG=`$(apk search lldb 2>/dev/null \")
        $out.Add("            | sed -E 's/-[^-]+-r[0-9]+`$//' \")
        $out.Add('            | sort -uV \')
        $out.Add("            | grep -E '^lldb(-[0-9]+|-default)?`$' \")
        $out.Add('            | tail -1) \')
        $out.Add('    && if [ -n "${LLDB_PKG}" ]; then \')
        $out.Add('           echo "Installing lldb package: ${LLDB_PKG}"; \')
        $out.Add('           apk add --no-cache "${LLDB_PKG}"; \')
        $out.Add('       else \')
        $out.Add("           echo 'INFO: no lldb in the configured apk feeds (Chainguard public + Wolfi os).'; \")
        $out.Add("           echo '      delve-lldb wrapper will be unavailable; delve (dotnet-dump) is unaffected.'; \")
        $out.Add("           echo '      For lldb on Chainguard, append apk.cgr.dev/extra-packages (paid tier).'; \")
        $out.Add('       fi \')
        $out.Add('    && (   command -v tar >/dev/null 2>&1 \')
        $out.Add('        || apk add --no-cache tar \')
        $out.Add("        || { echo 'ERROR: tar not available' >&2; exit 1; })")
        continue
    }

    # Toolchain-smoke adaptation: lldb may not have installed (the free
    # Chainguard / Wolfi feeds don't ship it). Guard the two `lldb`
    # invocations so the build doesn't fail when it's absent. delve-lldb is
    # optional; delve (dotnet-dump) is the primary path and unaffected.
    if ($line -eq '    && lldb --version \') {
        $out.Add('    && (command -v lldb >/dev/null 2>&1 && lldb --version \')
        $out.Add('         || echo "INFO: lldb absent (Chainguard free feed); delve-lldb wrapper unavailable") \')
        continue
    }
    if ($line -eq '        lldb --batch -o "plugin load ${SOS_PLUGIN}" -o "help sos" -o "quit" 2>&1 | head -10 \') {
        $out.Add('        (command -v lldb >/dev/null 2>&1 \')
        $out.Add('            && lldb --batch -o "plugin load ${SOS_PLUGIN}" -o "help sos" -o "quit" 2>&1 | head -10 \')
        $out.Add('            || echo "INFO: lldb absent — SOS plugin load check skipped") \')
        continue
    }

    # (3b) Skip the rest of the apt block
    if ($inApt) {
        if ($line -match '&& rm -rf /var/lib/apt/lists/\*$') {
            $inApt = $false
        }
        continue
    }

    $out.Add($line)
}

# Write base.dockerfile with LF endings (it's a Dockerfile — .gitattributes
# enforces LF on *.dockerfile but be explicit).
$joined = ($out -join "`n") + "`n"
[System.IO.File]::WriteAllText($Out, $joined, [System.Text.UTF8Encoding]::new($false))

# Note on scope: this generator only produces base.dockerfile from the
# canonical source. The thin build wrappers (chainguard/build.sh,
# chainguard/build.ps1) and the documentation (chainguard/README.md) are
# hand-written, committed alongside this script, and never touched by the
# generator. Keeps the mental model simple: one input, one output; the
# wrappers and docs are normal repo files you can edit freely without
# worrying about a regen wiping them.
Write-Host ""
Write-Host "Generated:"
Write-Host "  $Out"
Write-Host ""
Write-Host "Review the adaptation:"
Write-Host "  diff -u common/base.dockerfile chainguard/base.dockerfile"
Write-Host ""
Write-Host "Build:"
Write-Host "  .\chainguard\build.ps1            # base only"
Write-Host "  .\chainguard\build.ps1 sos        # base + sos per-case image"
