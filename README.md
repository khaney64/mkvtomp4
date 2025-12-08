# MKV to MP4 Batch Converter

A powerful PowerShell script for batch converting MKV video files to MP4 format using HandBrakeCLI with intelligent preset selection, performance tracking, and multiple operation modes.

## Features

- 🎬 **Automatic Preset Selection** — Detects video resolution and applies appropriate HandBrake preset (480p or 1080p)
- 📊 **Performance Tracking** — Learns from each conversion to provide accurate time estimates
- 🔍 **Multiple Operation Modes** — Check, convert, find, hide, show, and space modes for different workflows
- 💾 **Disk Space Analysis** — Estimates required space and checks availability before conversion
- 🛡️ **Safe Conversion** — Uses temporary files to prevent incomplete MP4s from interrupted processes
- 🎯 **Idempotent** — Running multiple times only converts new files
- 🎨 **Color-Coded Output** — Easy-to-read progress and status messages

## Requirements

- **PowerShell 5.1 or higher** (included with Windows 10/11)
- **HandBrakeCLI** — Download from [HandBrake.fr](https://handbrake.fr/downloads.php)
  - Default expected location: `C:\Tools\HandBrake\HandBrakeCLI.exe`
  - Update the `$HandBrakeCLI` variable in the script if installed elsewhere

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

## Conversion Settings

The script uses the following HandBrake settings for high-quality, web-optimized output:

- **Video Codec**: H.264 (x264)
- **Quality**: RF 18 (visually lossless)
- **Preset**: Automatically selected based on resolution
  - SD (≤480p): `Fast 480p30`
  - HD (≥720p): `Fast 1080p30`
- **Audio**: AC3 passthrough with AAC fallback
- **Optimization**: Web-optimized (fast-start enabled)

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

## Documentation

See [copilot-instructions.md](copilot-instructions.md) for complete technical documentation and regeneration instructions.

## License

This script is provided as-is for personal use. HandBrakeCLI is licensed under GPLv2.

## Acknowledgments

- [HandBrake](https://handbrake.fr/) — The excellent open-source video transcoder
- Built with PowerShell and assistance from GitHub Copilot

---

**Note**: This script is designed for personal media management. Ensure you have the right to convert any media files you process.
