// json-get.cs — .NET 10 file-based app (BCL only: System.Text.Json).
//
// Replaces every `python3 -c "import json,sys; d=json.load(open(F));
// print(d.get(K,'unknown'))"` call site (entrypoint.sh, demo.sh, smoke.sh,
// rot-check.yml), all of which run inside the container via `docker exec`
// and are guarded by the shell `2>/dev/null || echo "unknown"`.
//
// Contract (mirrors `json.load(open(file)).get(key, "unknown")` exactly):
//   json-get <file> <key>
//     • valid JSON object, key present  -> the value, then '\n', exit 0
//         (string: raw; bool/number/null: Python str() — True/False/None/
//          the number text — so output matches Python `print(d.get(...))`)
//     • valid JSON object, key absent   -> "unknown\n", exit 0
//         (mirrors dict.get(key, "unknown"))
//     • file unreadable / invalid JSON / non-object root -> exit nonzero,
//       NOTHING on stdout (Python would raise; the caller's `|| echo
//       unknown` then supplies the fallback)
//   json-get --selftest  -> parse an embedded sample; exit 0 ok / 1 fail
//       (used by the Dockerfile publish step to validate the binary)
//
// stdout is pristine: UTF-8 without BOM, explicit '\n', invariant culture,
// a single buffered write — nothing else may reach stdout.

using System;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;

CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))
{
    NewLine = "\n",
    AutoFlush = false,
};

if (args.Length == 1 && args[0] == "--selftest")
{
    try
    {
        using var probe = JsonDocument.Parse(
            "{\"status\":\"success\",\"n\":1,\"b\":true,\"z\":null}");
        var root = probe.RootElement;
        bool ok =
            root.TryGetProperty("status", out var s) && s.GetString() == "success"
            && root.TryGetProperty("b", out var b) && b.ValueKind == JsonValueKind.True
            && !root.TryGetProperty("missing", out _);
        if (!ok)
        {
            Console.Error.Write("json-get --selftest: assertion failed\n");
            return 1;
        }
        stdout.Write("selftest-ok\n");
        stdout.Flush();
        return 0;
    }
    catch (Exception ex)
    {
        Console.Error.Write("json-get --selftest: " + ex.Message + "\n");
        return 1;
    }
}

if (args.Length != 2)
{
    Console.Error.Write("usage: json-get <file> <key>  |  json-get --selftest\n");
    return 2;
}

string file = args[0];
string key = args[1];

JsonDocument doc;
try
{
    byte[] raw = File.ReadAllBytes(file);
    doc = JsonDocument.Parse(raw);          // OSError | ValueError equivalent
}
catch (Exception ex)
{
    Console.Error.Write("json-get: " + ex.Message + "\n");
    return 1;
}

using (doc)
{
    JsonElement root = doc.RootElement;
    if (root.ValueKind != JsonValueKind.Object)
    {
        // Python: json.load(...) is a list/scalar -> `.get` AttributeError
        // -> nonzero -> caller's `|| echo unknown`.
        Console.Error.Write("json-get: top-level JSON is not an object\n");
        return 1;
    }

    if (!root.TryGetProperty(key, out JsonElement v))
    {
        stdout.Write("unknown\n");           // dict.get(key, "unknown")
        stdout.Flush();
        return 0;
    }

    // Mirror Python `print(d.get(key))` for every scalar kind.
    string outv = v.ValueKind switch
    {
        JsonValueKind.String => v.GetString() ?? "",
        JsonValueKind.True => "True",
        JsonValueKind.False => "False",
        JsonValueKind.Null => "None",
        JsonValueKind.Number => v.GetRawText(),
        _ => v.GetRawText(),                  // object/array: Python would
                                              // print its repr; never used
                                              // by our string-only call sites
    };
    stdout.Write(outv);
    stdout.Write("\n");
    stdout.Flush();
    return 0;
}
