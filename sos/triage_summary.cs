// triage_summary.cs - .NET 10 file-based app (BCL only).
//
// Byte-for-byte port of triage_summary.py. Parses raw SOS/dotnet-dump output
// and emits the human-friendly triage summary section. Invoked by analyze.sh:
//
//   triage_summary RAW_FILE RUNTIME DUMP_ARCH FIDELITY DAC_SOURCE BUILD_TS
//
// Output is concatenated RAW into the authoritative analysis.txt, so stdout
// MUST be pristine: UTF-8 without BOM, explicit '\n', invariant culture,
// a single final write. Exit 0 on success; nonzero on error (analyze.sh has
// the `|| { warn; echo "(triage summary unavailable)" }` fallback).
//
// Parity discipline: every Python `re.match` is start-anchored, so its
// pattern is ported with a leading `\A` (.NET Regex.Match is unanchored;
// `re.search` ports to a plain Match). Python `str.strip()`/`.splitlines()`
// are reimplemented (PyStrip/PySplitlines) to match CPython exactly. Numeric
// gates use BigInteger to mirror Python arbitrary-precision int(). ALL
// non-ASCII output is written via \uXXXX escapes so the source stays pure
// ASCII while the emitted bytes match the Python literals exactly.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;

return Triage.Run(args);

static class Triage
{
    const RegexOptions O = RegexOptions.CultureInvariant;

    static readonly Regex ObjRx   = new(@"Exception object:\s*([0-9A-Fa-fx]+)", O);
    static readonly Regex MsgRx   = new(@"\A\s*Message\s*:", O);
    static readonly Regex InnerRx = new(@"InnerException:\s*(.+)", O);
    static readonly Regex ExcRx   = new(@"\b([A-Za-z_][\w.]*Exception)\b", O);
    static readonly Regex RowRx   = new(@"\A\s*[0-9A-Fa-fx]+\s+\d+\s+([0-9A-Fa-f]+)\s+[0-9A-Fa-f]", O);
    static readonly Regex ThrEndRx= new(@"\A(?:\s*_{6,}|\s*OS Thread Id:)", O);
    static readonly Regex OsidRx  = new(@"OS Thread Id:\s*0x([0-9A-Fa-f]+)", O);
    // [─═] == Python [BOX-DRAWINGS-LIGHT/DOUBLE-HORIZONTAL]; regular
    // (non-verbatim) string so \u escapes resolve and source stays ASCII.
    static readonly Regex BarRx   = new("\\A\\s*[─═]{6,}", O);
    static readonly Regex FrameRx = new(@"\A\s*[0-9A-Fa-f]{6,}\s+[0-9A-Fa-f]{6,}\s+(\S.*)$", O);
    static readonly Regex SysRx   = new(@"\A(?:System|Microsoft|Internal|Interop)\.", O);
    static readonly Regex MtRx    = new(@"\A\s*MT\s+Count\s+TotalSize\s+Class", O);
    static readonly Regex TotalRx = new(@"\A\s*Total\s+\d+", O);
    static readonly Regex QueueRx = new(@"Queue Length\s*:\s*(\d+)", O);
    static readonly Regex FinRx   = new(@"Finalizable objects.*?:\s*(\d+)", O | RegexOptions.IgnoreCase);
    static readonly Regex OomRx   = new(@"OutOfMemoryException|out of memory", O | RegexOptions.IgnoreCase);

    const string EMDASH = "—";   // -
    const string BULLET = "▸";   // >

    public static int Run(string[] argv)
    {
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

        if (argv.Length < 6)
        {
            Console.Error.Write("(triage summary unavailable " + EMDASH + " insufficient arguments)\n");
            return 1;
        }
        string rawFile  = argv[0];
        string runtime  = argv[1];
        string darch    = argv[2];
        string fidelity = argv[3];
        string dacSrc   = argv[4];
        string buildTs  = argv[5];

        string raw;
        try
        {
            byte[] bytes = File.ReadAllBytes(rawFile);
            raw = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (Exception e)
        {
            Console.Error.Write("(triage summary unavailable " + EMDASH + " " + e.Message + ")\n");
            return 1;
        }

        List<string> lines = PySplitlines(raw);

        // -- Exception chain ------------------------------------------------
        var chain = new List<(string obj, string type, string msg)>();
        var seenObjs = new HashSet<string>(StringComparer.Ordinal);
        string pendingType = null;
        string pendingObj = null;
        string unexpandedInner = "";
        foreach (string line in lines)
        {
            Match mObj = ObjRx.Match(line);
            if (mObj.Success)
                pendingObj = mObj.Groups[1].Value;

            if (line.Contains("Exception type:", StringComparison.Ordinal))
            {
                int ix = line.IndexOf("Exception type:", StringComparison.Ordinal);
                pendingType = PyStrip(line.Substring(ix + "Exception type:".Length));
            }
            else if (pendingType != null && MsgRx.IsMatch(line))
            {
                int c = line.IndexOf(':');
                string msg = PyStrip(c < 0 ? line : line.Substring(c + 1));
                bool hasObj = !string.IsNullOrEmpty(pendingObj);
                if (!(hasObj && seenObjs.Contains(pendingObj)))
                {
                    if (hasObj) seenObjs.Add(pendingObj);
                    chain.Add((pendingObj, pendingType, msg));
                }
                pendingType = null;
                pendingObj = null;
            }

            Match mInner = InnerRx.Match(line);
            if (mInner.Success && mInner.Groups[1].Value.Contains("Use printexception", StringComparison.Ordinal))
                unexpandedInner = PyStrip(mInner.Groups[1].Value);
        }

        string M(string v) => (!string.IsNullOrEmpty(v) && v != "<none>") ? v : "(none)";
        string Ob(string a) => !string.IsNullOrEmpty(a) ? "  [" + a + "]" : "";

        string excText = "";
        if (chain.Count > 0)
        {
            var (o0, t0, m0) = chain[0];
            excText = "  Type    : " + t0 + Ob(o0) + "\n  Message : " + M(m0);
            for (int i = 1; i < chain.Count; i++)
            {
                var (oi, t, m) = chain[i];
                string tag = (i == chain.Count - 1) ? "  (likely root cause)" : "";
                excText += "\n  ── inner #" + i + ": " + t + Ob(oi) + tag
                         + "\n     Message : " + M(m);
            }
            if (chain.Count == 1 && unexpandedInner.Length > 0)
                excText += "\n  Inner   : " + unexpandedInner + "  (not auto-expanded)";
        }
        else if (unexpandedInner.Length > 0)
        {
            excText = "  Inner   : " + unexpandedInner;
        }

        // -- clrthreads rows + the faulting thread --------------------------
        string faultThread = "";
        string faultOsid = null;
        bool inThreads = false;
        foreach (string line in lines)
        {
            if (line.Contains("ThreadCount:", StringComparison.Ordinal))
            {
                inThreads = true;
                continue;
            }
            if (inThreads)
            {
                if (PyStrip(line).Length == 0 || ThrEndRx.IsMatch(line))
                {
                    inThreads = false;
                    continue;
                }
                Match m = RowRx.Match(line);
                if (m.Success && ExcRx.IsMatch(line) && string.IsNullOrEmpty(faultOsid))
                {
                    string s = m.Groups[1].Value.ToLowerInvariant().TrimStart('0');
                    faultOsid = s.Length == 0 ? "0" : s;
                    faultThread = PyStrip(line);
                }
            }
        }

        // -- clrstack -all -> per-thread frame blocks (keyed by OSID) -------
        var blocks = new List<(string osid, List<string> body)>();
        string curOsid = null;
        var cur = new List<string>();
        foreach (string line in lines)
        {
            Match m = OsidRx.Match(line);
            if (m.Success)
            {
                if (curOsid != null)
                    blocks.Add((curOsid, cur));
                string s = m.Groups[1].Value.ToLowerInvariant().TrimStart('0');
                curOsid = s.Length == 0 ? "0" : s;
                cur = new List<string> { line };
            }
            else if (curOsid != null)
            {
                if (BarRx.IsMatch(line) || PyStrip(line) == "FULL SOS OUTPUT FOLLOWS")
                {
                    blocks.Add((curOsid, cur));
                    curOsid = null;
                    cur = new List<string>();
                }
                else
                {
                    cur.Add(line);
                }
            }
        }
        if (curOsid != null)
            blocks.Add((curOsid, cur));

        const int FRAME_CAP = 25;
        const int MAX_USER_THREADS = 4;

        string FmtBlock(string osid, List<string> blk, string tag)
        {
            List<string> body;
            if (blk.Count > FRAME_CAP + 1)
            {
                body = new List<string>(blk.GetRange(0, FRAME_CAP));
                body.Add("  ... (stack truncated to " + FRAME_CAP + " frames)");
            }
            else
            {
                body = blk.GetRange(0, Math.Min(blk.Count, FRAME_CAP + 1));
            }
            return "  ── Thread OSID 0x" + osid + "  [" + tag + "] ──\n"
                   + string.Join("\n", body);
        }

        var stackChunks = new List<string>();
        var used = new HashSet<string>(StringComparer.Ordinal);

        List<string> faultBlk = null;
        if (!string.IsNullOrEmpty(faultOsid))
        {
            foreach (var (o, b) in blocks)
                if (o == faultOsid) { faultBlk = b; break; }
        }
        if (faultBlk != null)
        {
            stackChunks.Add(FmtBlock(faultOsid, faultBlk, "FAULTING THREAD"));
            used.Add(faultOsid);
        }
        int cap = (faultBlk != null) ? 1 + MAX_USER_THREADS : MAX_USER_THREADS + 1;
        foreach (var (osid, blk) in blocks)
        {
            if (stackChunks.Count >= cap) break;
            if (used.Contains(osid)) continue;
            if (HasUserCode(blk))
            {
                stackChunks.Add(FmtBlock(osid, blk, "running user code"));
                used.Add(osid);
            }
        }
        if (!string.IsNullOrEmpty(faultOsid) && faultBlk == null)
        {
            stackChunks.Insert(0, "  (faulting thread OSID 0x" + faultOsid + " had no "
                                  + "managed stack " + EMDASH + " see clrthreads / clrstack below)");
        }
        string stacksTitle = (faultBlk != null)
            ? "FAULTING & USER-CODE CALL STACKS"
            : "USER-CODE CALL STACKS";

        // -- Top heap types (from dumpheap -stat) ---------------------------
        var heapLines = new List<string>();
        bool inHeap = false;
        foreach (string line in lines)
        {
            if (MtRx.IsMatch(line))
            {
                inHeap = true;
                continue;
            }
            if (inHeap)
            {
                if (TotalRx.IsMatch(line) || PyStrip(line).Length == 0)
                    break;
                heapLines.Add(line);
            }
        }
        string topHeap = heapLines.Count > 0
            ? string.Join("\n", heapLines.GetRange(
                  Math.Max(0, heapLines.Count - 20),
                  Math.Min(20, heapLines.Count)))
            : "(managed heap not available)";

        // -- Heuristic warnings ---------------------------------------------
        var hints = new List<string>();

        int syncblkWaits = 0;
        foreach (string l in lines)
            if (l.Contains("OwnedBy", StringComparison.Ordinal) || l.Contains("Waiting", StringComparison.Ordinal))
                syncblkWaits++;
        if (syncblkWaits > 3)
            hints.Add("Potential deadlock/contention: " + syncblkWaits + " lock-wait entries in syncblk");

        foreach (string line in lines)
        {
            Match m = QueueRx.Match(line);
            if (m.Success && BigInteger.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) > 100)
            {
                hints.Add("ThreadPool queue backlog: " + m.Groups[1].Value + " items pending");
                break;
            }
        }

        bool finalizerWarned = false;
        foreach (string line in lines)
        {
            Match m = FinRx.Match(line);
            if (m.Success && BigInteger.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) > 1000 && !finalizerWarned)
            {
                hints.Add("Finalizer backlog: " + m.Groups[1].Value + " objects awaiting finalization");
                finalizerWarned = true;
            }
        }

        bool oomWarned = false;
        foreach (string line in lines)
        {
            if (OomRx.IsMatch(line) && !oomWarned)
            {
                hints.Add("OutOfMemoryException detected " + EMDASH + " see eeheap -gc output below");
                oomWarned = true;
                break;
            }
        }

        string hintsText;
        if (hints.Count > 0)
        {
            var hb = new List<string>();
            foreach (string h in hints) hb.Add("  " + BULLET + " " + h);
            hintsText = string.Join("\n", hb);
        }
        else
        {
            hintsText = "  None detected";
        }

        // -- Assemble -------------------------------------------------------
        string bar60dash = new string('─', 60);
        string bar60eq   = new string('═', 60);

        string Section(string title, string body)
        {
            // Right-strip ONLY — the body's leading whitespace is the
            // per-row 2-space indent (e.g. "  Type    : …" / "  ▸ hint" /
            // "  ── Thread OSID …"). A both-sided strip (Python original
            // + original .NET port) lops off the FIRST row's indent only
            // and leaves all subsequent rows indented, producing the
            // misaligned column-0 first row visible in rendered reports.
            // Whitespace-only body still falls back to "(not available)".
            string b = body ?? "";
            if (PyStrip(b).Length == 0)
            {
                b = "(not available)";
            }
            else
            {
                int e = b.Length;
                while (e > 0 && PySpace(b[e - 1])) e--;
                b = b.Substring(0, e);
            }
            return "\n" + bar60dash + "\n  " + title + "\n" + bar60dash + "\n" + b + "\n";
        }

        string boxTop = "╔" + new string('═', 58) + "╗";
        string boxMid = "║          DOTNET-SOS  AUTO-TRIAGE  SUMMARY               ║";
        string boxBot = "╚" + new string('═', 58) + "╝";

        var outp = new List<string>
        {
            boxTop,
            boxMid,
            boxBot,
            "  Runtime      : " + runtime,
            "  Dump arch    : " + darch,
            "  Dump fidelity: " + fidelity,
            "  DAC source   : " + dacSrc,
            "  Build time   : " + buildTs,
            Section("TOP EXCEPTION", excText),
            Section("FAULTING THREAD (clrthreads)",
                faultThread.Length > 0 ? faultThread : "(no managed exception found " + EMDASH + " see clrthreads below)"),
            Section(stacksTitle,
                stackChunks.Count > 0
                    ? string.Join("\n\n", stackChunks)
                    : "(no managed call stacks recovered " + EMDASH + " see clrstack -all below)"),
            Section("HEURISTIC WARNINGS", hintsText),
            Section("TOP HEAP TYPES (dumpheap -stat, last 20 entries)", topHeap),
            "",
            bar60eq,
            "  FULL SOS OUTPUT FOLLOWS",
            bar60eq,
            "",
        };

        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))
        {
            NewLine = "\n",
            AutoFlush = false,
        };
        stdout.Write(string.Join("\n", outp));
        stdout.Write("\n");                       // Python print() trailing newline
        stdout.Flush();
        return 0;
    }

    // A managed frame whose call site is NOT System.*/Microsoft.* and is not
    // an infra pseudo-frame ([InlinedCallFrame], [DebuggerU2M...]).
    static bool HasUserCode(List<string> blk)
    {
        foreach (string ln in blk)
        {
            Match mm = FrameRx.Match(ln);
            if (!mm.Success) continue;
            string site = PyStrip(mm.Groups[1].Value);
            if (site.StartsWith("[", StringComparison.Ordinal)
                || site.StartsWith("Child SP", StringComparison.Ordinal))
                continue;
            if (SysRx.IsMatch(site))
                continue;
            return true;
        }
        return false;
    }

    // CPython str.isspace() superset used by str.strip(): Char.IsWhiteSpace
    // plus the C0 separators U+001C..U+001F (.NET does NOT treat them as
    // whitespace; CPython does). Integer compares keep the source ASCII.
    static bool PySpace(char c)
    {
        int u = c;
        return char.IsWhiteSpace(c) || (u >= 0x1c && u <= 0x1f);
    }

    static string PyStrip(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && PySpace(s[a])) a++;
        while (b > a && PySpace(s[b - 1])) b--;
        return s.Substring(a, b - a);
    }

    // CPython str.splitlines() line boundaries: \n \r \r\n \v \f U+001C
    // U+001D U+001E U+0085 U+2028 U+2029 (U+001F is whitespace for strip()
    // but NOT a splitlines boundary). Breaks excluded; a trailing break does
    // NOT yield a final empty element; "" -> []. Integer compares only.
    static List<string> PySplitlines(string s)
    {
        var res = new List<string>();
        var sb = new StringBuilder();
        int i = 0, n = s.Length;
        while (i < n)
        {
            char ch = s[i];
            if (ch == '\r')
            {
                res.Add(sb.ToString()); sb.Clear(); i++;
                if (i < n && s[i] == '\n') i++;
                continue;
            }
            int u = ch;
            if (u == 0x0a || u == 0x0b || u == 0x0c
                || u == 0x1c || u == 0x1d || u == 0x1e
                || u == 0x85 || u == 0x2028 || u == 0x2029)
            {
                res.Add(sb.ToString()); sb.Clear(); i++;
                continue;
            }
            sb.Append(ch); i++;
        }
        if (sb.Length > 0) res.Add(sb.ToString());
        return res;
    }
}
