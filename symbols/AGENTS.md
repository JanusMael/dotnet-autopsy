# AGENTS.md — `symbols/`

Where a user drops private PDBs, and for `delve-lldb` the app binary, before building the sos
image. Nothing here but `.keep`, `AGENTS.md` and `CLAUDE.md` is ever committed.

## Rules

| Rule | Why | Guarded by |
|---|---|---|
| Everything else in this directory stays untracked | PDBs and binaries belong to one case and can be large or sensitive | `.gitignore`: `symbols/*` with exceptions for the three tracked files |
| The directory itself stays in the build context | `sos/dotnet-sos.dockerfile` copies it to `/symbols-user/`, which `sos/analyze.sh` passes to SOS as a symbol directory and `sos/delve-lldb.sh` searches for the executable | `.dockerignore` keeps it; the `COPY` fails if the directory is missing |
| `AGENTS.md` and `CLAUDE.md` stay out of the image | They are repository documentation, not symbols | `.dockerignore` |
