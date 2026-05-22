# Security Policy

## Sensitive artifact warning

Every artifact this tool analyzes — core dumps, `.nettrace` captures, `.gcdump`
heap snapshots — contains **process memory**: connection strings, access tokens,
PII, internal type names and call sites. Treat every analysis image produced by
this tool as a sensitive artifact.

Built-in controls:

- **localhost-only binding.** `docker compose up` and all `docker run` examples
  bind to `127.0.0.1:5550`, not `0.0.0.0`. The unauthenticated file server is
  never reachable from other hosts on the network.
- **Do not use `--network host`** — this would expose the file server to all
  network interfaces.
- **Do not push per-case images to a shared registry.** The published artifact is
  `dotnet-autopsy-base` only (dump/trace/heap-less). Per-case images bake your
  artifact and must stay local.
- **Lifecycle.** Treat each case image as disposable. After analysis:
  ```sh
  docker compose down
  docker rmi dotnet-autopsy-sos   # or -trace / -gcdump
  docker image prune -f
  ```

## XSS controls

The file server renders `.md` files via Markdig without HTML sanitization. All
dump-derived content (exception messages, type names, heap strings, stack frames)
is placed inside fenced code blocks in `analysis.md`. The fence length is
dynamically extended to prevent content from escaping the block. Only
tool-generated metadata (versions, hashes, timestamps) appears as bare Markdown.

## Supported versions

Only the latest commit on `main` is supported. There are no backported security
fixes to older tags.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report privately via GitHub's
[Security Advisories](https://github.com/JanusMael/dotnet-autopsy/security/advisories/new)
feature (Repository → Security tab → "Report a vulnerability").

Include:
- A description of the vulnerability and its impact
- Steps to reproduce
- Any suggested mitigations

You will receive a response within 7 days. Coordinated disclosure is appreciated.
