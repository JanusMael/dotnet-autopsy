// analysis_md.cs - .NET 10 file-based app (BCL only).
//
// Byte-for-byte port of analysis_md.py: render the assembled analysis.txt as
// a navigable Markdown view (analysis.md). Pure post-processor; analysis.txt
// stays the authoritative raw source. SECURITY: the file server's Markdig
// renderer does NOT sanitize HTML and analysis.txt embeds dump-derived
// strings, so EVERY dump/SOS-derived body is emitted inside a fenced block
// (Fence() lengthens the ~ run so content cannot break out) - ported
// verbatim. Never crashes the caller: any parse problem -> single fenced
// fallback document; ALWAYS exit 0 (usage/read errors exit 1, handled by
// analyze.sh's `&& [ -s ]` gate).
//
// Usage:  analysis_md <analysis.txt> [status.json] > analysis.md
//
// Parity discipline: Python `re.match` is start-anchored -> ported with a
// leading `\A`; `re.search` -> plain Match. Python str.strip()/.rstrip()/
// .strip(ch)/.title()/.lower() reimplemented (PyStrip/PyRStrip/StripChars/
// PyTitle/ToLowerInvariant) to match CPython. Stable sort mirrors Python
// sorted(). raw is decoded with UTF-8 replacement (Python errors="replace").
// All non-ASCII is written via \uXXXX so the source stays pure ASCII while
// emitted bytes match the Python literals exactly.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

return AnalysisMd.Main2(args);

static class AnalysisMd
{
    const RegexOptions O = RegexOptions.CultureInvariant;

    // ─ = box light horizontal (also '-'); ═ = box double
    // horizontal (also '='); — = em dash; ⚠ = warning sign;
    // · = middle dot.
    static readonly Regex BAR_DASH = new("\\A\\s*[─-]{20,}\\s*$", O);
    static readonly Regex BAR_DEQ  = new("\\A\\s*[═=]{20,}\\s*$", O);
    static readonly Regex PROV_KV  = new(@"\A([A-Za-z][\w.\-]*)\s{2,}:\s?(.*)$", O);
    // ── Per-image renderer profile ──────────────────────────────────────────
    // The shared renderer used to assume SOS output unconditionally (one
    // hardcoded end-of-triage marker; one hardcoded per-command anchor
    // table). With the dotnet-autopsy/trace sibling, the trace report has a
    // different marker and only 2 commands — falling back to a single fenced
    // block. So the marker + anchor table become a per-image `Profile`,
    // selected by the `report_tool` field in provenance.
    //
    // SOS profile is the DEFAULT (anything other than a known sibling), so
    // the sos image's bytes are preserved when nothing else matches; the
    // GOLDEN parity gate proves that invariant.
    sealed record Profile(string Marker, string FullOutputTitle,
                          (string label, Regex rx)[] Anchors, int MinSplit);

    static readonly Profile SOS_PROFILE = new Profile(
        "FULL SOS OUTPUT FOLLOWS",
        "Full SOS output",
        new (string, Regex)[]
        {
            ("runtimes",               new Regex(@"^#?\d*\s*\.NET (Core )?runtime|^Loaded runtimes:", O)),
            ("clrmodules",             new Regex(@"^[0-9A-Fa-f]{12,16}\s+[0-9A-Fa-f]{4,8}\s+/", O)),
            ("clrthreads",             new Regex(@"^ThreadCount:", O)),
            ("parallelstacks",         new Regex(@"^_{8,}\s*$|^==>\s+\d+\s+threads? with", O)),
            ("clrstack -all",          new Regex(@"^OS Thread Id:\s*0x", O)),
            ("printexception -nested", new Regex(@"^Exception object:|^There is no current managed exception", O)),
            ("finalizequeue",          new Regex(@"^SyncBlocks to be cleaned up:", O)),
            ("threadpool",             new Regex(@"^(Failed to obtain ThreadPool data\.|CPU utilization:|Work Request in Queue:|Number of Timers:|Using Portable thread pool)", O)),
            ("syncblk",                new Regex(@"^Index\s+SyncBlock\b", O)),
            ("eeheap -gc",             new Regex(@"^Number of GC Heaps:", O)),
            ("dumpheap -stat",         new Regex(@"^Statistics:\s*$", O)),
            ("analyzeoom",             new Regex(@"managed OOM", O | RegexOptions.IgnoreCase)),
        },
        MinSplit: 5);

    // Trace profile — analyze-trace.sh writes section banners
    // `=== dotnet-trace report topN -n N ===` and
    // `=== dotnet-trace convert --format speedscope ===` into RAW; we anchor
    // on those. Threshold 2 because trace has 2 commands (vs sos's 12).
    static readonly Profile TRACE_PROFILE = new Profile(
        "FULL TRACE OUTPUT FOLLOWS",
        "Full trace output",
        new (string, Regex)[]
        {
            ("dotnet-trace report topN",        new Regex(@"^=== dotnet-trace report\b", O)),
            ("dotnet-trace convert speedscope", new Regex(@"^=== dotnet-trace convert\b", O)),
        },
        MinSplit: 2);

    // Gcdump RAW: analyze-gcdump.sh writes a kv-header + one section banner
    // `=== dotnet-gcdump report ===` into RAW. One anchor, threshold 1.
    static readonly Profile GCDUMP_PROFILE = new Profile(
        "FULL GCDUMP OUTPUT FOLLOWS",
        "Full gcdump output",
        new (string, Regex)[]
        {
            ("dotnet-gcdump report", new Regex(@"^=== dotnet-gcdump report\b", O)),
        },
        MinSplit: 1);

    static Profile SelectProfile(string reportTool) => reportTool switch
    {
        "dotnet-trace"  => TRACE_PROFILE,
        "dotnet-gcdump" => GCDUMP_PROFILE,
        _               => SOS_PROFILE,    // dotnet-dump and anything else
    };

    // Must match entrypoint.sh `--root <FILES_DIR> --route analysis`; the
    // rendered page is served at /view?path=analysis.md so sibling links
    // must be route-absolute.
    const string SERVE_BASE = "/analysis";

    static readonly Dictionary<string, string> DESCRIPTIONS = new(StringComparer.Ordinal)
    {
        ["provenance"] = "How this image was built — pin these via --build-arg to reproduce the exact analysis environment.",
        ["analysis degraded"] = "The dump could not be fully analyzed — what failed and how to capture a usable one.",
        ["auto-triage summary"] = "A synthesized at-a-glance read of the crash; the full raw SOS detail follows below.",
        ["full sos output"] = "Raw dotnet-dump / SOS output, split per command — the authoritative detail.",
        ["analysis output"] = "Raw analyzer output (the dump was not the expected structured form).",
        ["top exception"] = "The fatal managed exception (type, message, inner chain) — usually the proximate cause.",
        ["faulting thread"] = "The managed thread that carried the exception — its clrthreads row.",
        ["call stacks"] = "Managed call stacks: the faulting thread first, then threads running your app's code (framework/infra-only threads are omitted).",
        ["heuristic warnings"] = "Automated red flags (deadlock/contention, thread-pool backlog, finalizer backlog, OOM). Hints, not conclusions.",
        ["top heap types"] = "The largest managed types by total size — start here for memory-growth / leak triage.",
        ["session"] = "dotnet-dump startup: symbol-server settings and runtime/DAC resolution.",
        ["runtimes"] = "The .NET runtime(s) found in the dump and the matched DAC.",
        ["clrmodules"] = "Managed modules (assemblies) loaded in the process.",
        ["clrthreads"] = "All managed threads and state; the Exception column flags the faulting thread.",
        ["parallelstacks"] = "Threads grouped by shared call paths — a compact map of what everything was doing.",
        ["clrstack -all"] = "Full managed call stack for every thread.",
        ["printexception -nested"] = "The current exception with its full InnerException chain and stack trace.",
        ["finalizequeue"] = "Objects awaiting finalization — a large backlog can mean a finalizer stall or leak.",
        ["threadpool"] = "Thread-pool worker/IO counts and queued work — a backlog suggests pool starvation.",
        ["syncblk"] = "Monitor locks held/contended — the data for diagnosing managed deadlocks.",
        ["eeheap -gc"] = "GC heap segments and generation sizes — the overall managed-memory layout.",
        ["dumpheap -stat"] = "Per-type managed object counts and total sizes across the whole heap.",
        ["analyzeoom"] = "Whether a managed out-of-memory occurred and the allocation that triggered it.",
        ["inner exception detail"] = "Expanded inner exception(s) the outer one wrapped (FailFast/AggregateException/rethrow) — the deepest is usually the real root cause.",
    };

    static string Desc(string title)
    {
        string t = ToLowerInv(StripChars(PyStrip(title), '`'));
        t = PyStrip(t.Replace("⚠", ""));
        if (DESCRIPTIONS.TryGetValue(t, out string d)) return d;
        if (t.Contains("call stack", StringComparison.Ordinal)) return DESCRIPTIONS["call stacks"];
        if (t.StartsWith("faulting thread", StringComparison.Ordinal)) return DESCRIPTIONS["faulting thread"];
        if (t.StartsWith("top heap types", StringComparison.Ordinal)) return DESCRIPTIONS["top heap types"];
        if (t.StartsWith("analysis degraded", StringComparison.Ordinal) || t.Contains("degraded", StringComparison.Ordinal))
            return DESCRIPTIONS["analysis degraded"];
        if (t == "session / symbol setup" || t == "session/symbol setup") return DESCRIPTIONS["session"];
        if (t.StartsWith("inner exception detail", StringComparison.Ordinal)) return DESCRIPTIONS["inner exception detail"];
        return "";
    }

    static string Fence(string body, string lang = "shell")
    {
        int longest = 0;
        foreach (string ln in body.Split('\n'))
        {
            Match m = Regex.Match(ln, @"\A\s{0,3}(~+)", O);
            if (m.Success) longest = Math.Max(longest, m.Groups[1].Value.Length);
        }
        string bar = new string('~', Math.Max(3, longest + 1));
        return bar + lang + "\n" + StripChars(body, '\n') + "\n" + bar;
    }

    static string Slug(string s)
    {
        string r = StripChars(Regex.Replace(ToLowerInv(s), "[^a-z0-9]+", "-", O), '-');
        return r.Length > 0 ? r : "x";
    }

    static string Anchor(string s) => "<a id=\"" + s + "\"></a>";

    public static int Main2(string[] argv)
    {
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

        if (argv.Length < 1)
        {
            Console.Error.Write("usage: analysis_md <analysis.txt> [status.json]\n");
            return 1;
        }
        string raw;
        try
        {
            byte[] bytes = File.ReadAllBytes(argv[0]);
            // Python open(..., errors="replace"): invalid bytes -> U+FFFD.
            raw = new UTF8Encoding(false).GetString(bytes);
        }
        catch (Exception e)
        {
            Console.Error.Write("cannot read " + argv[0] + ": " + e.Message + "\n");
            return 1;
        }
        string statusPath = argv.Length > 1 ? argv[1] : null;

        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))
        {
            NewLine = "\n",
            AutoFlush = false,
        };
        try
        {
            stdout.Write(Render(raw, statusPath));
        }
        catch                                   // never fail the caller
        {
            stdout.Write(Fallback(raw));
        }
        stdout.Flush();
        return 0;
    }

    static string Render(string raw, string statusPath)
    {
        List<string> lines = new List<string>(raw.Split('\n'));

        int s = 0;
        while (s < lines.Count && PyStrip(lines[s]).Length == 0) s++;
        var provLines = new List<string>();
        int restStart = 0;
        if (s < lines.Count && lines[s].StartsWith("# Provenance", StringComparison.Ordinal))
        {
            int j = s;
            while (j < lines.Count && (lines[j].StartsWith("#", StringComparison.Ordinal)
                                       || PROV_KV.IsMatch(lines[j])
                                       || PyStrip(lines[j]).Length == 0))
                j++;
            provLines = lines.GetRange(0, j);
            restStart = j;
        }
        List<string> rest = lines.GetRange(restStart, lines.Count - restStart);

        // Compute meta + profile EARLY so the marker scan + downstream
        // splitting use the per-image (SOS / TRACE) profile selected by
        // report_tool. (Order matters: provLines is built above, then meta
        // → profile, then we scan for the per-profile marker.)
        var meta = Meta(provLines, statusPath);
        var profile = SelectProfile(meta.tool);

        int iBox = -1;
        for (int i = 0; i < rest.Count; i++)
            if (rest[i].StartsWith("╔", StringComparison.Ordinal)) { iBox = i; break; }
        int iFull = -1;
        for (int i = 0; i < rest.Count; i++)
            if (PyStrip(rest[i]) == profile.Marker) { iFull = i; break; }

        var lowfi = new List<string>();
        int segEnd = iBox >= 0 ? iBox : rest.Count;
        bool anyDeg = false;
        for (int i = 0; i < segEnd; i++)
            if (rest[i].Contains("ANALYSIS DEGRADED", StringComparison.Ordinal)) { anyDeg = true; break; }
        if (anyDeg)
            for (int i = 0; i < segEnd; i++)
                if (PyStrip(rest[i]).Length != 0) lowfi.Add(rest[i]);

        if (iBox < 0)
        {
            string body;
            if (lowfi.Count > 0)
            {
                var keep = new List<string>();
                foreach (string l in rest)
                    if (!lowfi.Contains(l)) keep.Add(l);
                body = StripChars(string.Join("\n", keep), '\n');
            }
            else
            {
                body = StripChars(string.Join("\n", rest), '\n');
            }
            return Doc(meta, profile, provLines, lowfi, new List<string>(), "", body, true);
        }

        int end = iFull >= 0 ? iFull : rest.Count;
        List<string> triageLines = rest.GetRange(iBox, end - iBox);

        string rawSos = "";
        if (iFull >= 0)
        {
            int k = iFull + 1;
            while (k < rest.Count && (BAR_DEQ.IsMatch(rest[k]) || PyStrip(rest[k]).Length == 0))
                k++;
            rawSos = StripChars(string.Join("\n", rest.GetRange(k, rest.Count - k)), '\n');
        }

        return Doc(meta, profile, provLines, lowfi, triageLines, rawSos, null, false);
    }

    static (string rt, string arch, string status, string tool) Meta(List<string> provLines, string statusPath)
    {
        var kv = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string l in provLines)
        {
            Match m = PROV_KV.Match(l);
            if (m.Success) kv[m.Groups[1].Value] = PyStrip(m.Groups[2].Value);
        }
        string status = "unknown";
        if (!string.IsNullOrEmpty(statusPath))
        {
            try
            {
                byte[] b = File.ReadAllBytes(statusPath);
                using var doc = JsonDocument.Parse(b);
                if (doc.RootElement.ValueKind == JsonValueKind.Object
                    && doc.RootElement.TryGetProperty("status", out var sv))
                    status = ScalarToPy(sv);
                else
                    status = "unknown";
            }
            catch (IOException) { }
            catch (JsonException) { }
        }
        string rt = kv.TryGetValue("runtime_version", out var r) ? r : "unknown";
        string arch = kv.TryGetValue("dump_arch", out var a) ? a : "unknown";
        // Per-image identity for the rendered H1. Each per-image analyze.sh
        // emits a `report_tool : <name>` provenance line (e.g.
        // dotnet-autopsy/sos, dotnet-autopsy/trace); default keeps the
        // family-level brand if absent.
        string tool = kv.TryGetValue("report_tool", out var t) && !string.IsNullOrEmpty(t)
            ? t : "dotnet-autopsy";
        return (rt, arch, status, tool);
    }

    static string ScalarToPy(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString() ?? "",
        JsonValueKind.True => "True",
        JsonValueKind.False => "False",
        JsonValueKind.Null => "None",
        JsonValueKind.Number => v.GetRawText(),
        _ => v.GetRawText(),
    };

    static List<(string title, string body)> TriageSections(List<string> tl, Profile profile)
    {
        var outp = new List<(string, string)>();
        int i = 0, n = tl.Count;
        while (i < n)
        {
            if (BAR_DASH.IsMatch(tl[i]) && i + 1 < n)
            {
                string title = PyStrip(tl[i + 1]);
                int j = i + 2;
                if (j < n && BAR_DASH.IsMatch(tl[j])) j++;
                var body = new List<string>();
                int k = j;
                while (k < n && !BAR_DASH.IsMatch(tl[k]) && !BAR_DEQ.IsMatch(tl[k])
                       && PyStrip(tl[k]) != profile.Marker)
                {
                    body.Add(tl[k]);
                    k++;
                }
                if (title.Length > 0)
                    outp.Add((title, StripChars(string.Join("\n", body), '\n')));
                i = k;
            }
            else
            {
                i++;
            }
        }
        return outp;
    }

    // \A═+ ... — ... == Python ^═+ ... — ... (em dash).
    static readonly Regex InnerRx = new(
        "\\A═+\\s*INNER EXCEPTION DETAIL\\s*—\\s*level\\s*(\\d+)"
        + "(?:\\s*\\(printexception\\s+([0-9A-Fa-fx]+)\\))?", O);

    static List<(string label, string body)> SplitSos(string rawSos, Profile profile)
    {
        string[] lines = rawSos.Split('\n');
        var bounds = new List<(int idx, string label)>();
        int pos = 0;
        foreach (var (label, rx) in profile.Anchors)
        {
            for (int i = pos; i < lines.Length; i++)
            {
                if (rx.IsMatch(lines[i]))
                {
                    bounds.Add((i, label));
                    pos = i + 1;
                    break;
                }
            }
        }
        if (bounds.Count < profile.MinSplit) return new List<(string, string)>();

        var chunks = new List<(string label, string body)>();
        int prevI = 0;
        string prevLabel = "session";
        foreach (var (idx, label) in bounds)
        {
            if (idx > prevI)
                chunks.Add((prevLabel, StripChars(JoinRange(lines, prevI, idx), '\n')));
            prevI = idx;
            prevLabel = label;
        }
        chunks.Add((prevLabel, StripChars(JoinRange(lines, prevI, lines.Length), '\n')));

        var final = new List<(string label, string body)>();
        foreach (var (lbl, body) in chunks)
        {
            if (!body.Contains("INNER EXCEPTION DETAIL", StringComparison.Ordinal))
            {
                final.Add((lbl, body));
                continue;
            }
            string curLbl = lbl;
            var cur = new List<string>();
            foreach (string ln in body.Split('\n'))
            {
                Match m = InnerRx.Match(ln);
                if (m.Success)
                {
                    if (PyStrip(string.Join("\n", cur)).Length > 0)
                        final.Add((curLbl, StripChars(string.Join("\n", cur), '\n')));
                    string lvl = m.Groups[1].Value;
                    string addr = m.Groups[2].Success ? m.Groups[2].Value : null;
                    curLbl = !string.IsNullOrEmpty(addr)
                        ? "inner exception detail — level " + lvl + " - " + addr
                        : "inner exception detail — level " + lvl;
                    cur = new List<string>();
                }
                else
                {
                    cur.Add(ln);
                }
            }
            if (PyStrip(string.Join("\n", cur)).Length > 0)
                final.Add((curLbl, StripChars(string.Join("\n", cur), '\n')));
        }

        var result = new List<(string label, string body)>();
        foreach (var (lbl, b) in final)
            if (PyStrip(b).Length > 0) result.Add((lbl, b));

        var inner = new List<(string label, string body)>();
        foreach (var it in result)
            if (it.label.StartsWith("inner exception detail", StringComparison.Ordinal))
                inner.Add(it);
        if (inner.Count > 0)
        {
            var restList = new List<(string label, string body)>();
            foreach (var it in result)
                if (!it.label.StartsWith("inner exception detail", StringComparison.Ordinal))
                    restList.Add(it);
            // Python sorted() is stable: decorate with original index.
            var keyed = new List<(int key, int ix, (string, string) it)>();
            for (int x = 0; x < inner.Count; x++)
            {
                Match lm = Regex.Match(inner[x].label, @"level\s*(\d+)", O);
                int key = lm.Success ? int.Parse(lm.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
                keyed.Add((key, x, inner[x]));
            }
            keyed.Sort((p, q) => p.key != q.key ? p.key.CompareTo(q.key) : p.ix.CompareTo(q.ix));
            var innerSorted = new List<(string, string)>();
            foreach (var e in keyed) innerSorted.Add(e.it);

            int pe = -1;
            for (int k = 0; k < restList.Count; k++)
                if (restList[k].label == "printexception -nested") { pe = k; break; }
            if (pe >= 0)
            {
                restList.InsertRange(pe + 1, innerSorted);
                return restList;
            }
        }
        return result;
    }

    static string JoinRange(string[] arr, int start, int endExcl)
    {
        var sb = new StringBuilder();
        for (int i = start; i < endExcl; i++)
        {
            if (i > start) sb.Append('\n');
            sb.Append(arr[i]);
        }
        return sb.ToString();
    }

    static string Doc((string rt, string arch, string status, string tool) meta,
                      Profile profile,
                      List<string> provLines, List<string> lowfi,
                      List<string> triageLines, string rawSos,
                      string minimalBody, bool isMinimal)
    {
        string rt = meta.rt, arch = meta.arch, status = meta.status, tool = meta.tool;
        var toc = new List<string>();
        var body = new List<string>();

        void H2(string title, string sid)
        {
            body.Add(Anchor(sid));
            body.Add("## " + title);
            string d = Desc(title);
            body.Add(d.Length > 0 ? "_" + d + "_\n" : "");
            toc.Add("- [" + title + "](#" + sid + ")");
        }
        void H3(string title, string sid)
        {
            body.Add(Anchor(sid));
            body.Add("### " + title);
            string d = Desc(title);
            body.Add(d.Length > 0 ? "_" + d + "_\n" : "");
            toc.Add("  - [" + title + "](#" + sid + ")");
        }

        string src = SERVE_BASE + "/analysis.txt";
        string stj = SERVE_BASE + "/status.json";
        string rawmd = SERVE_BASE + "/analysis.md?raw=1";
        string head =
            "# " + tool + " analysis — " + rt + " / " + arch + " — status: " + status + "\n\n"
            + "> Rendered view of `analysis.txt`. Authoritative raw source: "
            + "[analysis.txt](" + src + ") · machine status: [status.json](" + stj + ") · "
            + "[raw markdown](" + rawmd + "). This file is generated; `analysis.txt` is "
            + "the source of truth.";

        var rows = new List<(string k, string v)>();
        foreach (string l in provLines)
        {
            Match m = PROV_KV.Match(l);
            if (m.Success) rows.Add((m.Groups[1].Value, PyStrip(m.Groups[2].Value)));
        }
        if (rows.Count > 0)
        {
            H2("Provenance", "sec-provenance");
            body.Add("| Key | Value |");
            body.Add("|---|---|");
            foreach (var (k, v) in rows)
                body.Add("| " + k + " | " + v.Replace("|", "\\|") + " |");
            body.Add("");
        }

        if (lowfi.Count > 0)
        {
            H2("⚠ Analysis degraded", "sec-degraded");
            string reason = "";
            foreach (string l in lowfi)
            {
                string st = PyStrip(l);
                if (st.Length > 0 && !BAR_DEQ.IsMatch(l)
                    && !l.Contains("ANALYSIS DEGRADED", StringComparison.Ordinal))
                {
                    reason = st;
                    break;
                }
            }
            if (reason.Length > 0) body.Add("> " + reason + "\n");
            body.Add(Fence(string.Join("\n", lowfi)));
            body.Add("");
        }

        if (isMinimal)
        {
            if (PyStrip(minimalBody).Length > 0)
            {
                H2("Analysis output", "sec-output");
                body.Add(Fence(minimalBody));
                body.Add("");
            }
            return Assemble(head, toc, body);
        }

        H2("Auto-triage summary", "sec-triage");
        int mStart = 0;
        for (int i = 0; i < triageLines.Count; i++)
            if (triageLines[i].StartsWith("╚", StringComparison.Ordinal)) { mStart = i + 1; break; }
        int mEnd = triageLines.Count;
        for (int i = mStart; i < triageLines.Count; i++)
            if (BAR_DASH.IsMatch(triageLines[i]) || BAR_DEQ.IsMatch(triageLines[i])) { mEnd = i; break; }
        var metaRows = new List<(string k, string v)>();
        var metaRx = new Regex(@"\A\s{2}([A-Za-z][\w .]*?)\s*:\s(.*)$", O);
        for (int i = mStart; i < mEnd; i++)
        {
            Match m = metaRx.Match(triageLines[i]);
            if (m.Success)
                metaRows.Add((PyStrip(m.Groups[1].Value), PyStrip(m.Groups[2].Value)));
        }
        if (metaRows.Count > 0)
        {
            body.Add("| Field | Value |");
            body.Add("|---|---|");
            foreach (var (k, v) in metaRows)
                body.Add("| " + k + " | " + v.Replace("|", "\\|") + " |");
            body.Add("");
        }
        foreach (var (title, sbody) in TriageSections(triageLines, profile))
        {
            string nice = PyTitle(title).Replace("(Clrthreads)", "(clrthreads)");
            string sid = "tri-" + Slug(title);
            H3(nice, sid);
            body.Add(Fence(PyStrip(sbody).Length > 0 ? sbody : "(not available)"));
            body.Add("");
        }

        H2(profile.FullOutputTitle, "sec-sos");
        var parts = PyStrip(rawSos).Length > 0 ? SplitSos(rawSos, profile) : new List<(string, string)>();
        if (parts.Count > 0)
        {
            foreach (var (label, sbody) in parts)
            {
                string disp;
                if (label == "session")
                    disp = "Session / symbol setup";
                else if (label.StartsWith("inner exception detail", StringComparison.Ordinal))
                    disp = char.ToUpperInvariant(label[0]) + label.Substring(1);
                else
                    disp = "`" + label + "`";
                string sid = "cmd-" + Slug(label);
                H3(disp, sid);
                body.Add(Fence(sbody));
                body.Add("");
            }
        }
        else
        {
            body.Add(PyStrip(rawSos).Length > 0
                ? "_(could not split by command — full raw output below)_\n"
                : "_(no SOS output)_\n");
            if (PyStrip(rawSos).Length > 0)
                body.Add(Fence(rawSos));
            body.Add("");
        }

        return Assemble(head, toc, body);
    }

    static string Assemble(string head, List<string> toc, List<string> body)
    {
        var parts = new List<string> { head, "", Anchor("sec-contents"), "## Contents", "" };
        parts.AddRange(toc);
        parts.Add("");
        parts.AddRange(body);
        return PyRStrip(string.Join("\n", parts)) + "\n";
    }

    static string Fallback(string raw)
    {
        // The fallback path is hit only when Render() throws, before the
        // per-image provenance can be parsed — so we use the family brand
        // here rather than guess at sos/trace.
        return "# dotnet-autopsy analysis\n\n"
             + "> Rendered view of `analysis.txt` (raw fallback — structured "
             + "render failed). Authoritative source: "
             + "[analysis.txt](" + SERVE_BASE + "/analysis.txt).\n\n"
             + Fence(raw) + "\n";
    }

    // ---- CPython string-semantics helpers ---------------------------------

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

    static string PyRStrip(string s)
    {
        int b = s.Length;
        while (b > 0 && PySpace(s[b - 1])) b--;
        return s.Substring(0, b);
    }

    // Python str.strip(ch): trim only the given char from both ends.
    static string StripChars(string s, char ch)
    {
        int a = 0, b = s.Length;
        while (a < b && s[a] == ch) a++;
        while (b > a && s[b - 1] == ch) b--;
        return s.Substring(a, b - a);
    }

    static string ToLowerInv(string s) => s.ToLowerInvariant();

    // CPython str.title(): first cased char of each run uppercased, the rest
    // lowercased; non-cased chars (digits/punct/space) reset the run. For our
    // ASCII titles, "cased" == IsLetter.
    static string PyTitle(string s)
    {
        var sb = new StringBuilder(s.Length);
        bool prevCased = false;
        foreach (char c in s)
        {
            if (char.IsLetter(c))
            {
                sb.Append(prevCased ? char.ToLowerInvariant(c) : char.ToUpperInvariant(c));
                prevCased = true;
            }
            else
            {
                sb.Append(c);
                prevCased = false;
            }
        }
        return sb.ToString();
    }
}
