# dotnet-dump analysis — 7.7.7 / ddd — status: unknown

> Rendered view of `analysis.txt`. Authoritative raw source: [analysis.txt](/analysis/analysis.txt) · machine status: [status.json](/analysis/status.json) · [raw markdown](/analysis/analysis.md?raw=1). This file is generated; `analysis.txt` is the source of truth.

<a id="sec-contents"></a>
## Contents

- [Provenance](#sec-provenance)
- [⚠ Analysis degraded](#sec-degraded)

<a id="sec-provenance"></a>
## Provenance
_How this image was built — pin these via --build-arg to reproduce the exact analysis environment._

| Key | Value |
|---|---|
| report_tool | dotnet-dump |
| runtime_version | 7.7.7 |
| dump_arch | ddd |

<a id="sec-degraded"></a>
## ⚠ Analysis degraded
_The dump could not be fully analyzed — what failed and how to capture a usable one._

> FAIL_REASON: dump truncated — DAC not found for this build-id

~~~shell
════════════════════════════════════════════════════════════
  ⚠ ANALYSIS DEGRADED — low fidelity dump
════════════════════════════════════════════════════════════
  FAIL_REASON: dump truncated — DAC not found for this build-id
  Capture a full dump (see RUNBOOK.md § Troubleshooting).
════════════════════════════════════════════════════════════
~~~
