# dotnet-dump analysis — 10.0.8 / x86_64 — status: success

> Rendered view of `analysis.txt`. Authoritative raw source: [analysis.txt](/analysis/analysis.txt) · machine status: [status.json](/analysis/status.json) · [raw markdown](/analysis/analysis.md?raw=1). This file is generated; `analysis.txt` is the source of truth.

<a id="sec-contents"></a>
## Contents

- [Provenance](#sec-provenance)
- [Auto-triage summary](#sec-triage)
  - [Top Exception](#tri-top-exception)
  - [Faulting Thread (clrthreads)](#tri-faulting-thread-clrthreads)
  - [Faulting & User-Code Call Stacks](#tri-faulting-user-code-call-stacks)
  - [Heuristic Warnings](#tri-heuristic-warnings)
  - [Top Heap Types (Dumpheap -Stat, Last 20 Entries)](#tri-top-heap-types-dumpheap-stat-last-20-entries)
- [Full SOS output](#sec-sos)
  - [Session / symbol setup](#cmd-session)
  - [`runtimes`](#cmd-runtimes)
  - [`clrmodules`](#cmd-clrmodules)
  - [`clrthreads`](#cmd-clrthreads)
  - [`parallelstacks`](#cmd-parallelstacks)
  - [`clrstack -all`](#cmd-clrstack-all)
  - [`printexception -nested`](#cmd-printexception-nested)
  - [Inner exception detail — level 1 - 000076AD6AEBBE88](#cmd-inner-exception-detail-level-1-000076ad6aebbe88)
  - [`finalizequeue`](#cmd-finalizequeue)
  - [`threadpool`](#cmd-threadpool)
  - [`syncblk`](#cmd-syncblk)
  - [`eeheap -gc`](#cmd-eeheap-gc)
  - [`dumpheap -stat`](#cmd-dumpheap-stat)
  - [`analyzeoom`](#cmd-analyzeoom)

<a id="sec-provenance"></a>
## Provenance
_How this image was built — pin these via --build-arg to reproduce the exact analysis environment._

| Key | Value |
|---|---|
| report_tool | dotnet-dump |
| base_image_tag | mcr.microsoft.com/dotnet/sdk:10.0 |
| dotnet_sdk | 10.0.300 |
| dotnet-dump | 9.0.661903+d7b455b46332b31fd9ba3a3f3e020387984c511a |
| dotnet-symbol | 9.0.661903 |
| dotnet-sos | 9.0.661903+d7b455b46332b31fd9ba3a3f3e020387984c511a |
| dotnet-monitor | 9.0.0  (pinned) |
| dump_sha256 | 09d222ade43abd26b7833ab1c50004c85fce8183aed68ac4e293e8bdbcb4a0bc |
| dump_arch | x86_64 |
| runtime_version | 10.0.8 |
| dump_fidelity | full-or-triage |
| build_timestamp | 2026-05-18T00:23:11Z |

<a id="sec-triage"></a>
## Auto-triage summary
_A synthesized at-a-glance read of the crash; the full raw SOS detail follows below._

| Field | Value |
|---|---|
| Runtime | 10.0.8 |
| Dump arch | x86_64 |
| Dump fidelity | full-or-triage |
| DAC source | microsoft_symbol_server |
| Build time | 2026-05-18T00:23:11Z |

<a id="tri-top-exception"></a>
### Top Exception
_The fatal managed exception (type, message, inner chain) — usually the proximate cause._

~~~shell
Type    : System.ExecutionEngineException  [000076ad6ac00178]
  Message : (none)
  ── inner #1: System.InvalidOperationException  [000076ad6aebbe88]  (likely root cause)
     Message : simulated failure for the dotnet-sos demo dump
~~~

<a id="tri-faulting-thread-clrthreads"></a>
### Faulting Thread (clrthreads)
_The managed thread that carried the exception — its clrthreads row._

~~~shell
0    1       72 00005723823484B0    20020 Preemptive  000076AD6AEC2750:000076AD6AEC2FF0 0000572382314B50 -00001 Ukn System.ExecutionEngineException 000076ad6ac00178
~~~

<a id="tri-faulting-user-code-call-stacks"></a>
### Faulting & User-Code Call Stacks
_Managed call stacks: the faulting thread first, then threads running your app's code (framework/infra-only threads are omitted)._

~~~shell
── Thread OSID 0x72  [FAULTING THREAD] ──
OS Thread Id: 0x72
        Child SP               IP Call Site
00007FFEAC273000 000076bc9d6bf813 [InlinedCallFrame: 00007ffeac273000] 
00007FFEAC273000 000076bc1dfaccae [InlinedCallFrame: 00007ffeac273000] 
00007FFEAC272FE0 000076BC1DFACCAE System.Environment.FailFast(System.Runtime.CompilerServices.StackCrawlMarkHandle, System.String, System.Runtime.CompilerServices.ObjectHandleOnStack, System.String) [/_/src/runtime/artifacts/obj/coreclr/System.Private.CoreLib/linux.x64.Release/generated/Microsoft.Interop.LibraryImportGenerator/Microsoft.Interop.LibraryImportGenerator/LibraryImports.g.cs @ 399]
00007FFEAC2730A0 000076BC1DFACC2F System.Environment.FailFast(System.Threading.StackCrawlMark ByRef, System.String, System.Exception, System.String) [/_/src/runtime/src/coreclr/System.Private.CoreLib/src/System/Environment.CoreCLR.cs @ 83]
00007FFEAC2730B0 000076BC1DFACBE0 System.Environment.FailFast(System.String, System.Exception) [/_/src/runtime/src/coreclr/System.Private.CoreLib/src/System/Environment.CoreCLR.cs @ 67]
00007FFEAC2730C0 000076BC1EE91C11 Program.<Main>$(System.String[])
00007FFEAC275E80 000076bc9d3e23ce [SoftwareExceptionFrame: 00007ffeac275e80] 
00007FFEAC276C80 000076BC1EE91BDE Program.<Main>$(System.String[])

  ── Thread OSID 0x79  [running user code] ──
OS Thread Id: 0x79
        Child SP               IP Call Site
000076BC98489AE0 000076bc9d647d71 [InlinedCallFrame: 000076bc98489ae0] 
000076BC98489AE0 000076bc1e0aabb1 [InlinedCallFrame: 000076bc98489ae0] 
000076BC98489AD0 000076BC1E0AABB1 System.Threading.Thread.Sleep(Int32) [/_/src/runtime/src/libraries/System.Private.CoreLib/src/System/Threading/Thread.cs @ 381]
000076BC98489B70 000076BC1EE924F7 Program+<>c.<<Main>$>b__0_0()
000076BC98489B90 000076BC1E0A9B16 System.Threading.Thread.StartCallback()
000076BC98489D30 000076bc9d3e248c [DebuggerU2MCatchHandlerFrame: 000076bc98489d30] 
Exception object: 000076ad6ac00178
Exception type:   System.ExecutionEngineException
Message:          <none>
InnerException:   System.InvalidOperationException, Use printexception 000076AD6AEBBE88 to see more.
StackTrace (generated):
<none>
StackTraceString: <none>
HResult: 80131506
SyncBlocks to be cleaned up: 0
Free-Threaded Interfaces to be released: 0
MTA Interfaces to be released: 0
STA Interfaces to be released: 0
~~~

<a id="tri-heuristic-warnings"></a>
### Heuristic Warnings
_Automated red flags (deadlock/contention, thread-pool backlog, finalizer backlog, OOM). Hints, not conclusions._

~~~shell
▸ OutOfMemoryException detected — see eeheap -gc output below
~~~

<a id="tri-top-heap-types-dumpheap-stat-last-20-entries"></a>
### Top Heap Types (Dumpheap -Stat, Last 20 Entries)
_The largest managed types by total size — start here for memory-growth / leak triage._

~~~shell
76bc1f52ad80     1        24 System.Reflection.Internal.NativeHeapMemoryBlock+DisposableData
76bc1f48cf18     1        32 System.IO.FileStream
76bc1f034778     1        40 System.Gen2GcCallback
76bc1ef4a198     1        56 System.Runtime.CompilerServices.ConditionalWeakTable<System.Buffers.SharedArrayPoolThreadLocalArray[], System.Object>+Container
76bc1f0dc8d0     1        56 System.Runtime.CompilerServices.ConditionalWeakTable<System.Reflection.Assembly, System.Reflection.Metadata.MetadataReaderProvider>+Container
76bc1f521818     1        64 Microsoft.Win32.SafeHandles.SafeFileHandle
76bc1ef388f8     3        72 System.WeakReference<System.Diagnostics.Tracing.EventSource>
76bc1ef30848     4        96 System.WeakReference<System.Diagnostics.Tracing.EventProvider>
76bc1ee82238     2       144 System.Threading.Thread
76bc1ef2eb50     1       184 System.Diagnostics.Tracing.NativeRuntimeEventSource
76bc1ef4d100     1       184 System.Buffers.ArrayPoolEventSource
76bc1ef39ae8     1       400 System.Diagnostics.Tracing.RuntimeEventSource
76bc1ef30078     8       512 System.Diagnostics.Tracing.EventSource+OverrideEventProvider
~~~

<a id="sec-sos"></a>
## Full SOS output
_Raw dotnet-dump / SOS output, split per command — the authoritative detail._

<a id="cmd-session"></a>
### Session / symbol setup
_dotnet-dump startup: symbol-server settings and runtime/DAC resolution._

~~~shell
Loading core dump: /analysis/demo-core.dump ...
Current symbol store settings:
-> Cache: /analysis/symbols
-> Directory: /analysis
-> Cache: /root/.dotnet/symbolcache
-> Server: https://msdl.microsoft.com/download/symbols/ Timeout: 4 RetryCount: 3
Current symbol store settings:
-> Directory: /symbols-user
-> Cache: /analysis/symbols
-> Directory: /analysis
-> Cache: /root/.dotnet/symbolcache
-> Server: https://msdl.microsoft.com/download/symbols/ Timeout: 4 RetryCount: 3
~~~

<a id="cmd-runtimes"></a>
### `runtimes`
_The .NET runtime(s) found in the dump and the matched DAC._

~~~shell
#0 .NET Core runtime 10.0.826.23019 at 000076BC9CDE9000 size 006C9000 index fcf0ae82df5358546272813e24cce2178a41b1cc
    Runtime module path: /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/libcoreclr.so
    Libraries:
        Dac /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/libmscordaccore.so LINUX X64 Coreclr fcf0ae82df5358546272813e24cce2178a41b1cc
        Dbi libmscordbi.so LINUX X64 Coreclr fcf0ae82df5358546272813e24cce2178a41b1cc
        CDac /opt/bin/.store/dotnet-dump/9.0.661903/dotnet-dump/9.0.661903/tools/net8.0/any/libmscordaccore_universal.so LINUX X64 None fcf0ae82df5358546272813e24cce2178a41b1cc
    Exports:
        DotNetRuntimeInfo: <NO SYMBOL>
        g_dacTable: 000076BC9D4B3700
        DotNetRuntimeDebugHeader: <NO SYMBOL>
        DotNetRuntimeContractDescriptor: 000076BC9D48DED0
Settings:
-> Use CDAC contract reader: False
-> Force use CDAC contract reader: False
-> DAC signature verification check enabled: False
~~~

<a id="cmd-clrmodules"></a>
### `clrmodules`
_Managed modules (assemblies) loaded in the process._

~~~shell
000076BC1DE70000 00F2A000 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Private.CoreLib.dll
000076BC989B1000 00001600 /tmp/app/bin/Debug/net10.0/app.dll
000076BC989A6000 0000AF50 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Runtime.dll
000076BC1EF60000 00094200 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Collections.dll
000076BC9848B000 00003D28 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Threading.Thread.dll
000076BC1F0E0000 00056200 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Diagnostics.StackTrace.dll
000076BC1F140000 00165E00 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Reflection.Metadata.dll
000076BC1F2E0000 0013DE00 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Collections.Immutable.dll
000076BC1F420000 0005FA00 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Threading.dll
000076BC1F4A0000 00072C00 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Memory.dll
000076BC1F530000 00066A00 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Runtime.InteropServices.dll
000076BC95759000 00003D28 /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.8/System.Text.Encoding.Extensions.dll
~~~

<a id="cmd-clrthreads"></a>
### `clrthreads`
_All managed threads and state; the Exception column flags the faulting thread._

~~~shell
ThreadCount:      4
UnstartedThread:  0
BackgroundThread: 3
PendingThread:    0
DeadThread:       0
Hosted Runtime:   no
                                                                                                            Lock  
 DBG   ID     OSID ThreadOBJ           State GC Mode     GC Alloc Context                  Domain           Count Apt Exception
   0    1       72 00005723823484B0    20020 Preemptive  000076AD6AEC2750:000076AD6AEC2FF0 0000572382314B50 -00001 Ukn System.ExecutionEngineException 000076ad6ac00178
   5    2       77 000057238234AD90    21220 Preemptive  0000000000000000:0000000000000000 0000572382314B50 -00001 Ukn (Finalizer) 
   6    3       78 0000572382353430    21220 Preemptive  0000000000000000:0000000000000000 0000572382314B50 -00001 Ukn 
   7    4       79 000057238235AA30  2021220 Preemptive  0000000000000000:0000000000000000 0000572382314B50 -00001 Ukn 
~~~

<a id="cmd-parallelstacks"></a>
### `parallelstacks`
_Threads grouped by shared call paths — a compact map of what everything was doing._

~~~~~shell
________________________________________________
 ~~~~ 72
    1 System.Environment.FailFast(StackCrawlMarkHandle, String, ObjectHandleOnStack, String)
    1 System.Environment.FailFast(StackCrawlMark ByRef, String, Exception, String)
    1 System.Environment.FailFast(String, Exception)
    1 Program.<Main>$(String[])
    1 Program.<Main>$(String[])


________________________________________________
 ~~~~ 79
    1 System.Threading.Thread.Sleep(Int32)
    1 Program+<>c.<<Main>$>b__0_0()
    1 System.Threading.Thread.StartCallback()


==> 2 threads with 2 roots
~~~~~

<a id="cmd-clrstack-all"></a>
### `clrstack -all`
_Full managed call stack for every thread._

~~~shell
OS Thread Id: 0x72
        Child SP               IP Call Site
00007FFEAC273000 000076bc9d6bf813 [InlinedCallFrame: 00007ffeac273000] 
00007FFEAC273000 000076bc1dfaccae [InlinedCallFrame: 00007ffeac273000] 
00007FFEAC272FE0 000076BC1DFACCAE System.Environment.FailFast(System.Runtime.CompilerServices.StackCrawlMarkHandle, System.String, System.Runtime.CompilerServices.ObjectHandleOnStack, System.String) [/_/src/runtime/artifacts/obj/coreclr/System.Private.CoreLib/linux.x64.Release/generated/Microsoft.Interop.LibraryImportGenerator/Microsoft.Interop.LibraryImportGenerator/LibraryImports.g.cs @ 399]
00007FFEAC2730A0 000076BC1DFACC2F System.Environment.FailFast(System.Threading.StackCrawlMark ByRef, System.String, System.Exception, System.String) [/_/src/runtime/src/coreclr/System.Private.CoreLib/src/System/Environment.CoreCLR.cs @ 83]
00007FFEAC2730B0 000076BC1DFACBE0 System.Environment.FailFast(System.String, System.Exception) [/_/src/runtime/src/coreclr/System.Private.CoreLib/src/System/Environment.CoreCLR.cs @ 67]
00007FFEAC2730C0 000076BC1EE91C11 Program.<Main>$(System.String[])
00007FFEAC275E80 000076bc9d3e23ce [SoftwareExceptionFrame: 00007ffeac275e80] 
00007FFEAC276C80 000076BC1EE91BDE Program.<Main>$(System.String[])
OS Thread Id: 0x77
        Child SP               IP Call Site
000076BC9ACBED60 000076bc9d647d71 [DebuggerU2MCatchHandlerFrame: 000076bc9acbed60] 
OS Thread Id: 0x78
        Child SP               IP Call Site
000076BC991D0D60 000076bc9d647d71 [DebuggerU2MCatchHandlerFrame: 000076bc991d0d60] 
OS Thread Id: 0x79
        Child SP               IP Call Site
000076BC98489AE0 000076bc9d647d71 [InlinedCallFrame: 000076bc98489ae0] 
000076BC98489AE0 000076bc1e0aabb1 [InlinedCallFrame: 000076bc98489ae0] 
000076BC98489AD0 000076BC1E0AABB1 System.Threading.Thread.Sleep(Int32) [/_/src/runtime/src/libraries/System.Private.CoreLib/src/System/Threading/Thread.cs @ 381]
000076BC98489B70 000076BC1EE924F7 Program+<>c.<<Main>$>b__0_0()
000076BC98489B90 000076BC1E0A9B16 System.Threading.Thread.StartCallback()
000076BC98489D30 000076bc9d3e248c [DebuggerU2MCatchHandlerFrame: 000076bc98489d30] 
~~~

<a id="cmd-printexception-nested"></a>
### `printexception -nested`
_The current exception with its full InnerException chain and stack trace._

~~~shell
Exception object: 000076ad6ac00178
Exception type:   System.ExecutionEngineException
Message:          <none>
InnerException:   System.InvalidOperationException, Use printexception 000076AD6AEBBE88 to see more.
StackTrace (generated):
<none>
StackTraceString: <none>
HResult: 80131506
~~~

<a id="cmd-inner-exception-detail-level-1-000076ad6aebbe88"></a>
### Inner exception detail — level 1 - 000076AD6AEBBE88
_Expanded inner exception(s) the outer one wrapped (FailFast/AggregateException/rethrow) — the deepest is usually the real root cause._

~~~shell
Loading core dump: /analysis/demo-core.dump ...
Exception object: 000076ad6aebbe88
Exception type:   System.InvalidOperationException
Message:          simulated failure for the dotnet-sos demo dump
InnerException:   <none>
StackTrace (generated):
    SP               IP               Function
    00007FFEAC276C80 000076BC1EE91BDD app.dll!Program.<Main>$(System.String[])+0x37d

StackTraceString: <none>
HResult: 80131509
~~~

<a id="cmd-finalizequeue"></a>
### `finalizequeue`
_Objects awaiting finalization — a large backlog can mean a finalizer stall or leak._

~~~shell
SyncBlocks to be cleaned up: 0
Free-Threaded Interfaces to be released: 0
MTA Interfaces to be released: 0
STA Interfaces to be released: 0
----------------------------------

Heap 0
generation 0 has 0 objects (572382347990->572382347990)
generation 1 has 0 objects (572382347990->572382347990)
generation 2 has 0 objects (572382347990->572382347990)
Ready for finalization 0 objects (572382347a60->572382347a60)
------------------------------
Statistics for all finalizable objects (including all objects ready for finalization):
         Address               MT           Size
    76ad6ac08a90     76bc1ef2eb50            184 
    76ad6ac08d00     76bc1ef30078             64 
    76ad6ac08d68     76bc1ef30078             64 
    76ad6ac08de8     76bc1ef30848             24 
    76ad6ac08e48     76bc1ef388f8             24 
    76ad6ac08e60     76bc1ef39ae8            400 
    76ad6ac090b0     76bc1ef30078             64 
    76ad6ac09118     76bc1ef30078             64 
    76ad6ac09198     76bc1ef30848             24 
    76ad6ac091b0     76bc1ef388f8             24 
    76ad6ac09240     76bc1ef30078             64 
    76ad6ac09348     76bc1ef30078             64 
    76ad6ac093c8     76bc1ef30848             24 
    76ad6ac095a0     76bc1ef4a198             56 
    76ad6ac09798     76bc1ef4d100            184 
    76ad6ac09910     76bc1ef30078             64 
    76ad6ac09978     76bc1ef30078             64 
    76ad6ac099f8     76bc1ef30848             24 
    76ad6ac09a10     76bc1ef388f8             24 
    76ad6ac09f98     76bc1f034778             40 
    76ad6aebbd70     76bc1ee82238             72 
    76ad6aebbe18     76bc1ee82238             72 
    76ad6aebfa00     76bc1f0dc8d0             56 
    76ad6aec0600     76bc1f48cf18             32 
    76ad6aec0740     76bc1f521818             64 
    76ad6aec0880     76bc1f52ad80             24 

Statistics:
          MT Count TotalSize Class Name
76bc1f52ad80     1        24 System.Reflection.Internal.NativeHeapMemoryBlock+DisposableData
76bc1f48cf18     1        32 System.IO.FileStream
76bc1f034778     1        40 System.Gen2GcCallback
76bc1ef4a198     1        56 System.Runtime.CompilerServices.ConditionalWeakTable<System.Buffers.SharedArrayPoolThreadLocalArray[], System.Object>+Container
76bc1f0dc8d0     1        56 System.Runtime.CompilerServices.ConditionalWeakTable<System.Reflection.Assembly, System.Reflection.Metadata.MetadataReaderProvider>+Container
76bc1f521818     1        64 Microsoft.Win32.SafeHandles.SafeFileHandle
76bc1ef388f8     3        72 System.WeakReference<System.Diagnostics.Tracing.EventSource>
76bc1ef30848     4        96 System.WeakReference<System.Diagnostics.Tracing.EventProvider>
76bc1ee82238     2       144 System.Threading.Thread
76bc1ef2eb50     1       184 System.Diagnostics.Tracing.NativeRuntimeEventSource
76bc1ef4d100     1       184 System.Buffers.ArrayPoolEventSource
76bc1ef39ae8     1       400 System.Diagnostics.Tracing.RuntimeEventSource
76bc1ef30078     8       512 System.Diagnostics.Tracing.EventSource+OverrideEventProvider
Total 26 objects, 1,864 bytes
~~~

<a id="cmd-threadpool"></a>
### `threadpool`
_Thread-pool worker/IO counts and queued work — a backlog suggests pool starvation._

~~~shell
Failed to obtain ThreadPool data.
~~~

<a id="cmd-syncblk"></a>
### `syncblk`
_Monitor locks held/contended — the data for diagnosing managed deadlocks._

~~~shell
Index         SyncBlock MonitorHeld Recursion Owning Thread Info          SyncBlock Owner
-----------------------------
Total           0
Free            0

DATAS = 
========================================
~~~

<a id="cmd-eeheap-gc"></a>
### `eeheap -gc`
_GC heap segments and generation sizes — the overall managed-memory layout._

~~~shell
Number of GC Heaps: 1
----------------------------------------
Small object heap
         segment            begin        allocated        committed allocated size     committed size    
generation 0:
    76ad4ad7e250     76ad6ac00028     76ad6aec3008     76ad6aed1000 0x2c2fe0 (2895840) 0x2d1000 (2953216)
generation 1:
    76ad4ad7e1a8     76ad6a800028     76ad6a800028     76ad6a801000                    0x1000 (4096)     
generation 2:
    76ad4ad7e100     76ad6a400028     76ad6a400028     76ad6a401000                    0x1000 (4096)     
NonGC heap
         segment            begin        allocated        committed allocated size     committed size    
    57238234d110     76bc991e2008     76bc991e6540     76bc991f2000 0x4538 (17720)     0x10000 (65536)   
Large object heap
         segment            begin        allocated        committed allocated size     committed size    
    76ad4ad7e2f8     76ad6b000028     76ad6b000028     76ad6b001000                    0x1000 (4096)     
Pinned object heap
         segment            begin        allocated        committed allocated size     committed size    
    76ad4ad7dbc0     76ad68400028     76ad68402020     76ad68411000 0x1ff8 (8184)      0x11000 (69632)   
------------------------------
GC Allocated Heap Size:    Size: 0x2c9510 (2921744) bytes.
GC Committed Heap Size:    Size: 0x2f5000 (3100672) bytes.
~~~

<a id="cmd-dumpheap-stat"></a>
### `dumpheap -stat`
_Per-type managed object counts and total sizes across the whole heap._

~~~shell
Statistics:
          MT Count TotalSize Class Name
76bc1ef214d8     1        24 System.Collections.Generic.StringEqualityComparer
76bc1ef25130     1        24 System.OrdinalCaseSensitiveComparer
76bc1ef24730     1        24 System.Collections.Generic.NonRandomizedStringEqualityComparer+OrdinalIgnoreCaseComparer
76bc1ef25530     1        24 System.OrdinalIgnoreCaseComparer
76bc1f035880     1        24 System.Buffers.SharedArrayPool<System.Char>+<>c
76bc1ef47828     1        24 Program+<>c
76bc1f048708     1        24 System.Text.EncoderReplacementFallback
76bc1f0483b8     1        24 System.Text.DecoderReplacementFallback
76bc1f05d910     1        24 System.Reflection.Missing
76bc1f05da90     1        24 System.Type+<>c
76bc1f05e168     1        24 System.Resources.ResourceManager+ResourceManagerMediator
76bc1f05ddf8     1        24 System.Resources.ManifestBasedResourceGroveler
76bc1f0792d8     1        24 System.Resources.FastResourceComparer
76bc1f0dbcc8     1        24 System.Diagnostics.StackTraceSymbols
76bc1f2dbbe8     1        24 System.Collections.Immutable.ImmutableArray<System.Reflection.PortableExecutable.SectionHeader>
76bc1f2d5098     1        24 System.Collections.Immutable.ImmutableArray<System.Reflection.PortableExecutable.DebugDirectoryEntry>
76bc1f4855c8     1        24 System.Reflection.PortableExecutable.PEReader+<>c
76bc1f489070     1        24 System.Reflection.Metadata.MetadataStringDecoder
76bc1f52ad80     1        24 System.Reflection.Internal.NativeHeapMemoryBlock+DisposableData
76bc1f5a0068     1        24 System.Reflection.Internal.PooledStringBuilder+<>c__DisplayClass8_0
76bc1f5a9158     1        24 System.Collections.Generic.ObjectEqualityComparer<System.RuntimeType>
76bc1ee574e8     1        24 System.Int32
76bc1f07c028     1        24 System.Reflection.Metadata.TypeNameParseOptions
76bc1f07b0c0     1        25 System.Boolean[]
76bc1ef2a028     1        32 System.Collections.Generic.List<System.Char>
76bc1ef30a90     1        32 System.Diagnostics.Tracing.ActivityTracker
76bc1ef36bf0     1        32 System.Collections.Generic.List<System.Func<System.Diagnostics.Tracing.EventSource>>
76bc1ef389e8     1        32 System.Collections.Generic.List<System.WeakReference<System.Diagnostics.Tracing.EventSource>>
76bc1f05df00     1        32 System.Resources.ResourceManager+CultureNameResourceSetPair
76bc1f05f6f0     1        32 System.Resources.NeutralResourcesLanguageAttribute
76bc1f066bb8     1        32 System.Resources.NeutralResourcesLanguageAttribute[]
76bc1f07a7b0     1        32 System.Diagnostics.StackTrace
76bc1f2d7570     1        32 System.Reflection.Internal.ExternalMemoryBlockProvider
76bc1f480708     1        32 System.Collections.Immutable.ImmutableArray<System.Reflection.PortableExecutable.SectionHeader>+Builder
76bc1f484ee0     1        32 System.Collections.Immutable.ImmutableArray<System.Reflection.PortableExecutable.DebugDirectoryEntry>+Builder
76bc1f48cf18     1        32 System.IO.FileStream
76bc1f52aac0     1        32 System.Reflection.Internal.NativeHeapMemoryBlock
76bc1f5a04c0     1        32 System.Reflection.Internal.ObjectPool<System.Reflection.Internal.PooledStringBuilder>
76bc1f52ff20     1        32 System.Reflection.Internal.PooledStringBuilder
76bc1f5a0a40     1        32 System.Diagnostics.StackFrame[]
76bc1f5a2a90     1        32 System.Reflection.RuntimeMethodInfo[]
76bc1f5a9cc0     1        32 System.Reflection.ParameterInfo[]
76bc1ef48940     1        40 System.Buffers.SharedArrayPool<System.Char>
76bc1ef49500     1        40 System.Runtime.CompilerServices.ConditionalWeakTable<System.Buffers.SharedArrayPoolThreadLocalArray[], System.Object>
76bc1f034778     1        40 System.Gen2GcCallback
76bc1f0365b8     1        40 System.Threading.ExecutionContext
76bc1f0dc640     1        40 System.Runtime.CompilerServices.ConditionalWeakTable<System.Reflection.Assembly, System.Reflection.Metadata.MetadataReaderProvider>
76bc1f2dcb00     1        40 System.Reflection.PortableExecutable.CoffHeader
76bc1f52e618     1        40 System.Reflection.Metadata.DebugMetadataHeader
76bc1ef244d8     2        48 System.Collections.Generic.NonRandomizedStringEqualityComparer+OrdinalComparer
76bc1f047f28     1        48 System.Text.UTF8Encoding+UTF8EncodingSealed
76bc1f0dc588     1        48 System.Reflection.Metadata.MetadataReaderProvider
76bc1ef4a198     1        56 System.Runtime.CompilerServices.ConditionalWeakTable<System.Buffers.SharedArrayPoolThreadLocalArray[], System.Object>+Container
76bc1f0dc8d0     1        56 System.Runtime.CompilerServices.ConditionalWeakTable<System.Reflection.Assembly, System.Reflection.Metadata.MetadataReaderProvider>+Container
76bc1f522130     1        56 System.RuntimeType+ActivatorCache
76bc1f5237e8     1        56 System.Reflection.Internal.StreamMemoryBlockProvider
76bc1f52d688     1        56 System.Reflection.Metadata.Ecma335.NamespaceCache
76bc1f07ac18     1        56 System.Diagnostics.StackFrame
76bc1f5a28a0     1        56 System.RuntimeType+RuntimeTypeCache+MemberInfoCache<System.Reflection.RuntimeMethodInfo>
76bc1ef44270     2        64 System.Collections.Generic.List<System.String>
76bc1f034ba0     1        64 System.Func<System.Object, System.Boolean>
76bc1ef47d60     1        64 System.Threading.ThreadStart
76bc1f035ec0     1        64 System.Threading.Thread+StartHelper
76bc1f045b10     1        64 System.Resources.RuntimeResourceSet
76bc1f0cdbf8     2        64 System.Version
76bc1f2d7248     1        64 System.Reflection.PortableExecutable.PEReader
76bc1f2d0e40     1        64 System.Func<System.String, System.IO.Stream>
76bc1f2d77d0     1        64 System.Func<System.Reflection.PortableExecutable.DebugDirectoryEntry, System.Boolean>
76bc1f520898     1        64 System.IO.Strategies.UnixFileStreamStrategy
76bc1f521818     1        64 Microsoft.Win32.SafeHandles.SafeFileHandle
76bc1f5a00f8     1        64 System.Func<System.Reflection.Internal.PooledStringBuilder>
76bc1f5a6338     1        64 System.Collections.Generic.HashSet<System.RuntimeType>
76bc1f5a9008     2        64 System.RuntimeType[]
76bc1ef278a8     2        64 System.Guid
76bc1ef2ed30     3        72 System.Diagnostics.Tracing.TraceLoggingEventHandleTable
76bc1ef388f8     3        72 System.WeakReference<System.Diagnostics.Tracing.EventSource>
76bc1f036b30     1        72 System.SByte[]
76bc1f2dc338     1        72 System.Reflection.PortableExecutable.PEHeaders
76bc1f48fa18     1        72 System.IO.Strategies.BufferedFileStreamStrategy
76bc1ee8a910     1        80 System.Collections.Generic.Dictionary<System.String, System.Object>
76bc1ef2bbd8     1        80 System.Collections.Generic.Dictionary<System.Char, System.String>
76bc1ef376d8     2        80 System.Func<System.Diagnostics.Tracing.EventSource>[]
76bc1ef32220     1        80 System.Collections.Generic.Dictionary<System.Guid, System.Diagnostics.Tracing.EventSource+OverrideEventProvider>
76bc1ef30d20     1        80 System.Collections.Generic.Dictionary<System.String, System.Diagnostics.Tracing.EventSource+OverrideEventProvider>
76bc1ef45e50     1        80 System.Collections.Generic.Dictionary<System.Int32, System.Byte[]>
76bc1f038608     2        80 System.Reflection.RuntimeModule
76bc1f05e1e0     1        80 System.Collections.Generic.Dictionary<System.String, System.Resources.ResourceSet>
76bc1f06c268     1        80 System.Collections.Generic.Dictionary<System.String, System.Globalization.CultureInfo>
76bc1f06e088     1        80 System.Collections.Generic.Dictionary<System.String, System.Globalization.CultureData>
76bc1f06f2e8     2        80 System.Resources.ResourceFallbackManager
76bc1f078278     1        80 System.Collections.Generic.Dictionary<System.String, System.Resources.ResourceLocator>
76bc1f095a08     1        80 System.Buffers.AsciiCharSearchValues<System.Buffers.IndexOfAnyAsciiSearcher+Default, System.Buffers.SearchValues+FalseConst>
76bc1f5a9b20     1        80 System.Signature
76bc1f0710f8     1        88 System.IO.UnmanagedMemoryStream
76bc1f2dce50     1        88 System.Reflection.PortableExecutable.CorHeader
76bc1f5a3720     1        88 System.Reflection.RuntimeParameterInfo
76bc1ef30848     4        96 System.WeakReference<System.Diagnostics.Tracing.EventProvider>
76bc1ef38f78     2        96 System.WeakReference<System.Diagnostics.Tracing.EventSource>[]
76bc1ef41870     1        96 System.Collections.Generic.Dictionary<System.String, System.Diagnostics.Tracing.EventSource+OverrideEventProvider>+Entry[]
76bc1f044cd0     1        96 System.Resources.ResourceManager
76bc1f06ed98     1        96 System.Collections.Generic.Dictionary<System.String, System.Globalization.CultureData>+Entry[]
76bc1f06f058     1        96 System.Collections.Generic.Dictionary<System.String, System.Globalization.CultureInfo>+Entry[]
76bc1f0715e8     1        96 System.Reflection.RuntimeAssembly+ManifestResourceStream
76bc1f0796d8     1        96 System.Collections.Generic.Dictionary<System.String, System.Resources.ResourceSet>+Entry[]
76bc1f5a17c8     1       104 System.Reflection.RuntimeMethodInfo
76bc1ee808c8     1       120 System.OutOfMemoryException
76bc1ee809f0     1       120 System.StackOverflowException
76bc1ee80b18     1       120 System.ExecutionEngineException
76bc1ef415a0     1       120 System.Collections.Generic.Dictionary<System.Guid, System.Diagnostics.Tracing.EventSource+OverrideEventProvider>+Entry[]
76bc1ef47ec0     1       120 System.InvalidOperationException
76bc1f2dc708     3       120 System.Reflection.Internal.ExternalMemoryBlock
76bc1f485248     2       120 System.Reflection.PortableExecutable.DebugDirectoryEntry[]
76bc1f52dc80     1       120 System.Reflection.Metadata.Ecma335.StreamHeader[]
76bc1f0454d8     1       128 System.Resources.ResourceReader
76bc1f0cccd8     2       128 System.Reflection.Metadata.AssemblyNameInfo
76bc1ee82238     2       144 System.Threading.Thread
76bc1f03a3f8     3       144 System.Reflection.RuntimeAssembly
76bc1f06f730     3       144 System.Resources.ResourceFallbackManager+<GetEnumerator>d__5
76bc1f2d95e0     3       144 System.Text.StringBuilder
76bc1ef4a8e0     1       152 System.Runtime.CompilerServices.ConditionalWeakTable<System.Buffers.SharedArrayPoolThreadLocalArray[], System.Object>+Entry[]
76bc1f07afc0     1       152 System.Diagnostics.StackFrameHelper
76bc1f0dcaa8     1       152 System.Runtime.CompilerServices.ConditionalWeakTable<System.Reflection.Assembly, System.Reflection.Metadata.MetadataReaderProvider>+Entry[]
76bc1ef2f1e8     4       160 System.Diagnostics.Tracing.EventProviderImpl
76bc1f0d9ef8     2       160 System.Reflection.AssemblyName
76bc1f046180     3       168 System.IO.BinaryReader
76bc1f481bd8     2       168 System.Reflection.PortableExecutable.SectionHeader[]
76bc1f07c888     2       176 System.Reflection.Metadata.TypeName
76bc1ef2eb50     1       184 System.Diagnostics.Tracing.NativeRuntimeEventSource
76bc1ef4d100     1       184 System.Buffers.ArrayPoolEventSource
76bc1de547b0     8       192 System.Object
76bc1f05d7e8     4       192 System.Type[]
76bc1f05d480     3       192 System.Reflection.MemberFilter
76bc1f062728     2       192 System.RuntimeMethodInfoStub
76bc1f5a94c0     1       200 System.Collections.Generic.HashSet<System.RuntimeType>+Entry[]
76bc1ef4abd8     1       240 System.Buffers.SharedArrayPoolPartitions[]
76bc1f2dd910     1       248 System.Reflection.PortableExecutable.PEHeader
76bc1ef28160     4       256 System.Func<System.Diagnostics.Tracing.EventSource>
76bc1ef2f9c8     4       256 System.Diagnostics.Tracing.EventPipeEventProvider
76bc1f5a07a8     1       280 System.Reflection.Internal.ObjectPool<System.Reflection.Internal.PooledStringBuilder>+Element[]
76bc1ee8fea0     1       288 System.Collections.Generic.Dictionary<System.String, System.Object>+Entry[]
76bc1ef2cfc0     2       288 System.Collections.Generic.Dictionary<System.Char, System.String>+Entry[]
76bc1ee5afa0    12       288 System.Char
76bc1f0d0c48     1       312 System.Globalization.NumberFormatInfo
76bc1f07a190     2       368 System.Collections.Generic.Dictionary<System.String, System.Resources.ResourceLocator>+Entry[]
76bc1ef39ae8     1       400 System.Diagnostics.Tracing.RuntimeEventSource
76bc1ef2ede8     6       408 System.IntPtr[]
76bc1ef48f20     1       456 System.Buffers.SharedArrayPoolThreadLocalArray[]
76bc1ef30078     8       512 System.Diagnostics.Tracing.EventSource+OverrideEventProvider
76bc1f061768     1       552 System.Reflection.CustomAttributeRecord[]
76bc1f06aac8     5       560 System.Globalization.CultureInfo
76bc1f037638     5       840 System.RuntimeType+RuntimeTypeCache
76bc1f06df88     2       896 System.Globalization.CultureData
76bc1ef2cb20     9     1,376 System.Char[]
76bc1de5a088    58     2,320 System.RuntimeType
76bc1f52a8b0     1     2,352 System.Reflection.Metadata.MetadataReader
572382314230   340     8,160 Free
76bc1ee522d8     6     8,424 System.Object[]
76bc1ee7b158    38    14,560 System.Int32[]
76bc1f035b68     7    18,912 System.Collections.Generic.Dictionary<System.Int32, System.Byte[]>+Entry[]
76bc1ef439b8    21   131,720 System.String[]
76bc1ee7dd58 8,360 1,022,672 System.String
76bc1ef44e50   406 1,648,204 System.Byte[]
Total 9,486 objects, 2,876,109 bytes
~~~

<a id="cmd-analyzeoom"></a>
### `analyzeoom`
_Whether a managed out-of-memory occurred and the allocation that triggered it._

~~~shell
There was no managed OOM due to allocations on the GC heap
~~~
