# dotnet-trace analysis — 10.0.826.23019 / x86_64 — status: success

> Rendered view of `analysis.txt`. Authoritative raw source: [analysis.txt](/analysis/analysis.txt) · machine status: [status.json](/analysis/status.json) · [raw markdown](/analysis/analysis.md?raw=1). This file is generated; `analysis.txt` is the source of truth.

<a id="sec-contents"></a>
## Contents

- [Provenance](#sec-provenance)
- [Auto-triage summary](#sec-triage)
  - [Top Cpu Functions](#tri-top-cpu-functions)
  - [Trace Metadata](#tri-trace-metadata)
  - [Gc Summary](#tri-gc-summary)
  - [Exception Counts (Top 10)](#tri-exception-counts-top-10)
  - [Heuristic Warnings](#tri-heuristic-warnings)
- [Full trace output](#sec-sos)
  - [Session / symbol setup](#cmd-session)
  - [`dotnet-trace report topN`](#cmd-dotnet-trace-report-topn)
  - [`dotnet-trace convert speedscope`](#cmd-dotnet-trace-convert-speedscope)

<a id="sec-provenance"></a>
## Provenance
_How this image was built — pin these via --build-arg to reproduce the exact analysis environment._

| Key | Value |
|---|---|
| report_tool | dotnet-trace |
| base_image_tag | mcr.microsoft.com/dotnet/sdk:10.0 |
| dotnet_sdk | 10.0.300 |
| dotnet-trace | 9.0.661903+d7b455b46332b31fd9ba3a3f3e020387984c511a |
| dotnet-monitor | 9.0.0  (pinned) |
| trace_sha256 | dd27c8358e83012824defd265daa3d8803fa205146ebe2c296130a5b89562db9 |
| trace_size_bytes | 1266750 |
| dump_arch | x86_64 |
| container_arch | x86_64 |
| runtime_version | 10.0.826.23019 |
| trace_fidelity | full-or-triage |
| build_timestamp | 2026-05-21T12:59:23Z |

<a id="sec-triage"></a>
## Auto-triage summary
_A synthesized at-a-glance read of the crash; the full raw SOS detail follows below._

| Field | Value |
|---|---|
| Runtime | 10.0.826.23019 |
| Trace arch | x86_64 |
| Trace fidelity | full-or-triage |
| Tool | dotnet-trace 9.0.661903+d7b455b46332b31fd9ba3a3f3e020387984c511a |
| Build time | 2026-05-21T12:59:23Z |

<a id="tri-top-cpu-functions"></a>
### Top Cpu Functions

~~~shell
   1. Thread.Sleep(int32)                                                     incl= 49.81%  excl= 49.81%
   2. app!Program.<Main>$(class System.String[])                              incl= 49.82%  excl= 16.72%
   3. Thread.<PollGC>g__PollGCWorker|67_0()                                   incl= 14.12%  excl= 14.12%
   4. app!Program.<<Main>$>g__HashRecords|0_1(int32)                          incl= 15.81%  excl= 11.37%
   5. Cryptography!Interop+Crypto.EvpDigestReset(class Microsoft.Win32.SafeH  incl=  1.86%  excl=  1.86%
   6. HashProviderDispenser+EvpHashProvider.AppendHashData(value class Syste  incl=  3.06%  excl=  1.71%
   7. Cryptography!Interop+Crypto.EvpDigestUpdate(class Microsoft.Win32.Safe  incl=  1.35%  excl=  1.35%
   8. Object.MemberwiseClone()                                                incl=  0.87%  excl=  0.87%
   9. app!Program.<<Main>$>g__ParseAndSum|0_2(int32)                          incl=  0.68%  excl=  0.39%
  10. Cryptography!Interop+Crypto.EvpDigestFinalEx(class Microsoft.Win32.Saf  incl=   0.3%  excl=   0.3%
  11. Number.TryParseBinaryIntegerStyle(value class System.ReadOnlySpan`1<!!  incl=  0.23%  excl=  0.23%
  12. HashProviderDispenser+EvpHashProvider.FinalizeHashAndReset(value class  incl=  0.72%  excl=  0.17%
  13. HashProvider.AppendHashData(unsigned int8[],int32,int32)                incl=  1.51%  excl=  0.17%
  14. .ctor(class System.RuntimeType)                                         incl=  0.14%  excl=  0.13%
  15. Array.Copy(class System.Array,class System.Array,int32)                 incl=  10.9%  excl=   0.1%
  16. app!Program.<<Main>$>g__AllocateBuffers|0_3(int32)                      incl= 10.49%  excl=  0.06%
  17. EventSource.CreateManifestAndDescriptors(class System.Type,class Syste  incl=  0.29%  excl=  0.04%
  18. EventSource.SetCurrentThreadActivityId(value class System.Guid)         incl=  0.04%  excl=  0.04%
  19. SearchValues.Create(value class System.ReadOnlySpan`1<wchar>)           incl=  0.04%  excl=  0.04%
  20. Cryptography!Interop+Crypto.EvpMdCtxCreate(int)                         incl=  0.12%  excl=  0.03%
  21. Thread.PollGC()                                                         incl=  0.03%  excl=  0.03%
  22. Int32.ToString()                                                        incl=  0.04%  excl=  0.03%
  23. Number.UInt32ToDecStr_NoSmallNumberCheck(unsigned int32)                incl=  0.03%  excl=  0.03%
  24. .ctor(int32,class System.Collections.Generic.IEqualityComparer`1<!0>)   incl=  0.03%  excl=  0.03%
  25. UTF8Encoding.GetByteCount(class System.String)                          incl=  0.01%  excl=  0.01%
~~~

<a id="tri-trace-metadata"></a>
### Trace Metadata

~~~shell
  Trace file    : /analysis/demo-trace.nettrace
  File size     : 1266750 bytes
  Sample count  : 6376
  Duration      : 4032 ms
~~~

<a id="tri-gc-summary"></a>
### Gc Summary

~~~shell
  Gen 0 / Gen 1 / Gen 2 : 594 / 1 / 0
  Total GC pause time   : 52.2 ms
  Max single GC pause   : 0.6 ms
~~~

<a id="tri-exception-counts-top-10"></a>
### Exception Counts (Top 10)

~~~shell
  (no exceptions thrown during the captured window)
~~~

<a id="tri-heuristic-warnings"></a>
### Heuristic Warnings
_Automated red flags (deadlock/contention, thread-pool backlog, finalizer backlog, OOM). Hints, not conclusions._

~~~shell
  ▸ Highly concentrated CPU: top 3 functions = 80.65% exclusive
~~~

<a id="sec-sos"></a>
## Full trace output

<a id="cmd-session"></a>
### Session / symbol setup
_dotnet-dump startup: symbol-server settings and runtime/DAC resolution._

~~~shell
trace_file_path: /analysis/demo-trace.nettrace
trace_file_size: 1266750
~~~

<a id="cmd-dotnet-trace-report-topn"></a>
### `dotnet-trace report topN`

~~~shell
=== dotnet-trace report topN -n 25 ===
Top 25 Functions (Exclusive)                                                  Inclusive           Exclusive           
1.  Thread.Sleep(int32)                                                       49.81%              49.81%              
2.  app!Program.<Main>$(class System.String[])                                49.82%              16.72%              
3.  Thread.<PollGC>g__PollGCWorker|67_0()                                     14.12%              14.12%              
4.  app!Program.<<Main>$>g__HashRecords|0_1(int32)                            15.81%              11.37%              
5.  Cryptography!Interop+Crypto.EvpDigestReset(class Microsoft.Win32.SafeH    1.86%               1.86%               
6.  HashProviderDispenser+EvpHashProvider.AppendHashData(value class Syste    3.06%               1.71%               
7.  Cryptography!Interop+Crypto.EvpDigestUpdate(class Microsoft.Win32.Safe    1.35%               1.35%               
8.  Object.MemberwiseClone()                                                  0.87%               0.87%               
9.  app!Program.<<Main>$>g__ParseAndSum|0_2(int32)                            0.68%               0.39%               
10. Cryptography!Interop+Crypto.EvpDigestFinalEx(class Microsoft.Win32.Saf    0.3%                0.3%                
11. Number.TryParseBinaryIntegerStyle(value class System.ReadOnlySpan`1<!!    0.23%               0.23%               
12. HashProviderDispenser+EvpHashProvider.FinalizeHashAndReset(value class    0.72%               0.17%               
13. HashProvider.AppendHashData(unsigned int8[],int32,int32)                  1.51%               0.17%               
14. .ctor(class System.RuntimeType)                                           0.14%               0.13%               
15. Array.Copy(class System.Array,class System.Array,int32)                   10.9%               0.1%                
16. app!Program.<<Main>$>g__AllocateBuffers|0_3(int32)                        10.49%              0.06%               
17. EventSource.CreateManifestAndDescriptors(class System.Type,class Syste    0.29%               0.04%               
18. EventSource.SetCurrentThreadActivityId(value class System.Guid)           0.04%               0.04%               
19. SearchValues.Create(value class System.ReadOnlySpan`1<wchar>)             0.04%               0.04%               
20. Cryptography!Interop+Crypto.EvpMdCtxCreate(int)                           0.12%               0.03%               
21. Thread.PollGC()                                                           0.03%               0.03%               
22. Int32.ToString()                                                          0.04%               0.03%               
23. Number.UInt32ToDecStr_NoSmallNumberCheck(unsigned int32)                  0.03%               0.03%               
24. .ctor(int32,class System.Collections.Generic.IEqualityComparer`1<!0>)     0.03%               0.03%               
25. UTF8Encoding.GetByteCount(class System.String)                            0.01%               0.01%               
~~~

<a id="cmd-dotnet-trace-convert-speedscope"></a>
### `dotnet-trace convert speedscope`

~~~shell
=== dotnet-trace convert --format speedscope ===
Processing trace data file '/analysis/demo-trace.nettrace' to create a new Speedscope file '/analysis/trace.speedscope.json'.
Conversion complete
speedscope_file : /analysis/trace.speedscope.json (708542 bytes)
~~~
