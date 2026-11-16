# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# common/base.dockerfile — dotnet-autopsy SHARED BASE image
#
# The reusable toolchain layer shared by every dotnet-autopsy sibling
# (sos = core-dump analysis, trace = dotnet-trace analysis, …). Build &
# tag ONCE; per-case images do `FROM dotnet-autopsy-base`.
#
#   docker build -f common/base.dockerfile -t dotnet-autopsy-base .
#
# Build context is the REPO ROOT (so COPY can reach common/ ; .dockerignore
# is the existing root one). Contains: apt diagnostics packages, the .NET
# global tools (incl. dotnet-trace) + pwsh + dotnet-monitor, the NuGet-backed
# file server host, the Fresh editor, the SHARED .NET 11 file-based report apps
# (analysis_md, json-get) published to /opt/report-bin, the shared
# /usr/local/bin/json-get shim + PATH hardening, the reusable-sources bake
# (/analysis/sources), and the always-on toolchain smoke. Per-image triage
# apps (triage_summary, trace_triage), the dump/trace, delve wrappers and
# the SMOKE_TEST=1 end-to-end live in the per-image Dockerfile.
#
# Key build args:
#   DUMP_ARCH          — image CPU arch: amd64 (default) or arm64
#   DOTNET_SDK_IMAGE   — override base (e.g. mcr.microsoft.com/dotnet/sdk:11.0-resolute)
#   FILESERVER_VERSION — Bennewitz.Ninja.FileServer NuGet package version
#                        (default: latest = newest stable; pin for reproducibility)
# ─────────────────────────────────────────────────────────────────────────────

# ── Build-time args (before FROM so --platform can use them) ─────────────────
ARG DUMP_ARCH=amd64
ARG DOTNET_SDK_IMAGE=cgr.dev/chainguard/dotnet-sdk:latest-dev
ARG FILESERVER_REPO=JanusMael/Bennewitz.Ninja.FileServer
ARG FILESERVER_VERSION=latest
# dotnet-monitor and PowerShell are the pinned tools (the diagnostic tools
# float "newest"). dotnet-monitor's release cadence is independent of the SDK
# and an unpinned `dotnet tool install dotnet-monitor` is unreliable, so we
# pin a version verified to install AND run on the base image. Override via
# --build-arg.
ARG DOTNET_MONITOR_VERSION=10.0.5
# PowerShell global tool — pinned because 7.7.0 (published 2026-11-10) is
# uninstallable: it depends on powershell.linux-x64 7.7.0, which nuget.org
# does not carry. 7.6.10 targets .NET 10 and launches on newer runtimes via
# DOTNET_ROLL_FORWARD=Major. Return to floating (or bump) once a 7.7.x
# installs. Override via --build-arg.
ARG POWERSHELL_VERSION=7.6.10
# Fresh terminal editor (github.com/sinelaw/fresh) — pinned, static musl
# binary fetched at build time (no apt deps; sha256-verified). For SDK devs
# editing/repro in interactive sessions; nano is kept as the minimal fallback.
ARG FRESH_VERSION=v0.3.6

FROM --platform=linux/${DUMP_ARCH} ${DOTNET_SDK_IMAGE} AS base

# ── Chainguard adaptation ────────────────────────────────────────────────────
# Chainguard images run as nonroot by default. apk + the global dotnet
# tool installs that follow need root, so switch explicitly. If you want
# the final image to drop to nonroot, add a USER nonroot near the end
# (after all installs) and write the PATH/MOTD snippet from the canonical
# base to /home/nonroot/.bashrc as well as /root/.bashrc.
USER root

# Re-declare ARGs after FROM (Docker scope rule)
ARG DUMP_ARCH=amd64
ARG DOTNET_SDK_IMAGE=cgr.dev/chainguard/dotnet-sdk:latest-dev
ARG FILESERVER_REPO=JanusMael/Bennewitz.Ninja.FileServer
ARG FILESERVER_VERSION=latest
ARG DOTNET_MONITOR_VERSION=10.0.5
ARG POWERSHELL_VERSION=7.6.10
ARG FRESH_VERSION=v0.3.6

# Expose base image tag to scripts via env (for provenance)
ENV DOTNET_SDK_IMAGE=${DOTNET_SDK_IMAGE}

# ── Diagnostics env vars ───────────────────────────────────────────────────────
# Do NOT set DOTNET_DbgEnableMiniDump globally. If an analyzer itself
# (dotnet-dump/ClrMD) crashes on a low-fidelity input, a global setting makes
# the runtime write a multi-GB minidump INTO the image layer (observed: an
# 8 GB /tmp/core.dump → 11 GB image). The SMOKE_TEST step and the rot-check
# workflow set DOTNET_DbgEnableMiniDump inline, per-invocation, which is the
# only place a crash dump is actually wanted.
ENV DOTNET_PerfMapEnabled=1
# Chainguard adaptation: EventLog off. This image ships liblttng-ust, so
# DOTNET_EnableEventLog=1 loads the runtime LTTng tracepoint provider, and
# on .NET 11 dotnet-sos then segfaults at process exit (exit 139), failing
# RUN dotnet-sos install. The Microsoft SDK image has no liblttng-ust, so
# there the setting is inert; 0 here matches its effective behavior.
ENV DOTNET_EnableEventLog=0

# Roll forward across MAJOR runtime versions. This image floats every tool to
# newest, but a tool can still target an older major than the base runtime:
# dotnet-monitor and PowerShell are PINNED (PowerShell 7.6.x targets .NET 10
# and needs this to run on 11), and the floating diagnostic tools can lag a
# new SDK major (at .NET 11 GA the newest were 10.x). Once the base SDK image stops shipping that older major
# side-by-side, a framework-dependent tool built for it fails to launch with
# the .NET host's "framework not found" error (process exit code 150). Major
# roll-forward lets such a tool run on the newer runtime that IS present —
# exactly the rot-resilience this image is built for. The current monitor pin
# runs natively; this guards the next SDK major the same way it guarded this
# one.
# Report apps (analysis_md, json-get, the per-image triage apps) target the
# current major, so they exact-match first and roll-forward never engages —
# the parity GOLDEN output is unaffected (and parity runs outside the image
# anyway, where this env is not set).
ENV DOTNET_ROLL_FORWARD=Major

# ── Analysis environment ───────────────────────────────────────────────────────
ENV FILE_SERVER_DIR=/fileserver
ENV FILES_DIR=/analysis
ENV CASE_OUTPUT=${FILES_DIR}/analysis.txt
ENV SYMBOLS_CACHE=${FILES_DIR}/symbols

# ── Package install ────────────────────────────────────────────────────────────
# ONE block — the documented seam for base-image swaps (apt→apk for Chainguard).
# All packages tuned for post-mortem diagnosis; live-process-only tools
# (netcat, telnet, dnsutils, procdump) intentionally omitted.
#
# To swap to Chainguard/Wolfi: change FROM above and replace this block with:
#   RUN apk add --no-cache lldb gdb elfutils binutils file less nano \
#       procps btop curl ca-certificates tar gzip unzip
# (and add USER root before build steps if using nonroot base)
# Chainguard adaptation: apt-get replaced with apk add.
# Chainguard's curated feed omits some diagnostic tools (lldb, btop).
# Pull in the public Wolfi feed for those — Chainguard images are built
# on top of Wolfi and share the same package keychain.
#
# lldb: empirically NOT in the free Chainguard or Wolfi feeds (as of
# the 2026 builds we verified — `apk search lldb` returns only rust
# packages that mention LLDB in their description). It is available
# in Chainguard's paid Production tier; if you have that, append
# apk.cgr.dev/extra-packages to /etc/apk/repositories before this RUN.
#
# The block below still attempts dynamic discovery — if Wolfi ever
# adds an lldb package, it gets picked up automatically. If not, we
# log a clear INFO and continue: delve-lldb is optional; delve
# (dotnet-dump) is the documented primary interactive path.
#
# tar is typically pre-installed in the Chainguard SDK image and is not
# in either curated feed by that exact name; verify-then-install.
RUN wget -qO /etc/apk/keys/wolfi-signing.rsa.pub \
        https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \
    && echo 'https://packages.wolfi.dev/os' >> /etc/apk/repositories \
    && apk update \
    && apk add --no-cache \
        gdb \
        elfutils \
        binutils \
        file \
        less \
        nano \
        procps \
        btop \
        curl \
        ca-certificates \
        gzip \
        unzip \
    && apk update \
    && LLDB_PKG=$(apk search lldb 2>/dev/null \
            | sed -E 's/-[^-]+-r[0-9]+$//' \
            | sort -uV \
            | grep -E '^lldb(-[0-9]+|-default)?$' \
            | tail -1) \
    && if [ -n "${LLDB_PKG}" ]; then \
           echo "Installing lldb package: ${LLDB_PKG}"; \
           apk add --no-cache "${LLDB_PKG}"; \
       else \
           echo 'INFO: no lldb in the configured apk feeds (Chainguard public + Wolfi os).'; \
           echo '      delve-lldb wrapper will be unavailable; delve (dotnet-dump) is unaffected.'; \
           echo '      For lldb on Chainguard, append apk.cgr.dev/extra-packages (paid tier).'; \
       fi \
    && (   command -v tar >/dev/null 2>&1 \
        || apk add --no-cache tar \
        || { echo 'ERROR: tar not available' >&2; exit 1; })

# ── .NET global diagnostic tools (newest, no version pin) + PowerShell ────────
# The DAC version is irrelevant here — it's downloaded per-dump by build-ID.
# PowerShell is installed as a .NET global tool (`pwsh`) rather than via the
# packages.microsoft.com apt feed: it needs no apt repo/GPG key and stays
# base-image-independent (survives the Chainguard swap). It is pinned via
# ${POWERSHELL_VERSION} (see the ARG for why). Useful for scripting triage in
# this .NET-oriented container.
#
# dotnet-monitor is installed (NOT run as a service — this is a post-mortem
# container with no live target app) for ad-hoc interactive use. It is the
# one PINNED tool: its release cadence is independent of the SDK and an
# unpinned install is unreliable. Override via --build-arg. The pinned version
# was verified to launch on the base runtime without roll-forward; because it
# is pinned to a specific major, the DOTNET_ROLL_FORWARD=Major env set above
# keeps it launching once the base SDK image advances past that major (see
# that block). Bump ${DOTNET_MONITOR_VERSION} when a release natively targets
# the new runtime.
RUN dotnet tool install --tool-path /opt/bin dotnet-counters \
    && dotnet tool install --tool-path /opt/bin dotnet-dump \
    && dotnet tool install --tool-path /opt/bin dotnet-gcdump \
    && dotnet tool install --tool-path /opt/bin dotnet-sos \
    && dotnet tool install --tool-path /opt/bin dotnet-stack \
    && dotnet tool install --tool-path /opt/bin dotnet-trace \
    && dotnet tool install --tool-path /opt/bin dotnet-symbol \
    && dotnet tool install --tool-path /opt/bin PowerShell --version "${POWERSHELL_VERSION}" \
    && dotnet tool install --tool-path /opt/bin dotnet-monitor --version "${DOTNET_MONITOR_VERSION}"

ENV PATH=/opt/bin:$PATH

# Register SOS plugin with lldb (~/.dotnet/sos/libsosplugin.so → ~/.lldbinit)
RUN dotnet-sos install

# ── File server — ASP.NET Core host around the Bennewitz.Ninja.FileServer NuGet ─
# The file server is consumed as a NuGet LIBRARY (Bennewitz.Ninja.FileServer:
# AddFileServer() + MapFileServer()), hosted by the tiny ASP.NET Core app in
# common/FileServerHost/. Published here, once, framework-dependent — it runs
# on the image's own ASP.NET Core runtime on amd64 and arm64 alike, so the
# former per-RID prebuilt-tarball download (and its RID switch) is gone.
#
# FILESERVER_VERSION: "latest" → NuGet floating version "*" (newest stable —
# keeps the rot-check "no pins" philosophy); anything else is passed through
# as an exact package version. RELEASE.txt records the version that actually
# RESOLVED (read back from the published deps.json), so dsos-info stays
# accurate in both modes.
#
# Same NativeAOT-off + framework-dependent publish discipline as the report
# apps. The NuGet restore happens here at build time (network) — the base
# already needs NuGet for every `dotnet tool install` above, so this adds no
# new dependency class. It is the base's ONE NuGet package dependency; the
# report apps stay BCL-only (see CONTRIBUTING "Core invariants").
COPY common/FileServerHost/ /opt/FileServerHost/
RUN export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    && if [ "${FILESERVER_VERSION}" = "latest" ]; then PKGVER="*"; else PKGVER="${FILESERVER_VERSION}"; fi \
    && dotnet publish /opt/FileServerHost/FileServerHost.csproj -c Release -o "${FILE_SERVER_DIR}" \
           -p:FileServerPackageVersion="${PKGVER}" \
           -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
           > /tmp/pub-fileserver.log 2>&1 \
       || { echo "ERROR: publish FileServerHost failed"; cat /tmp/pub-fileserver.log; exit 1; } \
    && RESOLVED=$(sed -n 's/.*"Bennewitz\.Ninja\.FileServer\/\([^"]*\)".*/\1/p' "${FILE_SERVER_DIR}/FileServerHost.deps.json" | head -1) \
    && [ -n "${RESOLVED}" ] || RESOLVED="${FILESERVER_VERSION}" \
    && { echo "package         : Bennewitz.Ninja.FileServer"; \
         echo "version         : ${RESOLVED}"; \
         echo "requested       : ${FILESERVER_VERSION}"; \
         echo "source          : https://api.nuget.org/v3/index.json"; \
         echo "repo            : https://github.com/${FILESERVER_REPO}"; \
         echo "host            : common/FileServerHost (ASP.NET Core, framework-dependent)"; \
         echo "published_at    : $(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
       } > "${FILE_SERVER_DIR}/RELEASE.txt" \
    && rm -f /tmp/pub-fileserver.log \
    && echo "File server published: ${FILE_SERVER_DIR}/FileServerHost (Bennewitz.Ninja.FileServer ${RESOLVED})"

# ── Fresh terminal editor — pinned static musl binary, sha256-verified ────────
# A real editor for SDK devs working interactively in the container (nano is
# kept as the minimal fallback). One self-contained static binary + its
# plugins/themes tree → no apt deps, runs on any libc (base-swap resilient).
# Tree installed to /opt/fresh; `fresh` symlinked into /opt/bin, which is on
# PATH for ALL shell types (login + non-login, verified) just like pwsh and
# the dotnet-* tools. Asset: fresh-editor-<rust-arch>-unknown-linux-musl.tar.gz
RUN case "${DUMP_ARCH}" in \
        amd64) RUST_ARCH="x86_64" ;; \
        arm64) RUST_ARCH="aarch64" ;; \
        *)     echo "ERROR: unsupported DUMP_ARCH=${DUMP_ARCH}" && exit 1 ;; \
    esac \
    && ASSET="fresh-editor-${RUST_ARCH}-unknown-linux-musl.tar.gz" \
    && URL="https://github.com/sinelaw/fresh/releases/download/${FRESH_VERSION}/${ASSET}" \
    && echo "Downloading Fresh editor: ${URL}" \
    && mkdir -p /tmp/fresh-dl /opt/fresh \
    && for attempt in 1 2 3; do \
        curl -fSL "${URL}" -o /tmp/fresh-dl/f.tgz \
            && curl -fSL "${URL}.sha256" -o /tmp/fresh-dl/f.sha256 && break; \
        [ "${attempt}" -lt 3 ] && echo "Retry ${attempt}/3..." && sleep $((attempt * 5)); \
    done \
    && PUB=$(awk '{print $1}' /tmp/fresh-dl/f.sha256) \
    && GOT=$(sha256sum /tmp/fresh-dl/f.tgz | awk '{print $1}') \
    && [ -n "${PUB}" ] && [ "${PUB}" = "${GOT}" ] \
        || (echo "ERROR: Fresh checksum mismatch (pub=${PUB} got=${GOT})" && exit 1) \
    && tar -xzf /tmp/fresh-dl/f.tgz -C /opt/fresh --strip-components=1 \
    && [ -x /opt/fresh/fresh ] || (echo "ERROR: fresh binary missing in archive" && exit 1) \
    && ln -sf /opt/fresh/fresh /opt/bin/fresh \
    && rm -rf /tmp/fresh-dl \
    && echo "Fresh editor installed: /opt/fresh/fresh -> /opt/bin/fresh"

# ── Shared report apps + entrypoint (from common/) ────────────────────────────
# Only the GENERIC apps live here: analysis_md (the renderer — profile-driven,
# SOS profile is its built-in default) and json-get (the status.json reader).
# Per-image triage apps (triage_summary, trace_triage) are COPY'd + published
# in the per-image Dockerfile.
COPY common/entrypoint.sh common/analysis_md.cs common/json-get.cs /opt/
# Shared sourced library for the per-image analyze scripts (sos/analyze.sh,
# trace/analyze-trace.sh do `source /opt/lib/analyze-common.sh`). Lives in
# the base since it is shared; smoke-common.sh is host-side (NOT shipped).
COPY common/lib/analyze-common.sh /opt/lib/analyze-common.sh
RUN chmod +x /opt/entrypoint.sh

# ── Publish the SHARED .NET report tools (cached layer; pristine stdout) ───────
# .NET 11 file-based apps compiled ONCE here so the per-case analyze script
# invokes FIXED binaries: no per-case compile, no MSBuild text leaking into
# the authoritative analysis.txt. BCL-only → offline-capable (no NuGet).
# Spike-verified: `dotnet publish file.cs` defaults to NativeAOT (.NET 10 and 11)
# (needs a C linker), hence explicit AOT/single-file=off + framework-dependent
# (the runtime is present at run time since per-image is FROM this base).
# Apphost path is /opt/report-bin/<app>/<app>.
RUN export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    && for app in analysis_md json-get; do \
           dotnet publish "/opt/${app}.cs" -c Release -o "/opt/report-bin/${app}" \
               -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
               > "/tmp/pub-${app}.log" 2>&1 \
           || { echo "ERROR: publish ${app} failed"; cat "/tmp/pub-${app}.log"; exit 1; }; \
       done \
    && /opt/report-bin/json-get/json-get --selftest \
    && rm -f /tmp/pub-*.log \
    && echo "Shared report tools published to /opt/report-bin/{analysis_md,json-get}"

# ── Shared wrappers + PATH hardening ──────────────────────────────────────────
# json-get shim: the .NET status.json reader (replaces the former python3
# one-liners in entrypoint.sh / demo.sh / smoke.sh / rot-check.yml). On PATH
# for login, non-login, and `docker exec` shells.
RUN printf '#!/bin/bash\nexec /opt/report-bin/json-get/json-get "$@"\n' \
        > /usr/local/bin/json-get \
    && chmod +x /usr/local/bin/json-get \
    # /opt/bin holds pwsh + all dotnet-* tools. ENV PATH covers non-login
    # shells, but LOGIN shells (bash -l, sh -l, bash -lc) source /etc/profile
    # which RESETS PATH and drops /opt/bin. profile.d re-adds it for login
    # shells; the .bashrc line covers interactive non-login bash belt-and-braces.
    # NOTE: this profile.d + /root/.bashrc hardening is Debian/bash/root
    # specific. On a Chainguard/Wolfi swap (often nonroot, possibly busybox
    # sh / no profile.d), keep the ENV PATH line and re-point this snippet —
    # see README.md "Adapting the base image".
    && printf '# Keep dotnet-autopsy tooling (pwsh, dotnet-*) on PATH for login shells.\nexport PATH=/opt/bin:$PATH\n' \
        > /etc/profile.d/dotnet-autopsy.sh \
    && chmod 0644 /etc/profile.d/dotnet-autopsy.sh \
    && printf '\n# dotnet-autopsy interactive session\nexport PATH=/opt/bin:$PATH\ncat /analysis/.motd 2>/dev/null\n' \
        >> /root/.bashrc

# ── Reusable sources (advertise standalone-reuse) ─────────────────────────────
# DISTINCT from /analysis/docker/ (which is "how THIS image was built").
# /analysis/sources/ surfaces the standalone-reusable .NET 11 file-based apps
# so consumers see they work outside this project. The SHARED apps + a
# generated README go here in the base (byte-identical in every sibling); the
# per-image stage adds its own triage app.
RUN mkdir -p /analysis/sources
COPY common/analysis_md.cs common/json-get.cs /analysis/sources/
RUN cat > /analysis/sources/README.md << 'SRCREADME'
# dotnet-autopsy — reusable report apps

These are **standalone .NET 11 file-based apps** (no `.csproj`, no NuGet —
BCL only). They power the dotnet-autopsy report pipeline but are deliberately
self-contained so you can reuse them **outside this project**.

Run directly with the SDK:

    dotnet run analysis_md.cs -- <analysis.txt> [status.json] > analysis.md
    dotnet run json-get.cs    -- <file.json> <key>

Or publish a fixed binary (note: `dotnet publish file.cs` defaults to
NativeAOT in .NET 10 and later and needs a C linker — build framework-dependent):

    dotnet publish analysis_md.cs -c Release -o out \
        -p:PublishAot=false -p:PublishSingleFile=false --self-contained false

| App | Contract |
|---|---|
| `json-get.cs` | `json-get <file> <key>` → top-level string value (`unknown` if absent; nonzero on error). Mirrors `json.load(open(f)).get(k,'unknown')`. |
| `analysis_md.cs` | `analysis_md <analysis.txt> [status.json]` → a navigable, XSS-safe Markdown view on stdout. Always exits 0 (single-fenced fallback on any error). Renderer is profile-driven; the SOS profile is the built-in default. |

The per-image triage app (`triage_summary.cs` for the dump image,
`trace_triage.cs` for the trace image) is alongside this README in each
image. See the per-image `RUNBOOK.md` → "Extending the report tools" for the
parity-gate discipline and the NativeAOT publish note. Licence: see the
project `LICENSE`.
SRCREADME

# ── Toolchain smoke test (always — fail build if the shared layer is broken) ──
RUN echo "=== Toolchain smoke test ===" \
    && dotnet --info \
    && (command -v lldb >/dev/null 2>&1 && lldb --version \
         || echo "INFO: lldb absent (Chainguard free feed); delve-lldb wrapper unavailable") \
    && dotnet-dump --version \
    && dotnet-symbol --help >/dev/null \
    && pwsh --version \
    && pwsh -NoProfile -NonInteractive -Command '"pwsh OK: " + $PSVersionTable.PSVersion' \
    && dotnet-monitor --version \
    && fresh --version \
    && btop --version \
    && eu-readelf --version \
    && gdb --version \
    && /opt/report-bin/json-get/json-get --selftest \
    && echo "=== All tools present ===" \
    && SOS_PLUGIN=$(find /root/.dotnet/sos -name "libsosplugin.so" 2>/dev/null | head -1) \
    && if [ -n "${SOS_PLUGIN}" ]; then \
        echo "SOS plugin: ${SOS_PLUGIN}"; \
        (command -v lldb >/dev/null 2>&1 \
            && lldb --batch -o "plugin load ${SOS_PLUGIN}" -o "help sos" -o "quit" 2>&1 | head -10 \
            || echo "INFO: lldb absent — SOS plugin load check skipped") \
            && echo "=== SOS loads in lldb ===" || echo "=== WARNING: SOS lldb load check failed ==="; \
    else \
        echo "WARNING: libsosplugin.so not found — dotnet-sos install may have failed"; \
    fi
