# AGENTS.md

Conventions for AI agents and contributors working on this repository.

## What this repo is

A single PowerShell script, `Convert-MkvToMp4.ps1`, that batch-converts disc rips
(MKV) to MP4 with HandBrakeCLI, plus `Compare-RecycleBin.ps1`, a safety check for
the NAS recycle bin.

The repo lives **inside the movie library**, so `.gitignore` ignores everything
(`/*`) and re-includes only the tooling by name. To track a new file, add an
explicit `!/name` line. Never `git add -A` expecting it to be safe by accident —
the allowlist is the safety net, so do not weaken it.

## Read before changing behaviour

- `README.md` — user-facing behaviour, and the current source of truth
- `SPEC.md` — technical requirements. **Its older sections are stale**; see the
  banner at the top. Do not regenerate the script from them.
- `git log` — every change carries the reasoning for it, including the bug it
  fixed. Read the message before altering related code.

## Environment

This machine's tooling is not on `PATH` for non-interactive shells. Use full
paths:

| Tool | Path |
|---|---|
| HandBrakeCLI | `C:\Tools\HandBrake\HandBrakeCLI.exe` |
| ffmpeg / ffprobe | auto-discovered; commonly `C:\Program Files\DVDFab\StreamFab\` |
| git | `C:\Program Files\Git\cmd\git.exe` |
| python | `C:\Python312\python.exe` |

Related tooling that is **not** in this repo lives in `\\localcloud\media\.remuxtools\`
(subtitle fetching, sync repair, surround restore). See its README.

## Working rules

**Verify against real media, not assumptions.** Every significant bug here came
from an assumption that held for one disc and not another:

- `-a 1,1` assumed the first audio track was the best one. True for one disc,
  false for the next, and it silently produced stereo-only files.
- A size-only `cleanup` check assumed a valid MP4 meant a good conversion. It
  destroyed the subtitles for 567 movies.
- HandBrake's preset was assumed to pass subtitles through. It does not.

Before claiming a change works, probe an actual file with ffprobe and show the
stream list.

**Prefer measurement to estimation.** Runtime, coverage and sync are all
measurable. A subtitle that "downloaded successfully" can still cover 20% of the
film; check the last cue against the duration rather than trusting a cue count.

**Do not silently drop data.** If something cannot be carried into the output,
say so on the console and preserve it some other way. That is why PGS is
extracted to `.sup`.

**Guard destructive operations.** `cleanup` deletes the only remaining copy of a
source. Anything similar needs a check that the replacement is genuinely
complete, plus an explicit override switch.

## PowerShell notes

- `[int]` on a double **rounds**; use `[Math]::Floor` when truncating (this
  produced timestamps an hour out in a subtitle tool).
- `Get-ChildItem -Include` silently returns nothing without `-Recurse` or a
  trailing `\*`.
- `"$var_name"` parses `var_name` as the variable; use `"${var}_name"`.
- ffprobe CSV output can carry a trailing empty field (`6,` not `6`), which
  breaks numeric comparisons. Strip it.
- Paths in this library contain spaces, apostrophes and parentheses. Quote
  everything, and prefer `-LiteralPath` where available.

## Testing

There is no test suite. Validate a change by:

1. Running `check` mode first — it is read-only.
2. Converting one real title and probing the result with ffprobe: expected video,
   two audio tracks with the right channel counts, and the subtitle tracks you
   expect.
3. For destructive modes, running against a copied folder before the real one.

## Commits

Describe the **defect and its consequence**, not just the edit. "Select the best
audio track instead of assuming track 1" followed by why it mattered is far more
useful than "update audio args" — the git history is the primary record of why
this script looks the way it does.
