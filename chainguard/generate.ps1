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
# Not $out: names ignore case, so it would overwrite $Out, the output path.
$outLines = [System.Collections.Generic.List[string]]::new()
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
        $outLines.Add("ARG DOTNET_SDK_IMAGE=$SdkImage")
        continue
    }

    # (2) After FROM, insert USER root + a marker block
    if ($line -eq 'FROM --platform=linux/${DUMP_ARCH} ${DOTNET_SDK_IMAGE} AS base') {
        $outLines.Add($line)
        $outLines.Add('')
        $outLines.Add('# -- Chainguard adaptation ----------------------------------------------------')
        $outLines.Add('# Chainguard images run as nonroot by default. apk + the global dotnet')
        $outLines.Add('# tool installs that follow need root, so switch explicitly. If you want')
        $outLines.Add('# the final image to drop to nonroot, add a USER nonroot near the end')
        $outLines.Add('# (after all installs) and write the PATH/MOTD snippet from the canonical')
        $outLines.Add('# base to /home/nonroot/.bashrc as well as /root/.bashrc.')
        $outLines.Add('USER root')
        continue
    }

    # NOTE: DOTNET_ROLL_FORWARD=Major is no longer inserted here — the
    # canonical common/base.dockerfile now sets it directly (the dotnet-monitor
    # pin needs it on the Microsoft SDK image too once that image advances past
    # the pinned major). The Chainguard variant inherits it via passthrough.

    # (3a) Start of the apt-get block — emit the apk replacement, then swallow
    # The Chainguard curated feed omits lldb/btop; pull in the public Wolfi
    # feed (same key chain). lldb is REQUIRED — discover it dynamically and
    # fail hard with diagnostic output if no candidate is found.
    if ($line -match '^RUN apt-get update \\$') {
        $inApt = $true
        $outLines.Add('# Chainguard adaptation: apt-get replaced with apk add.')
        $outLines.Add("# Chainguard's curated feed omits some diagnostic tools (lldb, btop).")
        $outLines.Add('# Pull in the public Wolfi feed for those — Chainguard images are built')
        $outLines.Add('# on top of Wolfi and share the same package keychain.')
        $outLines.Add('#')
        $outLines.Add('# lldb: empirically NOT in the free Chainguard or Wolfi feeds (as of')
        $outLines.Add('# the 2026 builds we verified — `apk search lldb` returns only rust')
        $outLines.Add('# packages that mention LLDB in their description). It is available')
        $outLines.Add("# in Chainguard's paid Production tier; if you have that, append")
        $outLines.Add('# apk.cgr.dev/extra-packages to /etc/apk/repositories before this RUN.')
        $outLines.Add('#')
        $outLines.Add('# The block below still attempts dynamic discovery — if Wolfi ever')
        $outLines.Add('# adds an lldb package, it gets picked up automatically. If not, we')
        $outLines.Add('# log a clear INFO and continue: delve-lldb is optional; delve')
        $outLines.Add('# (dotnet-dump) is the documented primary interactive path.')
        $outLines.Add('#')
        $outLines.Add('# tar is typically pre-installed in the Chainguard SDK image and is not')
        $outLines.Add('# in either curated feed by that exact name; verify-then-install.')
        $outLines.Add('RUN wget -qO /etc/apk/keys/wolfi-signing.rsa.pub \')
        $outLines.Add('        https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \')
        $outLines.Add("    && echo 'https://packages.wolfi.dev/os' >> /etc/apk/repositories \")
        $outLines.Add('    && apk update \')
        $outLines.Add('    && apk add --no-cache \')
        # Drop lldb + tar from the main list — handled specially below.
        $corePackages = $aptPackages | Where-Object { $_ -notin @('lldb','tar') }
        for ($i = 0; $i -lt $corePackages.Count; $i++) {
            $outLines.Add("        $($corePackages[$i]) \")
        }
        $outLines.Add('    && apk update \')
        $outLines.Add("    && LLDB_PKG=`$(apk search lldb 2>/dev/null \")
        $outLines.Add("            | sed -E 's/-[^-]+-r[0-9]+`$//' \")
        $outLines.Add('            | sort -uV \')
        $outLines.Add("            | grep -E '^lldb(-[0-9]+|-default)?`$' \")
        $outLines.Add('            | tail -1) \')
        $outLines.Add('    && if [ -n "${LLDB_PKG}" ]; then \')
        $outLines.Add('           echo "Installing lldb package: ${LLDB_PKG}"; \')
        $outLines.Add('           apk add --no-cache "${LLDB_PKG}"; \')
        $outLines.Add('       else \')
        $outLines.Add("           echo 'INFO: no lldb in the configured apk feeds (Chainguard public + Wolfi os).'; \")
        $outLines.Add("           echo '      delve-lldb wrapper will be unavailable; delve (dotnet-dump) is unaffected.'; \")
        $outLines.Add("           echo '      For lldb on Chainguard, append apk.cgr.dev/extra-packages (paid tier).'; \")
        $outLines.Add('       fi \')
        $outLines.Add('    && (   command -v tar >/dev/null 2>&1 \')
        $outLines.Add('        || apk add --no-cache tar \')
        $outLines.Add("        || { echo 'ERROR: tar not available' >&2; exit 1; })")
        continue
    }

    # Toolchain-smoke adaptation: lldb may not have installed (the free
    # Chainguard / Wolfi feeds don't ship it). Guard the two `lldb`
    # invocations so the build doesn't fail when it's absent. delve-lldb is
    # optional; delve (dotnet-dump) is the primary path and unaffected.
    if ($line -eq '    && lldb --version \') {
        $outLines.Add('    && (command -v lldb >/dev/null 2>&1 && lldb --version \')
        $outLines.Add('         || echo "INFO: lldb absent (Chainguard free feed); delve-lldb wrapper unavailable") \')
        continue
    }
    if ($line -eq '        lldb --batch -o "plugin load ${SOS_PLUGIN}" -o "help sos" -o "quit" 2>&1 | head -10 \') {
        $outLines.Add('        (command -v lldb >/dev/null 2>&1 \')
        $outLines.Add('            && lldb --batch -o "plugin load ${SOS_PLUGIN}" -o "help sos" -o "quit" 2>&1 | head -10 \')
        $outLines.Add('            || echo "INFO: lldb absent — SOS plugin load check skipped") \')
        continue
    }

    # (3b) Skip the rest of the apt block
    if ($inApt) {
        if ($line -match '&& rm -rf /var/lib/apt/lists/\*$') {
            $inApt = $false
        }
        continue
    }

    $outLines.Add($line)
}

# Write base.dockerfile with LF endings (it's a Dockerfile — .gitattributes
# enforces LF on *.dockerfile but be explicit).
$joined = ($outLines -join "`n") + "`n"
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
