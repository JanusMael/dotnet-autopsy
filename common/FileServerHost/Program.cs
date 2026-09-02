// FileServerHost — dotnet-autopsy's in-container file server.
//
// A minimal ASP.NET Core host around the Bennewitz.Ninja.FileServer NuGet
// library. It keeps the CLI contract of the former prebuilt binary so that
// common/entrypoint.sh only had to change the executable name:
//
//   FileServerHost --root /analysis --route analysis --http-port 5550
//
// Serves ${root} mounted at /${route} — directory listings, rendered
// Markdown (append ?raw for the source), downloads — and redirects / to
// /${route} so the documented "browse everything" URL
// http://localhost:5550/ keeps working: the library mounts only the route
// it is given and does not add a root redirect itself.
//
// Binding: listens on 0.0.0.0 INSIDE the container. That is required for
// Docker's port mapping to reach it and is NOT the security boundary — the
// boundary is the host-side `-p 127.0.0.1:5550:5550` that every documented
// run/compose path uses (see README "Security"). Never bind the HOST side
// to 0.0.0.0.
//
// Argument parsing is deliberately hand-rolled (no NuGet CLI framework) and
// the args are NOT forwarded to WebApplication.CreateBuilder, so our flags
// never leak into IConfiguration.

using System.Xml.Linq;
using Bennewitz.Ninja.FileServer;
using Microsoft.AspNetCore.DataProtection.KeyManagement;
using Microsoft.AspNetCore.DataProtection.Repositories;
using Microsoft.AspNetCore.DataProtection.XmlEncryption;

string root  = Environment.GetEnvironmentVariable("FILES_DIR") ?? "/analysis";
string route = "analysis";
int    port  = 5550;

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--root":
            root = NextArg(args, ref i, "--root");
            break;
        case "--route":
            route = NextArg(args, ref i, "--route").Trim('/');
            break;
        case "--http-port":
            if (!int.TryParse(NextArg(args, ref i, "--http-port"), out port) || port <= 0 || port > 65535)
            {
                Console.Error.WriteLine("FileServerHost: --http-port must be an integer in 1..65535");
                return 2;
            }
            break;
        default:
            Console.Error.WriteLine($"FileServerHost: unknown argument '{args[i]}'");
            Console.Error.WriteLine("usage: FileServerHost [--root DIR] [--route NAME] [--http-port N]");
            return 2;
    }
}

if (string.IsNullOrEmpty(route))
{
    Console.Error.WriteLine("FileServerHost: --route must not be empty");
    return 2;
}

if (!Directory.Exists(root))
{
    // MapFileServer requires RootPath to exist at startup; fail with a clear
    // message instead of a stack trace.
    Console.Error.WriteLine($"FileServerHost: root directory does not exist: {root}");
    return 1;
}

string mount = "/" + route;

// The .NET SDK/ASP.NET base images bake ASPNETCORE_HTTP_PORTS=8080 into the
// environment. Any port chosen in code then conflicts with it and hosting
// logs a per-start "Overriding HTTP_PORTS ... Binding to values defined by
// URLS instead" warning. --http-port is the single source of truth here, so
// clear the image defaults BEFORE the builder snapshots the environment.
Environment.SetEnvironmentVariable("ASPNETCORE_HTTP_PORTS", null);
Environment.SetEnvironmentVariable("ASPNETCORE_HTTPS_PORTS", null);

var builder = WebApplication.CreateBuilder();
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
builder.Services.AddFileServer();

// This host issues no cookies and has no antiforgery/auth state, so
// DataProtection keys never need to outlive the process. The FileServer's
// Razor stack still registers the key-ring machinery, which by default
// selects FileSystemXmlRepository at startup — the source of the per-start
// "Storing keys in a directory ... that may not be persisted" warning
// (swapping IDataProtectionProvider alone does NOT prevent it). Supplying an
// in-memory XmlRepository means the file-system default is never chosen
// (the same mechanism PersistKeysTo*() uses), so keys live and die with the
// process. NullXmlEncryptor states explicitly that those in-memory keys are
// not encrypted — which silences the "No XML encryptor configured" warning
// the key manager otherwise logs when it generates the startup key. The
// remaining key-ring info chatter is demoted; real warnings still surface.
builder.Services.Configure<KeyManagementOptions>(o =>
{
    o.XmlRepository = new InMemoryXmlRepository();
    o.XmlEncryptor  = new NullXmlEncryptor();
});
builder.Logging.AddFilter("Microsoft.AspNetCore.DataProtection", LogLevel.Warning);

var app = builder.Build();
app.MapFileServer(mount, o => o.RootPath = root);
app.MapGet("/", () => Results.Redirect(mount));

Console.WriteLine($"FileServerHost: serving {root} at http://0.0.0.0:{port}{mount}");
app.Run();
return 0;

static string NextArg(string[] a, ref int i, string flag)
{
    if (i + 1 >= a.Length)
    {
        Console.Error.WriteLine($"FileServerHost: {flag} requires a value");
        Environment.Exit(2);
    }
    return a[++i];
}

// Process-lifetime key store for DataProtection. Nothing in this host ever
// Protect()s a payload, so the store only exists to satisfy the key ring
// without touching the filesystem. Thread-safe because XmlKeyManager may
// read and write from different threads; returns copies so callers cannot
// mutate stored elements.
sealed class InMemoryXmlRepository : IXmlRepository
{
    private readonly List<XElement> _elements = new();
    private readonly object _lock = new();

    public IReadOnlyCollection<XElement> GetAllElements()
    {
        lock (_lock)
        {
            return _elements.Select(e => new XElement(e)).ToList().AsReadOnly();
        }
    }

    public void StoreElement(XElement element, string friendlyName)
    {
        lock (_lock)
        {
            _elements.Add(new XElement(element));
        }
    }
}
