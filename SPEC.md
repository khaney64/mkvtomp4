# MKV to MP4 Batch Converter Script - Complete Requirements

> **Status: partial.** This document specifies the script as it stood through the
> `report`/`cleanup` modes. It does **not** yet cover the subtitle and audio work
> added afterwards, summarised under
> [Subtitle and Audio Requirements](#subtitle-and-audio-requirements) below.
>
> **Do not regenerate the script from the older sections alone.** Doing so would
> reintroduce fixed defects: no subtitles written, 5.1 downmixed to stereo, and
> an unguarded `cleanup` that deletes sources whose subtitles were lost. See
> `README.md` and `git log` for current behaviour.

## Purpose

Create a PowerShell script that automates the conversion of MKV video files to MP4 format using HandBrakeCLI. The script must intelligently select encoding presets based on video resolution, track performance metrics to improve time estimates, and provide multiple operation modes for different use cases including conversion, analysis, and file management.

## Inputs

### Parameters

1. **Mode** (Position 0, Optional)
   - Type: String
   - Default: `"check"`
   - Valid values: `"check"`, `"convert"`, `"find"`, `"hide"`, `"show"`, `"space"`, `"report"`
   - Description: Determines the operation to perform

2. **Path** (Position 1, Optional)
   - Type: String
   - Default: Current directory (Get-Location)
   - Description: The root directory to scan recursively

### External Dependencies

1. **HandBrakeCLI.exe**
   - Required location: `C:\Tools\HandBrake\HandBrakeCLI.exe`
   - Must be present and executable
   - Used for video scanning and conversion

2. **Performance Data File** (Optional)
   - Location: `handbrake_performance.json` (same directory as script)
   - Created automatically during conversions
   - Used to track encoding performance for better time estimates

### Input Files

- **Source files**: `.mkv` files found recursively in the specified path
- **Temporary marker files**: `.mk_` files (for show mode)
- **Performance tracking**: JSON file with historical conversion metrics

## Outputs

### Generated Files

1. **MP4 Video Files**
   - Extension: `.mp4`
   - Location: Same directory as source `.mkv` file
   - Created only if source `.mkv` exists and target `.mp4` doesn't

2. **Temporary Conversion Files**
   - Extension: `.mp_`
   - Purpose: Prevents incomplete files from being mistaken as valid MP4s
   - Renamed to `.mp4` only upon successful conversion
   - Automatically cleaned up on conversion failure

3. **Performance Data File** (`handbrake_performance.json`)
   - Format: JSON
   - Fields:
     - `MbitsPerMinute`: Double (average encoding rate)
     - `TotalConversions`: Integer (number of successful conversions tracked)
     - `LastUpdated`: String (ISO 8601 timestamp)

4. **Report File** (`report.txt`)
   - Format: Plain text
   - Created by: Report mode
   - Content:
     - Folder names grouped by directory
     - MP4 files within each folder
     - Video resolution information (480p, 720p, 1080p, 2K, 4K, etc.)
     - Summary statistics (total folders, total MP4 files, generation timestamp)

5. **HandBrake Log Files** (Temporary)
   - `%TEMP%\handbrake_out.log`: Standard output
   - `%TEMP%\handbrake_err.log`: Standard error
   - Purpose: Suppress verbose console output

### Console Output

- Color-coded progress messages
- File-by-file status updates
- Summary statistics based on mode
- Disk space availability analysis (check mode)
- Time and size estimates

## Processing Steps

### 1. Initialization

1. Parse command-line parameters (Mode, Path)
2. Set configuration variables:
   - `$HandBrakeCLI = "C:\Tools\HandBrake\HandBrakeCLI.exe"`
   - `$PerformanceDataFile = "$PSScriptRoot\handbrake_performance.json"`
3. Verify HandBrakeCLI exists; exit with error if not found
4. Validate that Path exists; exit with error if not found
5. Resolve Path to absolute path
6. Display header with mode and target directory

### 2. Mode-Specific Processing

#### Mode: "hide"

1. Find all `.mkv` files recursively in Path
2. If no files found, display message and exit
3. For each `.mkv` file:
   - Generate new filename with `.mk_` extension
   - Rename file (keeps same directory)
   - Log success or failure
4. Display summary: total found, total hidden

#### Mode: "show"

1. Find all `.mk_` files recursively in Path
2. If no files found, display message and exit
3. For each `.mk_` file:
   - Generate new filename with `.mkv` extension
   - Rename file (keeps same directory)
   - Log success or failure
4. Display summary: total found, total restored

#### Mode: "space"

1. Find all media files recursively in Path:
   - `.mp4` files (converted videos)
   - `.mp_` files (temporary conversion files)
   - `.mkv` files (source videos)
   - `.mk_` files (hidden source videos)
2. Calculate total size for each file type using `Measure-Object -Property Length -Sum`
3. Handle null values for empty collections (set to 0)
4. Calculate grand total of all file sizes
5. Display formatted summary:
   - For each file type:
     - Display file type name
     - Display count of files
     - Display size in GB (if >= 1 GB) or MB
   - Display grand total:
     - Total file count (all types combined)
     - Total size in GB (if >= 1 GB) or MB
   - Display disk information:
     - Total disk capacity in GB
     - Available space in GB
     - Usage percentage
6. Exit with code 0

#### Mode: "report"

1. Initialize report variables:
   - `$reportPath = Join-Path $currentDir "report.txt"`
   - `$reportLines = @()` (array for report content)
   - Initialize counters: `$totalFolders`, `$totalMp4Files`
2. Get all subdirectories in current directory using `Get-ChildItem -Directory | Sort-Object Name`
3. For each folder:
   - Find all MP4 files in the folder (non-recursive, immediate children only)
   - If MP4 files exist:
     - Increment `$totalFolders`
     - Add folder header to report with separator line (80 equals signs)
     - Display progress message (folder name)
     - For each MP4 file:
       - Display progress message (analyzing file)
       - Call `Get-VideoHeight` to detect resolution
       - Call `Get-VideoFormatLabel` to convert height to format string
       - Add to report: "  {filename} - {format}" (e.g., "movie.mp4 - 1080p")
       - If height detection fails, add "(Unable to detect resolution)"
       - Increment `$totalMp4Files`
4. Add summary section to report:
   - Blank line separator
   - Header with 80 equals signs
   - "Summary" heading
   - Header with 80 equals signs
   - Total folders with MP4 files count
   - Total MP4 files count
   - Generation timestamp (formatted as 'yyyy-MM-dd HH:mm:ss')
5. Write report lines to file using `Out-File` with UTF8 encoding
6. Display completion summary:
   - Folders scanned count
   - MP4 files found count
   - Report file path
7. Exit with code 0

#### Mode: "find"

1. Find all `.mkv` files recursively in Path
2. If no files found, display message and exit
3. For each `.mkv` file:
   - Check if corresponding `.mp4` exists
   - If yes:
     - Calculate relative path from base directory
     - Get MP4 file size in MB
     - Display file path and MP4 size
     - Add to collection
   - If no: skip
4. Display summary:
   - Total MKV files found
   - Count of files with existing MP4
   - Count of files without MP4
   - Total size of all MP4 files (GB and MB)

#### Mode: "check"

1. Find all `.mkv` files recursively in Path
2. If no files found, display message and exit
3. Initialize counters: `skipped`, `failed`, `filesToConvert`, `totalEstimatedSize`, `totalEstimatedTime`
4. For each `.mkv` file:
   - Check if corresponding `.mp4` exists
   - If yes: increment `skipped`, continue to next file
   - If no:
     - Call `Get-VideoHeight` to detect resolution
     - If detection fails: increment `failed`, continue
     - Call `Get-HandBrakePreset` to select preset
     - Call `Get-EstimatedMp4Size` to estimate output size
     - Call `Get-EstimatedConversionTime` to estimate duration
     - Accumulate `totalEstimatedSize` and `totalEstimatedTime`
     - Display: preset, source size → estimated size, estimated time
     - Increment `filesToConvert`
5. Display summary:
   - Total MKV files found
   - Count already having MP4
   - Count that would be converted
   - Count that failed analysis
   - Total estimated MP4 size (GB/MB)
   - Total estimated conversion time (hours/minutes)
   - Estimate source (historical data or defaults)
   - Average encoding rate if historical data exists
   - Available disk space on target drive
   - Space sufficiency check (✓ or ✗)
   - Instructions to run convert mode

#### Mode: "convert"

1. Find all `.mkv` files recursively in Path
2. If no files found, display message and exit
3. Initialize counters: `converted`, `skipped`, `failed`
4. For each `.mkv` file:
   - Check if corresponding `.mp4` exists
   - If yes: increment `skipped`, log skip message, continue
   - If no:
     - Call `Get-VideoHeight` to detect resolution
     - If detection fails: increment `failed`, continue
     - Call `Get-HandBrakePreset` to select preset
     - Call `Convert-MkvToMp4` with input path, output path, preset
     - If success: increment `converted`
     - If failure: increment `failed`
5. Display summary:
   - Total MKV files found
   - Count converted
   - Count skipped (already exists)
   - Count failed

### 3. Helper Functions

#### Get-VideoHeight

**Purpose**: Detect video resolution height from MKV or MP4 file

**Process**:
1. Execute `HandBrakeCLI --scan --input "$FilePath"` and capture output (stderr + stdout)
2. Parse output using regex patterns:
   - First try: `\+\s+size:\s+(\d+)x(\d+)` → extract second group (height)
   - Fallback: `(\d+)x(\d+)` → extract second group (height)
3. Return height as integer, or `$null` if not found
4. Log warnings on failures

**Note**: Works with both MKV and MP4 files for report mode.

#### Get-VideoFormatLabel

**Purpose**: Convert video height to user-friendly format label

**Parameters**:
- `Height`: Integer (video resolution height in pixels)

**Logic**:
- If height ≤ 480: return `"480p"`
- If height ≤ 576: return `"576p"`
- If height ≤ 720: return `"720p"`
- If height ≤ 1080: return `"1080p"`
- If height ≤ 1440: return `"1440p (2K)"`
- If height ≤ 2160: return `"2160p (4K)"`
- Else: return `"{height}p"` (e.g., "4320p" for 8K)

#### Get-HandBrakePreset

**Purpose**: Select appropriate preset based on resolution

**Logic**:
- If height ≤ 480: return `"Fast 480p30"` (SD content)
- If height ≥ 720: return `"Fast 1080p30"` (HD content)
- Else: return `"Fast 1080p30"` (default for in-between cases)

#### Get-PerformanceData

**Purpose**: Load historical performance metrics from JSON file

**Process**:
1. Check if `$PerformanceDataFile` exists
2. If exists:
   - Read file content
   - Parse as JSON
   - Return as object
3. If not exists or error: return `$null`

#### Save-PerformanceData

**Purpose**: Save performance metrics to JSON file

**Parameters**:
- `MbitsPerMinute`: Double (encoding rate)
- `TotalConversions`: Integer (conversion count)

**Process**:
1. Create hashtable with:
   - `MbitsPerMinute`
   - `TotalConversions`
   - `LastUpdated`: Current timestamp in ISO 8601 format
2. Convert to JSON
3. Write to `$PerformanceDataFile`

#### Update-PerformanceMetrics

**Purpose**: Update performance data with new conversion result

**Parameters**:
- `SourceSizeBytes`: Long (source file size)
- `ConversionTimeMinutes`: Double (elapsed time)

**Process**:
1. If `ConversionTimeMinutes` ≤ 0: return (invalid data)
2. Calculate current encoding rate:
   - Convert source size to megabits: `(SourceSizeBytes * 8) / 1MB`
   - Divide by conversion time: `sourceSizeMbits / ConversionTimeMinutes`
3. Load existing performance data
4. If no existing data:
   - Save current rate as first data point
   - Set `TotalConversions = 1`
5. If existing data exists:
   - Calculate weighted average:
     - Weight for existing data: `Min(0.8, TotalConversions / (TotalConversions + 1))`
     - New rate = `(existingRate * weight) + (currentRate * (1 - weight))`
   - Increment `TotalConversions`
   - Save updated data

**Rationale**: Weighted average (80% historical, 20% new) provides stability while adapting to system performance changes.

#### Get-EstimatedMp4Size

**Purpose**: Estimate final MP4 file size

**Parameters**:
- `InputPath`: String (source MKV path)
- `Height`: Integer (video resolution height)

**Process**:
1. Get source file size in bytes
2. Determine compression ratio based on resolution:
   - If height ≤ 480: ratio = 0.55 (SD content compresses better)
   - Else: ratio = 0.65 (HD content)
3. Calculate: `estimatedSize = sourceSize * compressionRatio`
4. Return as long integer

**Rationale**: RF 18 quality typically produces 50-70% of source size for MKV→MP4 conversion.

#### Get-EstimatedConversionTime

**Purpose**: Estimate conversion duration

**Parameters**:
- `InputPath`: String (source MKV path)
- `Height`: Integer (video resolution height)

**Process**:
1. Get source file size in bytes
2. Load performance data
3. If historical data exists and valid:
   - Convert source size to megabits
   - Divide by `MbitsPerMinute` from historical data
   - Return estimated minutes
4. If no historical data (fallback):
   - Convert source size to GB
   - Determine minutes per GB based on resolution:
     - Height ≤ 480: 2.5 minutes/GB
     - Height ≤ 720: 3.5 minutes/GB
     - Height > 720: 5 minutes/GB
   - Calculate: `estimatedMinutes = sourceSizeGB * minutesPerGB`
   - Return estimated minutes

**Rationale**: Historical data provides accurate system-specific estimates; fallback assumes moderate CPU performance.

#### Convert-MkvToMp4

**Purpose**: Execute HandBrake conversion with full error handling

**Parameters**:
- `InputPath`: String (source MKV path)
- `OutputPath`: String (target MP4 path)
- `Preset`: String (HandBrake preset name)

**Process**:
1. Generate temporary output path: change extension to `.mp_`
2. Display conversion start message
3. Clean up any existing `.mp_` file from previous interrupted conversion
4. Get source file size for performance tracking
5. Build HandBrake arguments array:
   - `--preset "$Preset"`
   - `-e x264` (H.264 encoder)
   - `-q 18` (RF 18 quality)
   - `-O` (web optimized)
   - `--audio-copy-mask ac3` (AC3 passthrough)
   - `--audio-fallback av_aac` (AAC fallback for non-AC3)
   - `-i "$InputPath"`
   - `-o "$tempOutputPath"`
6. Start timer
7. Execute HandBrakeCLI:
   - Use `Start-Process` with `-Wait` and `-PassThru`
   - Redirect stdout to `$env:TEMP\handbrake_out.log`
   - Redirect stderr to `$env:TEMP\handbrake_err.log`
8. Stop timer, calculate elapsed minutes
9. Check exit code:
   - If 0 (success):
     - Verify temp file exists
     - Rename `.mp_` to `.mp4`
     - Call `Update-PerformanceMetrics`
     - Display success message with elapsed time
     - Return `$true`
   - If non-zero (failure):
     - Display warning with exit code
     - Delete temp file if exists
     - Return `$false`
10. On exception:
    - Display error
    - Delete temp file if exists
    - Return `$false`

## Rules & Constraints

### File Naming Conventions

1. **Source files**: Must have `.mkv` extension (case-insensitive via `Get-ChildItem -Filter`)
2. **Target files**: Use `.mp4` extension with same base name as source
3. **Temporary conversion files**: Use `.mp_` extension during encoding
4. **Hidden files**: Use `.mk_` extension when hiding from Plex
5. **Media file types scanned in space mode**: `.mp4`, `.mp_`, `.mkv`, `.mk_`
6. **File paths**: Must handle spaces correctly (quote paths in HandBrake arguments)

### Conversion Settings

1. **Video codec**: H.264 (`-e x264`)
2. **Quality**: RF 18 (`-q 18`) — high quality, visually lossless
3. **Optimization**: Web optimized (`-O`) — enables fast-start for streaming
4. **Audio handling**:
   - AC3 audio: Passthrough (`--audio-copy-mask ac3`)
   - Other audio: Convert to AAC (`--audio-fallback av_aac`)
5. **Preset selection**:
   - SD (≤480p): `"Fast 480p30"`
   - HD (≥720p): `"Fast 1080p30"`

### Error Handling

1. **HandBrakeCLI not found**: Exit with error code 1, display clear message
2. **Invalid path**: Exit with error code 1, display error message
3. **Video height detection failure**: Log warning, skip file, increment failed counter
4. **Conversion failure**: Clean up temporary `.mp_` file, log warning, increment failed counter
5. **Interrupted conversion**: Existing `.mp_` files cleaned up before retry
6. **File I/O errors**: Catch exceptions, log warnings, continue with next file

### Performance Tracking

1. **Metric**: Megabits per minute (Mbits/minute)
2. **Formula**: `(sourceSize * 8 / 1MB) / conversionTimeMinutes`
3. **Update algorithm**: Weighted average with 80% weight on historical data
4. **Persistence**: JSON file in script directory
5. **Usage**: Prefer historical data over default estimates when available

### Idempotency

1. **Check mode**: Can be run multiple times without side effects
2. **Convert mode**: Skips files where target `.mp4` already exists
3. **Hide mode**: Renames `.mkv` to `.mk_`; subsequent runs find no `.mkv` files
4. **Show mode**: Renames `.mk_` to `.mkv`; subsequent runs find no `.mk_` files
5. **Find mode**: Read-only operation, no modifications
6. **Space mode**: Read-only operation, no modifications

### Disk Space Safety

1. **Check mode**: Calculates required space and compares to available space
2. **Warning display**: Shows shortage in GB if insufficient space
3. **Success display**: Shows remaining space in GB if sufficient space
4. **No automatic blocking**: Script doesn't prevent conversion if space is low (user decision)

### Console Output Standards

1. **Color coding**:
   - Yellow: Headers, warnings, instructions
   - Cyan: Informational (mode, estimates, counts, file sizes)
   - Blue: Space mode
   - Green: Success messages, grand totals
   - Red: Errors, failures, space shortage
   - Gray: Secondary details (presets, rates, times, file counts)
   - Magenta: Find mode
   - DarkGray: Skipped files
   - White: Section labels in space mode
2. **Progress messages**: Display current file being processed
3. **Summary format**: Consistent header with `===` borders
4. **Relative paths**: Show relative paths in find mode for readability

### Dependencies

1. **Required**:
   - PowerShell 5.1 or higher
   - HandBrakeCLI.exe at specified path
   - Read/write access to target directories
2. **Optional**:
   - Performance data file (created automatically)

## Regeneration Instructions

To recreate this script from scratch:

### Step 1: Create Script Structure

Create a PowerShell script file (`Convert-MkvToMp4.ps1`) with:
1. Comment-based help block (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.NOTES`)
2. Parameter block with Mode and Path parameters
3. Configuration variables section
4. Validation of HandBrakeCLI existence
5. Path validation and resolution

### Step 2: Implement Helper Functions

Implement the following functions in order (see detailed specifications in Processing Steps section):
1. `Get-VideoHeight` — scan MKV file for resolution
2. `Get-HandBrakePreset` — select preset based on height
3. `Get-PerformanceData` — load historical performance metrics
4. `Save-PerformanceData` — save performance metrics
5. `Update-PerformanceMetrics` — update metrics with weighted average
6. `Get-EstimatedMp4Size` — estimate output file size
7. `Get-EstimatedConversionTime` — estimate conversion duration
8. `Convert-MkvToMp4` — execute HandBrake conversion

### Step 3: Implement Main Script Logic

1. **Header display**: Show title, mode, and target directory
2. **Mode routing**: Implement conditional logic for each mode:
   - `space`: Scan for all media files (`.mp4`, `.mp_`, `.mkv`, `.mk_`), calculate sizes, display summary, exit
   - `hide`: Rename `.mkv` → `.mk_`, display summary, exit
   - `show`: Rename `.mk_` → `.mkv`, display summary, exit
   - `find`, `check`, `convert`: Continue to file processing loop

### Step 4: Implement File Processing Loop

1. Find all `.mkv` files recursively using `Get-ChildItem -Recurse -Filter "*.mkv"`
2. Exit if no files found
3. Initialize counters based on mode requirements
4. Loop through each MKV file:
   - Generate MP4 path using `[IO.Path]::ChangeExtension()`
   - Check if MP4 exists
   - Branch based on mode:
     - **find**: Display files with existing MP4
     - **check**: Analyze files, accumulate estimates
     - **convert**: Execute conversion for files without MP4
5. Handle detection failures gracefully

### Step 5: Implement Summary Display

Create mode-specific summary sections:
1. **find**: Count of files with/without MP4, total MP4 size
2. **check**: Detailed estimates including:
   - File counts
   - Total estimated size
   - Total estimated time with source indicator
   - Encoding rate if available
   - Disk space analysis
   - Instructions for convert mode
3. **convert**: Conversion statistics (converted, skipped, failed)
4. **hide/show**: Rename operation counts

### Step 6: Test Scenarios

Ensure the script handles:
1. Empty directories (no MKV files)
2. Paths with spaces
3. Mixed resolutions (SD and HD)
4. Existing MP4 files (idempotency)
5. Interrupted conversions (temp file cleanup)
6. Missing HandBrakeCLI
7. Invalid paths
8. First run (no performance data)
9. Subsequent runs (using performance data)

### Step 7: Code Quality

Ensure:
1. Consistent indentation (4 spaces)
2. Descriptive variable names
3. Comments for complex logic
4. Error handling with try-catch where appropriate
5. Proper use of PowerShell idioms (e.g., `-ErrorAction`, `$null` checks)
6. Color-coded output for user experience
7. Informative progress messages

### Key Implementation Notes

1. **Regex patterns**: Use `\+\s+size:\s+(\d+)x(\d+)` as primary pattern for HandBrake scan output
2. **File extension changes**: Always use `[IO.Path]::ChangeExtension()` for safety
3. **Path handling**: Use `[IO.Path]::GetFileName()` when renaming to avoid path issues
4. **Process execution**: Use `Start-Process` with `-Wait`, `-PassThru`, and output redirection
5. **JSON handling**: Use `ConvertFrom-Json` and `ConvertTo-Json` with `-Raw` flag for file I/O
6. **Weighted average**: Use `[Math]::Min(0.8, ratio)` to cap weight at 80%
7. **Time formatting**: Display hours and minutes when time ≥ 60 minutes
8. **Size formatting**: Display GB when size ≥ 1 GB, otherwise MB
9. **Relative paths**: Use `String.Replace()` and `TrimStart('\')` for clean display
10. **Exit codes**: Use `exit 0` for success, `exit 1` for errors

This document provides complete instructions to regenerate the PowerShell script without reference to existing code. All logic, formulas, constants, and design decisions are documented explicitly.

---

## Subtitle and Audio Requirements

Added after the sections above. These are requirements, not history - a
regenerated script must satisfy them.

### Audio selection

1. Choose the source audio track with the **most channels**, breaking ties toward
   a codec MP4 can pass through (`ac3`, `eac3`). Do **not** assume track 1: disc
   track order varies and some titles list stereo before 5.1.
2. Emit two output tracks from that source track: the original (passed through
   where possible) and an AAC stereo compatibility track.
3. Where passthrough is impossible (DTS, TrueHD, LPCM), encode to **AC3**, not
   AAC. Multichannel AAC cannot be bitstreamed over S/PDIF.
4. Scale the AC3 bitrate by channel count: 192k for 1 channel, 256k for 2,
   640k for 6 or more (640k is AC3's ceiling).

### Subtitle handling

1. Select English subtitle tracks explicitly (`--subtitle-lang-list eng`,
   `--all-subtitles`) and burn none in. HandBrake's preset default is
   "Foreign Audio Search", which passes nothing through.
2. Write a sidecar `.srt` for any text subtitle track in the source.
3. Extract PGS/DVB tracks to a `.sup` beside the **output**, since MP4 cannot
   carry them and the source is usually deleted afterwards.
4. After each conversion, report source track count vs output track count, and
   state plainly when the result has no subtitles at all.

### Modes

- `backfill` - write sidecar `.srt` files for previously converted videos, from a
  surviving `.mkv`/`.mk_` or from an embedded text track. Must work when there is
  no paired MP4. Skip titles that already have a sidecar or embedded text unless
  overridden.
- `cleanup` - must **refuse** to delete a source whose subtitles are absent from
  the replacement, unless explicitly overridden. A size check cannot detect a
  conversion that silently dropped them, and the source is the last copy.

### Switches

`-Container mp4|mkv`, `-NoSidecar`, `-NoSup`, `-IncludeEmbedded`,
`-SkipSubtitleGuard`.

### External dependencies

ffmpeg and ffprobe, auto-discovered. The script must degrade gracefully when
they are absent: conversion still works, subtitle handling and best-track
selection do not.