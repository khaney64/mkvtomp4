# MKV to MP4 Batch Converter

A powerful PowerShell script for batch converting MKV video files to MP4 format using HandBrakeCLI with intelligent preset selection, performance tracking, and multiple operation modes.

## Features

- 🎬 **Automatic Preset Selection** — Detects video resolution and applies appropriate HandBrake preset (480p or 1080p)
- 💬 **Subtitle Preservation** — Carries the disc's subtitles into the MP4 and writes a sidecar `.srt`
- 🔊 **Surround Audio Preservation** — Keeps the source 5.1 track and adds a stereo compatibility track
- 📊 **Performance Tracking** — Learns from each conversion to provide accurate time estimates
- 🔍 **Multiple Operation Modes** — Check, convert, find, hide, show, space, report, cleanup, and backfill
- 💾 **Disk Space Analysis** — Estimates required space and checks availability before conversion
- 📄 **MP4 Report Generation** — Creates detailed reports of MP4 files organized by folder with resolution information
- 🛡️ **Safe Conversion** — Uses temporary files to prevent incomplete MP4s from interrupted processes
- 🔒 **Subtitle-Loss Guard** — `cleanup` refuses to delete a source whose subtitles did not survive
- 🎯 **Idempotent** — Running multiple times only converts new files
- 🎨 **Color-Coded Output** — Easy-to-read progress and status messages

## Requirements

- **PowerShell 5.1 or higher** (included with Windows 10/11)
- **HandBrakeCLI** — Download from [HandBrake.fr](https://handbrake.fr/downloads.php)
  - Default expected location: `C:\Tools\HandBrake\HandBrakeCLI.exe`
  - Update the `$HandBrakeCLI` variable in the script if installed elsewhere
- **ffmpeg / ffprobe** — *optional but strongly recommended*
  - Used to inspect audio and subtitle tracks, write sidecar `.srt` files, and
    extract `.sup` subtitles
  - Auto-discovered from `PATH`, `C:\Tools\ffmpeg\bin`, `C:\ffmpeg\bin`, or
    `C:\Program Files\ffmpeg\bin`
  - Without it the script still converts, but subtitle handling, best-audio-track
    selection and the `backfill` mode are unavailable

## Installation

1. Clone this repository or download `Convert-MkvToMp4.ps1`
2. Install HandBrakeCLI to `C:\Tools\HandBrake\` (or update the path in the script)
3. Open PowerShell and navigate to the script directory

## Usage

### Basic Usage

```powershell
# Check what would be converted (default mode)
.\Convert-MkvToMp4.ps1

# Convert all MKV files in current directory
.\Convert-MkvToMp4.ps1 -Mode convert

# Specify a different directory
.\Convert-MkvToMp4.ps1 -Mode convert -Path "D:\Videos"
```

### Operation Modes

#### `check` (Default)
Scans directories and provides estimates without converting:
- Lists files that would be converted
- Estimates output file sizes
- Calculates total conversion time
- Checks available disk space
- Uses historical performance data if available

```powershell
.\Convert-MkvToMp4.ps1
.\Convert-MkvToMp4.ps1 -Mode check -Path "M:\Movies"
```

#### `convert`
Performs actual MKV to MP4 conversions:
- Skips files that already have MP4 versions
- Uses temporary `.mp_` extension during conversion
- Tracks performance for future time estimates
- Shows elapsed time for each conversion

```powershell
.\Convert-MkvToMp4.ps1 -Mode convert
.\Convert-MkvToMp4.ps1 convert "M:\Movies"
```

#### `find`
Lists MKV files that already have corresponding MP4 files:
- Shows relative paths
- Displays MP4 file sizes
- Provides total MP4 size summary

```powershell
.\Convert-MkvToMp4.ps1 -Mode find
```

#### `hide`
Renames MKV files to `.mk_` extension (useful for hiding from media servers like Plex):
- Recursively finds all `.mkv` files
- Renames to `.mk_` extension
- Reports success/failure for each file

```powershell
.\Convert-MkvToMp4.ps1 -Mode hide
```

#### `show`
Restores hidden files by renaming `.mk_` back to `.mkv`:
- Recursively finds all `.mk_` files
- Renames to `.mkv` extension
- Reports success/failure for each file

```powershell
.\Convert-MkvToMp4.ps1 -Mode show
```

#### `space`
Analyzes disk space usage for all media files:
- Scans all subdirectories recursively
- Reports space used by `.mp4`, `.mp_`, `.mkv`, and `.mk_` files
- Shows file counts and sizes for each type
- Displays grand total of all media files
- Shows disk information (capacity, available space, usage percentage)

```powershell
.\Convert-MkvToMp4.ps1 -Mode space
.\Convert-MkvToMp4.ps1 space "M:\Movies"
```

#### `report`
Generates a detailed report of MP4 files with resolution information:
- Scans each subfolder for MP4 files
- Detects video resolution for each file (480p, 720p, 1080p, 2K, 4K, etc.)
- Groups files by folder
- Outputs results to `report.txt` in the current directory
- Includes summary statistics

```powershell
.\Convert-MkvToMp4.ps1 -Mode report
.\Convert-MkvToMp4.ps1 report "M:\Movies"
```

**Sample Report Output:**
```
================================================================================
Folder: Avatar (2009)
================================================================================
  Avatar.mp4 - 1080p
  Avatar - Extras.mp4 - 480p

================================================================================
Folder: The Matrix (1999)
================================================================================
  The Matrix.mp4 - 1080p

================================================================================
Summary
================================================================================
Total folders with MP4 files: 2
Total MP4 files: 3
Report generated: 2025-12-28 14:32:18
```

#### `cleanup`
Deletes `.mk_` sources that have a confirmed-good `.mp4` replacement:
- Requires the MP4 to be at least 50 MB and at least 8% of the source size
- **Refuses to delete when the source's subtitles did not survive** — see
  [Safety Features](#safety-features)
- Reports every case it declines to touch, and why

```powershell
.\Convert-MkvToMp4.ps1 -Mode cleanup
.\Convert-MkvToMp4.ps1 cleanup "M:\Movies" -SkipSubtitleGuard   # override
```

#### `backfill`
Writes sidecar `.srt` files for videos converted before subtitle handling existed:
- Pairs each video with its surviving `.mkv`/`.mk_` and extracts any text subtitle track
- Works on a source with no paired MP4, and on an MP4 with an embedded text track
- Skips titles that already have a sidecar, or that already carry embedded text
  (`-IncludeEmbedded` to write one anyway)
- Reports bitmap-only sources, which need OCR or a download instead

```powershell
.\Convert-MkvToMp4.ps1 -Mode backfill
.\Convert-MkvToMp4.ps1 backfill "M:\Movies"
```

### Switches

| Switch | Effect |
|---|---|
| `-Container mkv` | Output MKV instead of MP4. Keeps bitmap (PGS/VobSub) subtitles as selectable tracks — same file size, since the saving comes from the re-encode, not the container |
| `-NoSidecar` | Do not write sidecar `.srt` files during convert/backfill |
| `-NoSup` | Do not extract `.sup` archives for subtitles MP4 cannot carry |
| `-IncludeEmbedded` | During `backfill`, write a sidecar even if the video already has an embedded text track |
| `-SkipSubtitleGuard` | Allow `cleanup` to delete sources whose subtitles were lost |

## Conversion Settings

The script uses the following HandBrake settings for high-quality, web-optimized output:

- **Video Codec**: H.264 (x264)
- **Quality**: RF 18 (visually lossless)
- **Preset**: Automatically selected based on resolution
  - SD (≤480p): `Fast 480p30`
  - HD (≥720p): `Fast 1080p30`
- **Optimization**: Web-optimized (fast-start enabled)

### Audio

Two tracks are written: the source's **best** audio track, plus an AAC stereo
compatibility track.

- The best track is chosen by **channel count**, not position — disc track order
  is inconsistent, and some titles list the stereo mix before the 5.1 one
- AC3 / E-AC3 sources are **passed through untouched** (bit-identical)
- Anything that cannot pass through (DTS, TrueHD, LPCM) is encoded to **AC3**,
  which keeps all channels and plays natively everywhere — including over
  S/PDIF, which cannot carry multichannel AAC
- The AC3 bitrate scales with channel count: 192k mono, 256k stereo, 640k for
  5.1 and above

### Subtitles

English subtitles are selected explicitly and none are burned in. What actually
survives depends on the format, which in turn depends on the disc:

| Source format | Comes from | Into the MP4? |
|---|---|---|
| `subrip` (text) | DVD closed captions, extracted by MakeMKV | Yes, as `mov_text` — **and** as a sidecar `.srt` |
| `dvd_subtitle` (VobSub) | DVD | Yes (non-standard, but Plex reads it) |
| `hdmv_pgs_subtitle` (PGS) | Blu-ray | **No** — nothing can put PGS in an MP4 |
| `dvb_subtitle` | Broadcast | **No** |

**Blu-rays do not carry closed captions**, so a Blu-ray rip yields bitmap
subtitles only and produces no `.srt`. That is expected, not a failure. DVDs
usually do carry captions, which is why DVD rips get a sidecar automatically.

When a format cannot be carried, the script says so plainly rather than leaving
you to discover it in Plex later:

```
  Subtitles: source 1 track(s) [hdmv_pgs_subtitle] -> output 0 track(s)
             1 hdmv_pgs_subtitle track(s) could NOT be written to MP4 ...
             saved film.en.sup (15.7 MB) - OCR it later with Subtitle Edit
             *** RESULT: no subtitles in the output. ***
```

It also **extracts those tracks to a `.sup` sidecar automatically**, because
otherwise their only copy is inside the `.mkv` you are about to delete. The cost
is roughly 0.2% of the source size. A `.sup` is an archive, not a playable
subtitle — Plex ignores it — but it can be OCR'd to `.srt` with
[Subtitle Edit](https://www.nikse.dk/subtitleedit) at any time.

Sidecars are matched by **exact basename**, so `Film_t00.mp4` needs
`Film_t00.en.srt`. Watch for this when moving a converted file into a folder
where an older version already lives: an overwrite keeps the old name and
strands the subtitle.

## Performance Tracking

The script learns from each conversion:
- Tracks encoding rate in Mbits/minute
- Saves data to `handbrake_performance.json`
- Uses weighted average (80% historical, 20% new)
- Provides increasingly accurate time estimates

### Performance Data Structure
```json
{
  "MbitsPerMinute": 1250.5,
  "TotalConversions": 15,
  "LastUpdated": "2025-12-05T14:32:18.1234567-05:00"
}
```

## Examples

### Convert a specific movie collection
```powershell
.\Convert-MkvToMp4.ps1 -Mode convert -Path "D:\Movies\Marvel Collection"
```

### Check disk space before large batch conversion
```powershell
# First check estimates and disk space
.\Convert-MkvToMp4.ps1 -Mode check -Path "M:\"

# If sufficient space, proceed with conversion
.\Convert-MkvToMp4.ps1 -Mode convert -Path "M:\"
```

### Hide MKV files after converting to MP4
```powershell
# Convert all files
.\Convert-MkvToMp4.ps1 -Mode convert

# Hide the original MKV files
.\Convert-MkvToMp4.ps1 -Mode hide
```

### Find completed conversions
```powershell
.\Convert-MkvToMp4.ps1 -Mode find
```

### Analyze disk space usage
```powershell
# Get detailed space usage report for all media files
.\Convert-MkvToMp4.ps1 -Mode space

# Analyze a specific directory
.\Convert-MkvToMp4.ps1 space "D:\Media\Movies"
```

### Generate a report of MP4 files
```powershell
# Create a report of all MP4 files with resolution information
.\Convert-MkvToMp4.ps1 -Mode report

# Generate report for a specific directory
.\Convert-MkvToMp4.ps1 report "M:\Movies"

# The report will be saved to report.txt in the scanned directory
```

## Output Examples

### Check Mode Output
```
==================================
MKV to MP4 Batch Converter
==================================
Mode: check

Scanning directory: M:\Movies

Found 5 MKV file(s)

Analyzing: M:\Movies\Movie1.mkv
Detected resolution height: 1080p
Would convert using preset: Fast 1080p30
Source size: 4500.0 MB → Estimated MP4 size: 2925.0 MB
Estimated conversion time: ~18.5 minutes

...

==================================
Check Summary
==================================
Total MKV files found: 5
Already have MP4: 2
Would convert: 3
Failed to analyze: 0

Estimated total new MP4 size:
  8.1 GB (8308 MB)

Estimated total conversion time (based on 12 previous conversion(s)):
  ~1 hour(s) 23 minute(s)
  (Average encoding rate: 1250.5 Mbits/minute)

Available disk space on M:: 125.5 GB
✓ Sufficient space available (117.4 GB remaining after conversion)

To proceed with conversion, run:
  .\Convert-MkvToMp4.ps1 -Mode convert
```

## Safety Features

- **Temporary Files**: Converts to `.mp_` extension, only renamed to `.mp4` on success
- **Cleanup**: Automatically removes incomplete temporary files on failure
- **Idempotent**: Safe to run multiple times—skips existing MP4 files
- **No Overwrites**: Never overwrites existing MP4 files
- **Validation**: Checks for HandBrakeCLI and valid paths before processing
- **Subtitle-Loss Guard**: `cleanup` will not delete a `.mk_` source whose
  subtitles are absent from the replacement — a size check alone cannot tell
  that a conversion silently dropped them, and the source is the only remaining
  copy. Override with `-SkipSubtitleGuard`.
- **Bitmap Subtitle Archive**: PGS/DVB tracks are extracted to `.sup` before they
  can be lost with the source. Disable with `-NoSup`.

## Troubleshooting

### HandBrakeCLI not found
```
HandBrakeCLI not found at: C:\Tools\HandBrake\HandBrakeCLI.exe
```
**Solution**: Install HandBrakeCLI or update the `$HandBrakeCLI` variable in the script.

### Could not detect video height
```
Warning: Could not detect video height for: Movie.mkv
```
**Solution**: The MKV file may be corrupted or in an unusual format. HandBrake scan failed to parse it.

### Conversion failed with exit code
```
Warning: HandBrake returned exit code 1 for: Movie.mkv
```
**Solution**: Check the HandBrake logs at `%TEMP%\handbrake_out.log` and `%TEMP%\handbrake_err.log` for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

### No subtitles in the output

```
  *** RESULT: no subtitles in the output. ***
```
**Cause**: the source is bitmap-only (typical of Blu-ray, which carries no closed
captions), so there was no text track to carry across or write as a sidecar.

**Solutions**: OCR the `.sup` the script saved alongside the MP4 with
[Subtitle Edit](https://www.nikse.dk/subtitleedit), download a subtitle, or
re-run with `-Container mkv` to keep the bitmap track as a selectable stream.

### Converted file only has stereo

Check that ffprobe is available — without it the script cannot inspect the
source and falls back to audio track 1, which is not always the best one. Run a
conversion and confirm the line `Using source audio track N (Mch)` reports the
channel count you expect.

## Documentation

- [SPEC.md](SPEC.md) — complete technical specification and regeneration instructions
- [AGENTS.md](AGENTS.md) — conventions for AI agents and contributors working on this repo

## License

This script is provided as-is for personal use. HandBrakeCLI is licensed under GPLv2.

## Acknowledgments

- [HandBrake](https://handbrake.fr/) — The excellent open-source video transcoder
- Built with PowerShell and assistance from GitHub Copilot

---

**Note**: This script is designed for personal media management. Ensure you have the right to convert any media files you process.
