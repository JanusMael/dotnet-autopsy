// trace/TraceTriage/Program.cs — the dotnet-autopsy/trace report tool.
// (Phase E migration of the former trace/trace_triage.cs file-based app.)
//
// Companion to triage_summary.cs but for `dotnet-trace` captures. Reads the
// RAW assembled by analyze-trace.sh (the `dotnet-trace report topN` text
// output plus a small kv-header) and emits a '─'×60 sectioned triage block
// + '═'×60 marker that common/analysis_md.cs consumes via the TRACE_PROFILE.
//
// Invoked by /opt/analyze-trace.sh:
//   trace_triage RAW RUNTIME ARCH FIDELITY TOOL BUILD_TS [SPEEDSCOPE] [NETTRACE]
//
// argv[6] (optional): path to the `dotnet-trace convert --format speedscope`
//                     JSON — read BCL-only via System.Text.Json for
//                     sample_count + duration_ms.
// argv[7] (optional): path to the original `.nettrace` — when present, walk
//                     the EventPipe stream via TraceEvent for the v1.1
//                     "depth" sections: runtime_version, GC SUMMARY,
//                     EXCEPTION COUNTS. When absent (parity fixtures) the
//                     depth sections are simply omitted, so the BCL-only
//                     baseline stays byte-identical for parity goldens.
//
// Stdout is pristine: UTF-8 without BOM, explicit '\n', invariant culture,
// a single final write. Exit 0 ok / nonzero on error (analyze-trace.sh has
// the `|| { warn; echo "(trace triage unavailable)" }` fallback).
//
// NOTE: this is the FIRST and ONLY dotnet-autopsy report tool that depends
// on a NuGet (Microsoft.Diagnostics.Tracing.TraceEvent). Sos's
// triage_summary remains BCL-only file-based. See trace/TraceTriage.csproj
// and RUNBOOK "Extending the report tools".

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Diagnostics.Tracing;

namespace DotnetAutopsy.Trace;

static class Program
{
    const RegexOptions O = RegexOptions.CultureInvariant;

    static readonly Regex TopHeaderRx = new(@"\ATop\s+\d+\s+Functions\s+\(Exclusive\)", O);
    static readonly Regex TopRowRx = new(@"\A\s*(\d+)\.\s+(.+?)\s+(\d+(?:\.\d+)?%)\s+(\d+(?:\.\d+)?%)\s*\z", O);
    static readonly Regex KvRx = new(@"\A(trace_\w+)\s*:\s*(.+?)\s*\z", O);

    public static int Main(string[] argv)
    {
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

        // Probe mode: `trace_triage --probe-runtime <nettrace>` prints the
        // .NET runtime version on stdout (one line) and exits. Used by
        // analyze-trace.sh to learn the version BEFORE writing
        // provenance.txt, so the rendered H1 reflects the real version
        // instead of "unknown". Best-effort: empty stdout + exit 0 if the
        // .nettrace can't be parsed (caller handles fallback).
        if (argv.Length >= 2 && argv[0] == "--probe-runtime")
        {
            var probed = ReadDepth(argv[1]);
            if (probed.Has && probed.RuntimeVersion.Length > 0)
            {
                var po = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))
                    { NewLine = "\n", AutoFlush = false };
                po.Write(probed.RuntimeVersion);
                po.Write("\n");
                po.Flush();
            }
            return 0;
        }

        if (argv.Length < 6)
        {
            Console.Error.Write("(trace triage unavailable — insufficient arguments)\n");
            return 1;
        }
        string rawFile  = argv[0];
        string runtime  = argv[1];
        string tarch    = argv[2];
        string fidelity = argv[3];
        string tool     = argv[4];
        string buildTs  = argv[5];
        string ssPath   = argv.Length >= 7 ? argv[6] : "";
        string ntPath   = argv.Length >= 8 ? argv[7] : "";

        string raw;
        try
        {
            byte[] bytes = File.ReadAllBytes(rawFile);
            raw = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (Exception e)
        {
            Console.Error.Write("(trace triage unavailable — " + e.Message + ")\n");
            return 1;
        }

        List<string> lines = PySplitlines(raw);

        // ── Parse top-N CPU rows + optional kv header ─────────────────────
        var rows = new List<(int rank, string fn, string incl, string excl)>();
        var kv = new Dictionary<string, string>(StringComparer.Ordinal);
        bool inTop = false;
        foreach (string line in lines)
        {
            Match km = KvRx.Match(line);
            if (km.Success) kv[km.Groups[1].Value] = PyStrip(km.Groups[2].Value);

            if (!inTop)
            {
                if (TopHeaderRx.IsMatch(line)) inTop = true;
                continue;
            }
            Match m = TopRowRx.Match(line);
            if (m.Success)
            {
                rows.Add((int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture),
                          PyStrip(m.Groups[2].Value),
                          m.Groups[3].Value,
                          m.Groups[4].Value));
            }
            else if (PyStrip(line).Length == 0 && rows.Count > 0)
            {
                inTop = false;
            }
        }

        // ── (optional) TraceEvent depth from the binary .nettrace ─────────
        // When argv[7] is supplied AND the file parses cleanly, walk the
        // EventPipe stream for runtime_version, GC pause stats and
        // exception throw counts. Best-effort: any failure leaves depth
        // sections OMITTED — output then matches the BCL-only baseline
        // (parity gate's deterministic mode).
        Depth d = (ntPath.Length > 0 && File.Exists(ntPath))
            ? ReadDepth(ntPath)
            : new Depth();
        if (d.RuntimeVersion.Length > 0 && (runtime.Length == 0 || runtime == "unknown"))
            runtime = d.RuntimeVersion;

        // ── TOP CPU FUNCTIONS ─────────────────────────────────────────────
        string topCpu;
        if (rows.Count > 0)
        {
            var sb = new StringBuilder();
            int width = 0;
            foreach (var r in rows) if (r.fn.Length > width) width = r.fn.Length;
            if (width > 80) width = 80;
            foreach (var r in rows)
            {
                string fn = r.fn.Length <= width ? r.fn : (r.fn.Substring(0, width - 1) + "…");
                sb.Append("  ").Append(r.rank.ToString(CultureInfo.InvariantCulture).PadLeft(2))
                  .Append(". ").Append(fn.PadRight(width))
                  .Append("  incl=").Append(r.incl.PadLeft(7))
                  .Append("  excl=").Append(r.excl.PadLeft(7))
                  .Append('\n');
            }
            topCpu = sb.ToString().TrimEnd('\n');
        }
        else
        {
            topCpu = "(no CPU sample rows parsed — check the dotnet-trace report output below)";
        }

        // ── TRACE METADATA (kv-header + speedscope JSON) ──────────────────
        var md = new StringBuilder();
        string Kv(string k) => kv.TryGetValue(k, out var v) ? v : "";
        string path = Kv("trace_file_path");
        string size = Kv("trace_file_size");
        string sc   = Kv("trace_sample_count");
        string durM = Kv("trace_duration_ms");
        if (sc.Length == 0 || durM.Length == 0)
        {
            var (ssSc, ssDur) = ReadSpeedscopeMeta(ssPath);
            if (sc.Length   == 0 && ssSc.Length  > 0) sc   = ssSc;
            if (durM.Length == 0 && ssDur.Length > 0) durM = ssDur;
        }
        if (path.Length > 0) md.Append("  Trace file    : ").Append(path).Append('\n');
        if (size.Length > 0) md.Append("  File size     : ").Append(size).Append(" bytes\n");
        if (sc.Length   > 0) md.Append("  Sample count  : ").Append(sc).Append('\n');
        if (durM.Length > 0) md.Append("  Duration      : ").Append(durM).Append(" ms\n");
        string traceMeta = md.Length > 0
            ? md.ToString().TrimEnd('\n')
            : "(no trace metadata recorded — analyze-trace.sh did not embed a kv header)";

        // ── HEURISTIC WARNINGS (unchanged from v1.0) ──────────────────────
        var hints = new List<string>();
        if (rows.Count > 0)
        {
            double Pct(string p)
            {
                string n = p.EndsWith("%", StringComparison.Ordinal) ? p[..^1] : p;
                return double.TryParse(n, NumberStyles.Float, CultureInfo.InvariantCulture, out var x) ? x : 0.0;
            }
            double top1 = Pct(rows[0].excl);
            if (top1 > 50.0)
                hints.Add("Single-function hotspot: " + rows[0].fn + " at " + rows[0].excl + " exclusive CPU");
            double top3 = 0.0;
            for (int i = 0; i < Math.Min(3, rows.Count); i++) top3 += Pct(rows[i].excl);
            if (top3 > 80.0)
                hints.Add("Highly concentrated CPU: top 3 functions = "
                          + top3.ToString("F2", CultureInfo.InvariantCulture) + "% exclusive");
        }
        else
        {
            hints.Add("No CPU sample rows parsed — trace may be empty / wrong profile (need cpu-sampling)");
        }
        if (d.Has && d.MaxGcPauseMs > 200.0)
            hints.Add("Long GC pause: " + d.MaxGcPauseMs.ToString("F1", CultureInfo.InvariantCulture)
                     + " ms (gen0=" + d.Gen0Count + " gen1=" + d.Gen1Count + " gen2=" + d.Gen2Count + ")");
        if (d.Has && d.ExceptionCounts.Count > 0)
        {
            int totalExc = d.ExceptionCounts.Values.Sum();
            if (totalExc > 100)
                hints.Add("High exception throw rate: " + totalExc + " throws across "
                         + d.ExceptionCounts.Count + " distinct types");
        }
        var hb = new List<string>();
        foreach (string h in hints) hb.Add("  ▸ " + h);
        string hintsText = hb.Count > 0 ? string.Join("\n", hb) : "  None detected";

        // ── (optional) GC SUMMARY + EXCEPTION COUNTS — depth path only ────
        string gcSummary = "";
        string excCounts = "";
        if (d.Has)
        {
            var gb = new StringBuilder();
            gb.Append("  Gen 0 / Gen 1 / Gen 2 : ").Append(d.Gen0Count).Append(" / ")
              .Append(d.Gen1Count).Append(" / ").Append(d.Gen2Count).Append('\n');
            gb.Append("  Total GC pause time   : ")
              .Append(d.TotalGcPauseMs.ToString("F1", CultureInfo.InvariantCulture)).Append(" ms\n");
            gb.Append("  Max single GC pause   : ")
              .Append(d.MaxGcPauseMs.ToString("F1", CultureInfo.InvariantCulture)).Append(" ms");
            gcSummary = gb.ToString();

            if (d.ExceptionCounts.Count > 0)
            {
                var top = d.ExceptionCounts.OrderByDescending(p => p.Value).Take(10).ToList();
                int wType = top.Max(p => p.Key.Length);
                if (wType > 70) wType = 70;
                var eb = new StringBuilder();
                foreach (var (type, n) in top)
                {
                    string t = type.Length <= wType ? type : (type[..(wType - 1)] + "…");
                    eb.Append("  ").Append(t.PadRight(wType))
                      .Append("  ").Append(n.ToString(CultureInfo.InvariantCulture).PadLeft(6))
                      .Append('\n');
                }
                excCounts = eb.ToString().TrimEnd('\n');
            }
            else
            {
                excCounts = "  (no exceptions thrown during the captured window)";
            }
        }

        // ── Assemble (same structural contract as triage_summary.cs) ──────
        string bar60dash = new string('─', 60);
        string bar60eq   = new string('═', 60);

        string Section(string title, string body)
        {
            // Right-strip ONLY — preserve the per-row 2-space indent
            // (same fix as Hotfix d58d598 / triage_summary.cs). Whitespace-
            // only body falls back to "(not available)".
            string b = body ?? "";
            if (PyStrip(b).Length == 0)
                b = "(not available)";
            else
            {
                int e = b.Length;
                while (e > 0 && PySpace(b[e - 1])) e--;
                b = b.Substring(0, e);
            }
            return "\n" + bar60dash + "\n  " + title + "\n" + bar60dash + "\n" + b + "\n";
        }

        var outp = new List<string>
        {
            "╔═════════════════════════════════════════════════════════╗",
            "║       DOTNET-AUTOPSY · TRACE  AUTO-TRIAGE  SUMMARY      ║",
            "╚═════════════════════════════════════════════════════════╝",
            "  Runtime      : " + runtime,
            "  Trace arch   : " + tarch,
            "  Trace fidelity: " + fidelity,
            "  Tool         : " + tool,
            "  Build time   : " + buildTs,
            Section("TOP CPU FUNCTIONS", topCpu),
            Section("TRACE METADATA", traceMeta),
        };
        // Depth sections OMITTED entirely when not in depth mode → BCL-only
        // baseline stays byte-identical for parity goldens (which never pass
        // a .nettrace argv).
        if (d.Has)
        {
            outp.Add(Section("GC SUMMARY", gcSummary));
            outp.Add(Section("EXCEPTION COUNTS (top 10)", excCounts));
        }
        outp.Add(Section("HEURISTIC WARNINGS", hintsText));
        outp.AddRange(new[]
        {
            "",
            bar60eq,
            "  FULL TRACE OUTPUT FOLLOWS",
            bar60eq,
            "",
        });

        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))
        {
            NewLine = "\n",
            AutoFlush = false,
        };
        stdout.Write(string.Join("\n", outp));
        stdout.Write("\n");
        stdout.Flush();
        return 0;
    }

    // ── TraceEvent depth — runtime_version + GC + exception counts ─────────
    // EventPipe stream walking via Microsoft.Diagnostics.Tracing.TraceEvent.
    // Best-effort: any exception leaves d.Has=false → all depth sections
    // omitted; the BCL-only baseline is the deterministic fallback.
    sealed class Depth
    {
        public bool Has;                           // true iff Process() ran cleanly
        public string RuntimeVersion = "";
        public int Gen0Count, Gen1Count, Gen2Count;
        public double TotalGcPauseMs;
        public double MaxGcPauseMs;
        public Dictionary<string, int> ExceptionCounts = new(StringComparer.Ordinal);
    }

    static Depth ReadDepth(string nettracePath)
    {
        var d = new Depth();
        try
        {
            // GCStart/GCStop pairing by (ProcessID, Count); for a single-
            // process EventPipe trace, Count alone is unique.
            var openGc = new Dictionary<int, (double ms, int depth)>();

            using var source = new EventPipeEventSource(nettracePath);

            source.Clr.GCStart += e =>
            {
                openGc[e.Count] = (e.TimeStampRelativeMSec, e.Depth);
            };
            source.Clr.GCStop += e =>
            {
                if (openGc.TryGetValue(e.Count, out var s))
                {
                    double pause = e.TimeStampRelativeMSec - s.ms;
                    if (s.depth == 0) d.Gen0Count++;
                    else if (s.depth == 1) d.Gen1Count++;
                    else if (s.depth >= 2) d.Gen2Count++;
                    d.TotalGcPauseMs += pause;
                    if (pause > d.MaxGcPauseMs) d.MaxGcPauseMs = pause;
                    openGc.Remove(e.Count);
                }
            };

            source.Clr.ExceptionStart += e =>
            {
                string t = !string.IsNullOrEmpty(e.ExceptionType) ? e.ExceptionType : "(unknown)";
                d.ExceptionCounts[t] = d.ExceptionCounts.TryGetValue(t, out var n) ? n + 1 : 1;
            };

            // Runtime version: emitted via the CLR rundown's RuntimeStart
            // event (DCStart variant for rundown / non-DCStart for live).
            // Capture either; the rundown one is what `dotnet-trace collect`
            // bakes at the trace's tail.
            source.Clr.RuntimeStart += e =>
            {
                string ver = e.VMMajorVersion + "." + e.VMMinorVersion + "."
                           + e.VMBuildNumber  + "." + e.VMQfeNumber;
                if (d.RuntimeVersion.Length == 0) d.RuntimeVersion = ver;
            };

            source.Process();
            d.Has = true;
        }
        catch
        {
            // Best-effort; leave d.Has=false → depth sections omitted.
        }
        return d;
    }

    // Read sample_count + duration_ms from a speedscope JSON file.
    static (string sampleCount, string durationMs) ReadSpeedscopeMeta(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return ("", "");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
            var root = doc.RootElement;
            if (!root.TryGetProperty("profiles", out var profs)
                || profs.ValueKind != JsonValueKind.Array
                || profs.GetArrayLength() == 0)
                return ("", "");
            var p = profs[0];
            string sc = "";
            if (p.TryGetProperty("samples", out var samples)
                && samples.ValueKind == JsonValueKind.Array)
                sc = samples.GetArrayLength().ToString(CultureInfo.InvariantCulture);
            else if (p.TryGetProperty("events", out var events_)
                && events_.ValueKind == JsonValueKind.Array)
                sc = ((events_.GetArrayLength() + 1) / 2)
                     .ToString(CultureInfo.InvariantCulture);
            string dur = "";
            if (p.TryGetProperty("startValue", out var sv)
                && p.TryGetProperty("endValue",   out var ev)
                && sv.ValueKind == JsonValueKind.Number
                && ev.ValueKind == JsonValueKind.Number)
            {
                double span = ev.GetDouble() - sv.GetDouble();
                string unit = p.TryGetProperty("unit", out var u)
                              ? (u.GetString() ?? "") : "";
                double ms = unit switch
                {
                    "microseconds" => span / 1000.0,
                    "nanoseconds"  => span / 1_000_000.0,
                    "seconds"      => span * 1000.0,
                    _              => span,
                };
                dur = ((long)Math.Round(ms)).ToString(CultureInfo.InvariantCulture);
            }
            return (sc, dur);
        }
        catch (IOException)   { return ("", ""); }
        catch (JsonException) { return ("", ""); }
    }

    // CPython str semantics — verbatim from triage_summary.cs / former trace_triage.cs.
    static bool PySpace(char c) => char.IsWhiteSpace(c) || ((int)c >= 0x1c && (int)c <= 0x1f);

    static string PyStrip(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && PySpace(s[a])) a++;
        while (b > a && PySpace(s[b - 1])) b--;
        return s.Substring(a, b - a);
    }

    static List<string> PySplitlines(string s)
    {
        var res = new List<string>();
        var sb = new StringBuilder();
        int i = 0, n = s.Length;
        while (i < n)
        {
            char c = s[i];
            if (c == '\r')
            {
                res.Add(sb.ToString()); sb.Clear(); i++;
                if (i < n && s[i] == '\n') i++;
                continue;
            }
            int u = c;
            if (c == '\n' || c == '\v' || c == '\f'
                || u == 0x1c || u == 0x1d || u == 0x1e
                || u == 0x85 || u == 0x2028 || u == 0x2029)
            {
                res.Add(sb.ToString()); sb.Clear(); i++;
                continue;
            }
            sb.Append(c); i++;
        }
        if (sb.Length > 0) res.Add(sb.ToString());
        return res;
    }
}
