// gcdump_triage.cs - .NET 10 file-based app (BCL only).
//
// Triage parser for `dotnet-gcdump report <file>` text output. Sibling of
// triage_summary (dump) and trace_triage (trace) — emits the same '─'×60
// sectioned triage block + '═'×60 marker that common/analysis_md.cs
// consumes via the GCDUMP_PROFILE.
//
// Invoked by /opt/analyze-gcdump.sh:
//   gcdump_triage RAW RUNTIME ARCH FIDELITY TOOL BUILD_TS
//
// v1 scope (BCL-only): parse dotnet-gcdump's report header + type rows →
// HEAP SUMMARY + TOP TYPES BY SIZE + HEURISTIC WARNINGS. No TraceEvent
// dependency (the .gcdump is a heap snapshot; the text report dotnet-gcdump
// emits is already authoritative for the top-types view this image
// surfaces).
//
// Stdout is pristine: UTF-8 without BOM, explicit '\n', invariant culture,
// a single final write. Exit 0 ok / nonzero on error (analyze-gcdump.sh has
// the `|| { warn; echo "(gcdump triage unavailable)" }` fallback).

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

return GcdumpTriage.Run(args);

static class GcdumpTriage
{
    const RegexOptions O = RegexOptions.CultureInvariant;

    // Header lines emitted by `dotnet-gcdump report`:
    //   "     21,711,918  GC Heap bytes"
    //   "         19,766  GC Heap objects"
    static readonly Regex HeapBytesRx   = new(@"\A\s*([\d,]+)\s+GC Heap bytes\s*\z", O);
    static readonly Regex HeapObjectsRx = new(@"\A\s*([\d,]+)\s+GC Heap objects\s*\z", O);

    // Column header (identifies the start of the type table):
    //   "   Object Bytes     Count  Type"
    static readonly Regex TypeHeaderRx = new(@"\A\s*Object\s+Bytes\s+Count\s+Type\s*\z", O);

    // Type row:
    //   "        202,080         1  Entry<System.Int32,System.String>[] (Bytes > 100K)  [System.Private.CoreLib.dll]"
    // Capture: bytes (with commas), count, type+bucket+module (everything else, stripped).
    static readonly Regex TypeRowRx = new(@"\A\s*([\d,]+)\s+([\d,]+)\s+(\S.*?)\s*\z", O);

    public static int Run(string[] argv)
    {
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

        if (argv.Length < 6)
        {
            Console.Error.Write("(gcdump triage unavailable — insufficient arguments)\n");
            return 1;
        }
        string rawFile  = argv[0];
        string runtime  = argv[1];
        string garch    = argv[2];
        string fidelity = argv[3];
        string tool     = argv[4];
        string buildTs  = argv[5];

        string raw;
        try
        {
            byte[] bytes = File.ReadAllBytes(rawFile);
            raw = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (Exception e)
        {
            Console.Error.Write("(gcdump triage unavailable — " + e.Message + ")\n");
            return 1;
        }

        var lines = PySplitlines(raw);

        // ── Parse heap header + type rows ─────────────────────────────────
        string heapBytes = "";
        string heapObjects = "";
        var rows = new List<(long bytes, long count, string type)>();
        bool inTypes = false;
        foreach (string line in lines)
        {
            var hb = HeapBytesRx.Match(line);
            if (hb.Success) { heapBytes = hb.Groups[1].Value; continue; }
            var ho = HeapObjectsRx.Match(line);
            if (ho.Success) { heapObjects = ho.Groups[1].Value; continue; }
            if (!inTypes)
            {
                if (TypeHeaderRx.IsMatch(line)) inTypes = true;
                continue;
            }
            // In types table; stop on blank line.
            if (PyStrip(line).Length == 0) { inTypes = false; continue; }
            var r = TypeRowRx.Match(line);
            if (r.Success)
            {
                if (long.TryParse(r.Groups[1].Value.Replace(",", ""),
                                  NumberStyles.Integer, CultureInfo.InvariantCulture, out long b)
                 && long.TryParse(r.Groups[2].Value.Replace(",", ""),
                                  NumberStyles.Integer, CultureInfo.InvariantCulture, out long c))
                {
                    rows.Add((b, c, PyStrip(r.Groups[3].Value)));
                }
            }
        }

        // ── HEAP SUMMARY ──────────────────────────────────────────────────
        var hb_ = new StringBuilder();
        if (heapBytes.Length > 0)   hb_.Append("  GC Heap bytes     : ").Append(heapBytes).Append('\n');
        if (heapObjects.Length > 0) hb_.Append("  GC Heap objects   : ").Append(heapObjects).Append('\n');
        hb_.Append("  Types reported    : ").Append(rows.Count.ToString(CultureInfo.InvariantCulture));
        string heapSummary = hb_.ToString();

        // ── TOP TYPES BY SIZE (top 25; dotnet-gcdump emits descending) ────
        string topTypes;
        if (rows.Count > 0)
        {
            int take = Math.Min(25, rows.Count);
            int width = 0;
            for (int i = 0; i < take; i++)
                if (rows[i].type.Length > width) width = rows[i].type.Length;
            if (width > 80) width = 80;

            var sb = new StringBuilder();
            for (int i = 0; i < take; i++)
            {
                var r = rows[i];
                string t = r.type.Length <= width ? r.type : (r.type.Substring(0, width - 1) + "…");
                sb.Append("  ").Append((i + 1).ToString(CultureInfo.InvariantCulture).PadLeft(2))
                  .Append(". ").Append(t.PadRight(width))
                  .Append("  bytes=").Append(r.bytes.ToString("N0", CultureInfo.InvariantCulture).PadLeft(13))
                  .Append("  count=").Append(r.count.ToString("N0", CultureInfo.InvariantCulture).PadLeft(10))
                  .Append('\n');
            }
            topTypes = sb.ToString().TrimEnd('\n');
        }
        else
        {
            topTypes = "(no type rows parsed — check the dotnet-gcdump report output below)";
        }

        // ── HEURISTIC WARNINGS ────────────────────────────────────────────
        var hints = new List<string>();
        if (rows.Count > 0)
        {
            long total = 0;
            for (int i = 0; i < rows.Count; i++) total += rows[i].bytes;
            // Single type dominating > 50% of the heap.
            if (rows[0].bytes * 2 > total && total > 0)
                hints.Add("Single-type heap dominator: " + rows[0].type
                        + " holds " + rows[0].bytes.ToString("N0", CultureInfo.InvariantCulture)
                        + " bytes (" + (rows[0].bytes * 100.0 / total).ToString("F1", CultureInfo.InvariantCulture)
                        + "% of the reported heap)");

            // Look for known "smelly" type patterns in top 5.
            int n = Math.Min(5, rows.Count);
            for (int i = 0; i < n; i++)
            {
                string t = rows[i].type;
                if ((t.StartsWith("System.String", StringComparison.Ordinal) ||
                     t.StartsWith("System.Char", StringComparison.Ordinal))
                    && rows[i].bytes > 1_000_000)
                    hints.Add("Large string footprint in top-5: " + t
                            + " at " + rows[i].bytes.ToString("N0", CultureInfo.InvariantCulture)
                            + " bytes (check for unbounded caches, log accumulation, interned strings)");
                if (t.StartsWith("System.Byte[]", StringComparison.Ordinal)
                    && rows[i].bytes > 5_000_000)
                    hints.Add("Large byte-buffer footprint in top-5: " + t
                            + " at " + rows[i].bytes.ToString("N0", CultureInfo.InvariantCulture)
                            + " bytes (likely buffered I/O / unflushed pool / serializer cache)");
            }
        }
        else
        {
            hints.Add("No type rows parsed — gcdump may be empty/corrupt or dotnet-gcdump report failed");
        }
        var hb2 = new List<string>();
        foreach (string h in hints) hb2.Add("  ▸ " + h);
        string hintsText = hb2.Count > 0 ? string.Join("\n", hb2) : "  None detected";

        // ── Assemble (same structural contract as triage_summary.cs) ──────
        string bar60dash = new string('─', 60);
        string bar60eq   = new string('═', 60);

        string Section(string title, string body)
        {
            // Right-strip only — preserve per-row 2-space indent (matches
            // the Hotfix d58d598 fix in the sibling triage tools).
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
            "║      DOTNET-AUTOPSY · GCDUMP  AUTO-TRIAGE  SUMMARY      ║",
            "╚═════════════════════════════════════════════════════════╝",
            "  Runtime      : " + runtime,
            "  Gcdump arch  : " + garch,
            "  Gcdump fidelity: " + fidelity,
            "  Tool         : " + tool,
            "  Build time   : " + buildTs,
            Section("HEAP SUMMARY", heapSummary),
            Section("TOP TYPES BY SIZE", topTypes),
            Section("HEURISTIC WARNINGS", hintsText),
            "",
            bar60eq,
            "  FULL GCDUMP OUTPUT FOLLOWS",
            bar60eq,
            "",
        };

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

    // CPython str semantics — verbatim from the sibling triage apps.
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
