# dotnet-dump analysis — 9.9.9 / testarch — status: unknown

> Rendered view of `analysis.txt`. Authoritative raw source: [analysis.txt](/analysis/analysis.txt) · machine status: [status.json](/analysis/status.json) · [raw markdown](/analysis/analysis.md?raw=1). This file is generated; `analysis.txt` is the source of truth.

<a id="sec-contents"></a>
## Contents

- [Provenance](#sec-provenance)
- [Auto-triage summary](#sec-triage)
  - [Top Exception](#tri-top-exception)
- [Full SOS output](#sec-sos)

<a id="sec-provenance"></a>
## Provenance
_How this image was built — pin these via --build-arg to reproduce the exact analysis environment._

| Key | Value |
|---|---|
| report_tool | dotnet-dump |
| runtime_version | 9.9.9 |
| dump_arch | testarch |

<a id="sec-triage"></a>
## Auto-triage summary
_A synthesized at-a-glance read of the crash; the full raw SOS detail follows below._

| Field | Value |
|---|---|
| Runtime | 9.9.9 |
| Dump arch | testarch |

<a id="tri-top-exception"></a>
### Top Exception
_The fatal managed exception (type, message, inner chain) — usually the proximate cause._

~~~~~shell
  Type    : <script>alert(1)</script>
~~~~ tilde-run body line that must not break the fence
  Message : <b>not html</b> & <i>x</i>
~~~~~

<a id="sec-sos"></a>
## Full SOS output
_Raw dotnet-dump / SOS output, split per command — the authoritative detail._

_(could not split by command — full raw output below)_

~~~~~~~shell
this raw line matches no command anchor signature
<script>document.cookie</script>
~~~~~~ a deeper tilde run in the raw fallback block
plain tail line
~~~~~~~
