<#
.SYNOPSIS
    Converts MKV files to MP4 using HandBrakeCLI with automatic preset selection.

.DESCRIPTION
    Recursively scans the current directory for .mkv files and converts them to .mp4
    if the .mp4 doesn't already exist. Automatically selects the appropriate HandBrake
    preset based on video resolution (480p or 1080p).

.PARAMETER Mode
    Operation mode: "check" (default) to scan and estimate, "convert" to perform conversions, "find" to list files that already have MP4s, "hide" to rename .mkv to .mk_ (hide from Plex), "show" to rename .mk_ back to .mkv, "space" to analyze disk space usage of media files, "report" to generate a report of MP4 files with resolution information, "cleanup" to remove .mk_ files that have a valid .mp4 replacement in the same folder, or "backfill" to write sidecar .srt files for already-converted videos whose .mkv/.mk_ source still exists.

.PARAMETER Path
    The directory path to scan. Defaults to the current directory if not specified.

.NOTES
    - Requires HandBrakeCLI.exe to be installed
    - Requires ffmpeg/ffprobe for sidecar subtitle extraction (backfill mode)
    - Uses H.264 encoding with RF 18 quality
    - Web-optimized MP4 output
    - Keeps the original surround track (AC3/E-AC3 passthrough) plus an AAC
      stereo compatibility track
    - Passes through English subtitles and writes sidecar .srt files.
      NOTE: MP4 cannot store VobSub (DVD) or PGS (Blu-ray) bitmap subtitles.
      Use -Container mkv to preserve those as selectable tracks.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "convert", "find", "hide", "show", "space", "report", "cleanup", "backfill")]
    [string]$Mode = "check",
    
    [Parameter(Position = 1)]
    [string]$Path = (Get-Location).Path,

    # Output container. "mp4" keeps the existing pipeline (text subtitles only -
    # MP4 cannot carry VobSub/PGS bitmap subtitles). "mkv" preserves every
    # subtitle track including bitmap ones, at the same encoded file size.
    [Parameter()]
    [ValidateSet("mp4", "mkv")]
    [string]$Container = "mp4",

    # Skip writing sidecar .srt files during convert/backfill.
    [Parameter()]
    [switch]$NoSidecar,

    # Allow cleanup to delete sources whose subtitles did not survive conversion.
    [Parameter()]
    [switch]$SkipSubtitleGuard,

    # Write a sidecar even when the playable file already has an embedded text
    # subtitle track. Off by default: such files already work in Plex, and the
    # sidecar would be redundant.
    [Parameter()]
    [switch]$IncludeEmbedded
)

# Configuration
$HandBrakeCLI = "C:\Tools\HandBrake\HandBrakeCLI.exe"
$PerformanceDataFile = "$PSScriptRoot\handbrake_performance.json"
$OutputExtension = ".$Container"

# Locate ffmpeg/ffprobe - used for sidecar subtitle extraction only.
function Find-Tool {
    param([string]$Name)
    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = @(
        "C:\Tools\ffmpeg\bin\$Name.exe",
        "C:\Tools\ffmpeg\$Name.exe",
        "C:\ffmpeg\bin\$Name.exe",
        "C:\Program Files\ffmpeg\bin\$Name.exe",
        "C:\Program Files\DVDFab\StreamFab\$Name.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

$FFmpeg  = Find-Tool -Name "ffmpeg"
$FFprobe = Find-Tool -Name "ffprobe"
$SubtitleToolsAvailable = ($null -ne $FFmpeg) -and ($null -ne $FFprobe)

# Verify HandBrakeCLI exists
if (-not (Test-Path $HandBrakeCLI)) {
    Write-Error "HandBrakeCLI not found at: $HandBrakeCLI"
    Write-Error "Please install HandBrakeCLI or update the path in the script."
    exit 1
}

# Function to detect video height from MKV file
function Get-VideoHeight {
    param (
        [string]$FilePath
    )
    
    try {
        # Use HandBrakeCLI --scan to get video information
        # Redirect stderr to stdout and capture, suppressing console output
        $scanOutput = & $HandBrakeCLI --scan --input "$FilePath" 2>&1 | Out-String
        
        # Parse the output for resolution information
        # Look for patterns like "1920x1080" or "720x480"
        if ($scanOutput -match '\+\s+size:\s+(\d+)x(\d+)') {
            $height = [int]$Matches[2]
            return $height
        }
        elseif ($scanOutput -match '(\d+)x(\d+)') {
            $height = [int]$Matches[2]
            return $height
        }
        else {
            Write-Warning "Could not detect video height for: $FilePath"
            return $null
        }
    }
    catch {
        Write-Warning "Error scanning file: $FilePath - $_"
        return $null
    }
}

# Function to get video format label from height
function Get-VideoFormatLabel {
    param (
        [int]$Height
    )
    
    if ($Height -le 480) {
        return "480p"
    }
    elseif ($Height -le 576) {
        return "576p"
    }
    elseif ($Height -le 720) {
        return "720p"
    }
    elseif ($Height -le 1080) {
        return "1080p"
    }
    elseif ($Height -le 1440) {
        return "1440p (2K)"
    }
    elseif ($Height -le 2160) {
        return "2160p (4K)"
    }
    else {
        return "${Height}p"
    }
}

# Function to select appropriate HandBrake preset based on height
function Get-HandBrakePreset {
    param (
        [int]$Height
    )
    
    if ($Height -le 480) {
        return "Fast 480p30"
    }
    elseif ($Height -ge 720) {
        return "Fast 1080p30"
    }
    else {
        # Default to 1080p for anything in between
        return "Fast 1080p30"
    }
}

# Function to load performance data
function Get-PerformanceData {
    if (Test-Path $PerformanceDataFile) {
        try {
            $data = Get-Content $PerformanceDataFile -Raw | ConvertFrom-Json
            return $data
        }
        catch {
            Write-Warning "Could not load performance data: $_"
            return $null
        }
    }
    return $null
}

# Function to save performance data
function Save-PerformanceData {
    param (
        [double]$MbitsPerMinute,
        [int]$TotalConversions
    )
    
    try {
        $data = @{
            MbitsPerMinute = $MbitsPerMinute
            TotalConversions = $TotalConversions
            LastUpdated = (Get-Date).ToString("o")
        }
        $data | ConvertTo-Json | Set-Content $PerformanceDataFile -Force
    }
    catch {
        Write-Warning "Could not save performance data: $_"
    }
}

# Function to update performance metrics
function Update-PerformanceMetrics {
    param (
        [long]$SourceSizeBytes,
        [double]$ConversionTimeMinutes
    )
    
    if ($ConversionTimeMinutes -le 0) {
        return
    }
    
    # Calculate Mbits per minute for this conversion
    $sourceSizeMbits = ($SourceSizeBytes * 8) / 1MB
    $currentRate = $sourceSizeMbits / $ConversionTimeMinutes
    
    # Load existing performance data
    $perfData = Get-PerformanceData
    
    if ($null -eq $perfData) {
        # First conversion - use current rate
        Save-PerformanceData -MbitsPerMinute $currentRate -TotalConversions 1
    }
    else {
        # Calculate weighted average (more weight on recent data)
        # Use 80% existing + 20% new for stability with adaptation
        $totalConversions = $perfData.TotalConversions + 1
        $weight = [Math]::Min(0.8, ($perfData.TotalConversions / ($totalConversions * 1.0)))
        $newRate = ($perfData.MbitsPerMinute * $weight) + ($currentRate * (1 - $weight))
        
        Save-PerformanceData -MbitsPerMinute $newRate -TotalConversions $totalConversions
    }
}

# Function to estimate MP4 file size
function Get-EstimatedMp4Size {
    param (
        [string]$InputPath,
        [int]$Height
    )
    
    try {
        # Get source file size
        $sourceSize = (Get-Item $InputPath).Length
        
        # Estimation logic based on RF 18 compression
        # RF 18 is high quality, typically results in 50-70% of source size for MKV->MP4
        # Lower resolution gets slightly better compression
        if ($Height -le 480) {
            # SD content compresses better
            $compressionRatio = 0.55
        }
        else {
            # HD content
            $compressionRatio = 0.65
        }
        
        $estimatedSize = [long]($sourceSize * $compressionRatio)
        return $estimatedSize
    }
    catch {
        Write-Warning "Could not estimate size for: $InputPath"
        return 0
    }
}

# Function to estimate conversion time
function Get-EstimatedConversionTime {
    param (
        [string]$InputPath,
        [int]$Height
    )
    
    try {
        $sourceSize = (Get-Item $InputPath).Length
        
        # Try to use historical performance data
        $perfData = Get-PerformanceData
        
        if ($null -ne $perfData -and $perfData.MbitsPerMinute -gt 0) {
            # Use actual measured performance
            $sourceSizeMbits = ($sourceSize * 8) / 1MB
            $estimatedMinutes = $sourceSizeMbits / $perfData.MbitsPerMinute
            return $estimatedMinutes
        }
        else {
            # Fall back to default estimates if no historical data
            $sourceSizeGB = $sourceSize / 1GB
            
            # Estimation logic based on typical encoding speeds
            # These are rough estimates and vary by CPU performance
            # Assumes moderate CPU (e.g., Intel i5/i7 or Ryzen 5/7)
            # Times are in minutes per GB
            if ($Height -le 480) {
                # SD content encodes faster: ~2-3 minutes per GB
                $minutesPerGB = 2.5
            }
            elseif ($Height -le 720) {
                # 720p content: ~3-4 minutes per GB
                $minutesPerGB = 3.5
            }
            else {
                # 1080p content: ~4-6 minutes per GB
                $minutesPerGB = 5
            }
            
            $estimatedMinutes = $sourceSizeGB * $minutesPerGB
            return $estimatedMinutes
        }
    }
    catch {
        Write-Warning "Could not estimate time for: $InputPath"
        return 0
    }
}

# Function to convert MKV to MP4
# Text-based subtitle codecs that can be written straight out as SRT.
$script:TextSubtitleCodecs = @("subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt")

# Returns the subtitle streams of a media file as objects with
# Index / Codec / Language / IsText / Forced / HearingImpaired.
function Get-SubtitleStreams {
    param([string]$FilePath)

    if (-not $SubtitleToolsAvailable) { return @() }

    try {
        $json = & $FFprobe -v error `
            -show_entries "stream=index,codec_type,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired" `
            -of json "$FilePath" 2>$null | Out-String

        if ([string]::IsNullOrWhiteSpace($json)) { return @() }
        $parsed = $json | ConvertFrom-Json

        $result = @()
        foreach ($s in $parsed.streams) {
            if ($s.codec_type -ne "subtitle") { continue }
            $lang = if ($s.tags.language) { $s.tags.language } else { "und" }
            $result += [PSCustomObject]@{
                Index            = [int]$s.index
                Codec            = $s.codec_name
                Language         = $lang
                Title            = $s.tags.title
                IsText           = ($script:TextSubtitleCodecs -contains $s.codec_name)
                Forced           = ([int]$s.disposition.forced -eq 1)
                HearingImpaired  = ([int]$s.disposition.hearing_impaired -eq 1)
            }
        }
        return $result
    }
    catch {
        Write-Verbose "Could not probe subtitles in ${FilePath}: $_"
        return @()
    }
}

# Extracts every English text subtitle track from $SourcePath into sidecar .srt
# files named after $VideoPath (Plex convention: <video basename>.en.srt).
# Returns a result object describing what happened.
function Export-SidecarSubtitles {
    param(
        [string]$SourcePath,   # the .mkv / .mk_ holding the subtitle data
        [string]$VideoPath,    # the video the sidecar should sit beside
        [switch]$Force
    )

    $outcome = [PSCustomObject]@{
        Source       = $SourcePath
        Written      = @()
        Skipped      = 0
        BitmapOnly   = $false
        TextTracks   = 0
        Error        = $null
    }

    if (-not $SubtitleToolsAvailable) {
        $outcome.Error = "ffmpeg/ffprobe not found"
        return $outcome
    }

    $subs = Get-SubtitleStreams -FilePath $SourcePath
    if ($subs.Count -eq 0) { return $outcome }

    $english = @($subs | Where-Object { $_.Language -in @("eng", "en") })
    # If nothing is tagged English, fall back to untagged tracks - single-language
    # discs frequently leave the language field empty.
    if ($english.Count -eq 0) {
        $english = @($subs | Where-Object { $_.Language -in @("und", "") })
    }

    $textTracks = @($english | Where-Object { $_.IsText })
    $outcome.TextTracks = $textTracks.Count

    if ($textTracks.Count -eq 0) {
        $outcome.BitmapOnly = ($english.Count -gt 0)
        return $outcome
    }

    $baseDir  = [IO.Path]::GetDirectoryName($VideoPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($VideoPath)

    $n = 0
    foreach ($t in $textTracks) {
        $n++
        # First track gets the plain .en.srt name Plex prefers; extra tracks are
        # disambiguated so they do not collide.
        $suffix = if ($n -eq 1) { "en" } else { "en.$n" }
        if ($t.HearingImpaired -and $n -eq 1 -and $textTracks.Count -gt 1) { $suffix = "en.sdh" }
        if ($t.Forced) { $suffix = "en.forced" }

        $srtPath = Join-Path $baseDir "$baseName.$suffix.srt"

        if ((Test-Path $srtPath) -and -not $Force) {
            $outcome.Skipped++
            continue
        }

        & $FFmpeg -v error -y -i "$SourcePath" -map "0:$($t.Index)" -c:s srt "$srtPath" 2>$null

        if ((Test-Path $srtPath) -and ((Get-Item $srtPath).Length -gt 0)) {
            $outcome.Written += $srtPath
        }
        else {
            if (Test-Path $srtPath) { Remove-Item $srtPath -Force -ErrorAction SilentlyContinue }
            $outcome.Error = "extraction produced no output for stream $($t.Index)"
        }
    }

    return $outcome
}

# Decides whether it is safe to delete $SourcePath now that $ReplacementPath
# exists. Deleting a source is irreversible and the subtitle data lives ONLY in
# the source, so this errs toward refusing.
# Returns $null when safe, or a string describing what would be lost.
function Get-SubtitleLossReason {
    param(
        [string]$SourcePath,
        [string]$ReplacementPath
    )

    if (-not $SubtitleToolsAvailable) {
        return "cannot verify - ffmpeg/ffprobe not found"
    }

    $sourceSubs = Get-SubtitleStreams -FilePath $SourcePath
    if ($sourceSubs.Count -eq 0) { return $null }   # nothing to lose

    # A sidecar .srt beside the replacement counts as preserved.
    $baseDir  = [IO.Path]::GetDirectoryName($ReplacementPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($ReplacementPath)
    $sidecars = @(Get-ChildItem -Path $baseDir -Filter "$baseName*.srt" -File -ErrorAction SilentlyContinue)
    if ($sidecars.Count -gt 0) { return $null }

    # An embedded subtitle track in the replacement counts as preserved.
    $destSubs = Get-SubtitleStreams -FilePath $ReplacementPath
    if ($destSubs.Count -gt 0) { return $null }

    $kinds = ($sourceSubs.Codec | Sort-Object -Unique) -join ", "
    return "source has $($sourceSubs.Count) subtitle track(s) [$kinds]; replacement has none and no sidecar .srt exists"
}

# Finds the .mkv or .mk_ that a converted video came from, if it still exists.
function Get-SourceForVideo {
    param([string]$VideoPath)

    $baseDir  = [IO.Path]::GetDirectoryName($VideoPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($VideoPath)

    foreach ($ext in @(".mkv", ".mk_")) {
        $candidate = Join-Path $baseDir "$baseName$ext"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Convert-MkvToMp4 {
    param (
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Preset
    )
    
    try {
        # Use temporary extension .mp_ during conversion
        $tempOutputPath = [IO.Path]::ChangeExtension($OutputPath, ".mp_")
        # HandBrake picks the muxer from -f, but honours the output extension for
        # some container defaults; keep the temp name aligned with the real one.
        
        Write-Host "Converting: $InputPath" -ForegroundColor Cyan
        Write-Host "Using preset: $Preset" -ForegroundColor Gray
        
        # Clean up any existing temp file from previous interrupted conversion
        if (Test-Path $tempOutputPath) {
            Write-Host "Removing previous incomplete conversion..." -ForegroundColor Yellow
            Remove-Item $tempOutputPath -Force
        }
        
        # Get source file size for performance tracking
        $sourceSize = (Get-Item $InputPath).Length
        
        # Build HandBrake command
        # -e x264 / -q 18: H.264 at RF 18
        # -O: web optimized (mp4 only)
        #
        # Audio: emit two tracks from source track 1 - the original surround
        # stream passed through untouched, plus an AAC stereo compatibility
        # track. The preset alone would have produced stereo AAC only, silently
        # discarding 5.1.
        #
        # Subtitles: the presets default to "Foreign Audio Search", which passes
        # nothing through unless forced subs are detected. Select every English
        # track explicitly and burn none of them in.
        $copyMask = if ($Container -eq "mkv") { "ac3,eac3,dts,dtshd,truehd" } else { "ac3,eac3" }

        $arguments = @(
            "--preset", "`"$Preset`"",
            "-e", "x264",
            "-q", "18",
            "-f", $(if ($Container -eq "mkv") { "av_mkv" } else { "av_mp4" }),
            "-a", "1,1",
            "-E", "copy,av_aac",
            "--mixdown", "5point1,stereo",
            "--aname", "`"Surround,Stereo`"",
            "--audio-copy-mask", $copyMask,
            "--audio-fallback", "av_aac",
            "--subtitle-lang-list", "eng",
            "--all-subtitles",
            "--subtitle-burned=none",
            "--subtitle-default=none"
        )
        if ($Container -eq "mp4") { $arguments += "-O" }
        $arguments += @(
            "-i", "`"$InputPath`"",
            "-o", "`"$tempOutputPath`""
        )
        
        # Start timer
        $startTime = Get-Date
        
        # Redirect output to reduce console clutter
        # stdout and stderr are redirected to $null
        $process = Start-Process -FilePath $HandBrakeCLI `
                                 -ArgumentList $arguments `
                                 -NoNewWindow `
                                 -Wait `
                                 -PassThru `
                                 -RedirectStandardOutput "$env:TEMP\handbrake_out.log" `
                                 -RedirectStandardError "$env:TEMP\handbrake_err.log"
        
        # Calculate elapsed time
        $endTime = Get-Date
        $elapsedMinutes = ($endTime - $startTime).TotalMinutes
        
        if ($process.ExitCode -eq 0) {
            # Conversion successful, rename temp file to final .mp4
            if (Test-Path $tempOutputPath) {
                Rename-Item -Path $tempOutputPath -NewName ([IO.Path]::GetFileName($OutputPath)) -Force
                
                # Write sidecar .srt alongside the output - the most reliable
                # subtitle path in Plex (direct-plays on every client, never
                # forces a transcode).
                if (-not $NoSidecar) {
                    $null = Export-SidecarSubtitles -SourcePath $InputPath -VideoPath $OutputPath
                }

                # Update performance metrics
                Update-PerformanceMetrics -SourceSizeBytes $sourceSize -ConversionTimeMinutes $elapsedMinutes
                
                $elapsedFormatted = "{0:N1}" -f $elapsedMinutes
                Write-Host "✓ Successfully converted: $OutputPath" -ForegroundColor Green
                Write-Host "  Conversion time: $elapsedFormatted minutes" -ForegroundColor Gray
                return $true
            }
            else {
                Write-Warning "Conversion reported success but temp file not found: $tempOutputPath"
                return $false
            }
        }
        else {
            Write-Warning "HandBrake returned exit code $($process.ExitCode) for: $InputPath"
            # Clean up incomplete temp file
            if (Test-Path $tempOutputPath) {
                Remove-Item $tempOutputPath -Force -ErrorAction SilentlyContinue
            }
            return $false
        }
    }
    catch {
        Write-Error "Error converting file: $InputPath - $_"
        # Clean up incomplete temp file
        $tempOutputPath = [IO.Path]::ChangeExtension($OutputPath, ".mp_")
        if (Test-Path $tempOutputPath) {
            Remove-Item $tempOutputPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# Main script
Write-Host "=================================" -ForegroundColor Yellow
Write-Host "MKV to MP4 Batch Converter" -ForegroundColor Yellow
Write-Host "=================================" -ForegroundColor Yellow
$modeColor = switch ($Mode) {
    "convert" { "Green" }
    "find" { "Magenta" }
    "hide" { "Yellow" }
    "show" { "Yellow" }
    "space" { "Blue" }
    "cleanup" { "Red" }
    default { "Cyan" }
}
Write-Host "Mode: $Mode" -ForegroundColor $modeColor
Write-Host ""

# Validate and resolve the path
if (-not (Test-Path $Path)) {
    Write-Error "Path does not exist: $Path"
    exit 1
}

$currentDir = (Resolve-Path $Path).Path
Write-Host "Scanning directory: $currentDir" -ForegroundColor Cyan
Write-Host ""

# Handle report mode - generate report of MP4 files with resolution information
if ($Mode -eq "report") {
    Write-Host "Generating MP4 report..." -ForegroundColor Cyan
    Write-Host ""
    
    $reportPath = Join-Path $currentDir "report.txt"
    $reportLines = @()
    
    # Get all subdirectories in the current directory
    $folders = Get-ChildItem -Path $currentDir -Directory | Sort-Object Name
    
    $totalFolders = 0
    $totalMp4Files = 0
    
    foreach ($folder in $folders) {
        # Find all MP4 files in this folder (non-recursive, only immediate children)
        $mp4Files = Get-ChildItem -Path $folder.FullName -Filter "*.mp4" -File -ErrorAction SilentlyContinue
        
        if ($mp4Files.Count -gt 0) {
            $totalFolders++
            $totalMp4Files += $mp4Files.Count
            
            # Add folder header to report
            $reportLines += ""
            $reportLines += "=" * 80
            $reportLines += "Folder: $($folder.Name)"
            $reportLines += "=" * 80
            
            Write-Host "Scanning: $($folder.Name)" -ForegroundColor Yellow
            
            foreach ($mp4 in $mp4Files) {
                Write-Host "  Analyzing: $($mp4.Name)" -ForegroundColor Gray
                
                # Get video height
                $height = Get-VideoHeight -FilePath $mp4.FullName
                
                if ($null -ne $height) {
                    $formatLabel = Get-VideoFormatLabel -Height $height
                    $reportLines += "  $($mp4.Name) - $formatLabel"
                }
                else {
                    $reportLines += "  $($mp4.Name) - (Unable to detect resolution)"
                }
            }
        }
    }
    
    # Add summary at the end
    $reportLines += ""
    $reportLines += "=" * 80
    $reportLines += "Summary"
    $reportLines += "=" * 80
    $reportLines += "Total folders with MP4 files: $totalFolders"
    $reportLines += "Total MP4 files: $totalMp4Files"
    $reportLines += "Report generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    
    # Write report to file
    $reportLines | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    
    Write-Host ""
    Write-Host "=================================" -ForegroundColor Green
    Write-Host "Report Complete" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green
    Write-Host "Folders scanned: $totalFolders" -ForegroundColor Cyan
    Write-Host "MP4 files found: $totalMp4Files" -ForegroundColor Cyan
    Write-Host "Report saved to: $reportPath" -ForegroundColor White
    Write-Host ""
    exit 0
}

# Handle space mode - analyze disk usage of media files
if ($Mode -eq "space") {
    Write-Host "Scanning for media files..." -ForegroundColor Cyan
    Write-Host ""
    
    # Find all media files
    $mp4Files = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mp4" -File -ErrorAction SilentlyContinue
    $mp_Files = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mp_" -File -ErrorAction SilentlyContinue
    $mkvFiles = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mkv" -File -ErrorAction SilentlyContinue
    $mk_Files = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mk_" -File -ErrorAction SilentlyContinue
    
    # Calculate total sizes
    $mp4Size = ($mp4Files | Measure-Object -Property Length -Sum).Sum
    $mp_Size = ($mp_Files | Measure-Object -Property Length -Sum).Sum
    $mkvSize = ($mkvFiles | Measure-Object -Property Length -Sum).Sum
    $mk_Size = ($mk_Files | Measure-Object -Property Length -Sum).Sum
    
    # Handle null values for empty collections
    if ($null -eq $mp4Size) { $mp4Size = 0 }
    if ($null -eq $mp_Size) { $mp_Size = 0 }
    if ($null -eq $mkvSize) { $mkvSize = 0 }
    if ($null -eq $mk_Size) { $mk_Size = 0 }
    
    $grandTotal = $mp4Size + $mp_Size + $mkvSize + $mk_Size
    
    # Display results
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Space Usage Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host ""
    
    # MP4 files
    $mp4GB = [math]::Round($mp4Size / 1GB, 2)
    $mp4MB = [math]::Round($mp4Size / 1MB, 2)
    Write-Host "MP4 files (.mp4):" -ForegroundColor White
    Write-Host "  Count: $($mp4Files.Count)" -ForegroundColor Gray
    if ($mp4GB -ge 1) {
        Write-Host "  Size: $mp4GB GB ($mp4MB MB)" -ForegroundColor Cyan
    } else {
        Write-Host "  Size: $mp4MB MB" -ForegroundColor Cyan
    }
    Write-Host ""
    
    # MP_ files (temp conversions)
    $mp_GB = [math]::Round($mp_Size / 1GB, 2)
    $mp_MB = [math]::Round($mp_Size / 1MB, 2)
    Write-Host "Temporary files (.mp_):" -ForegroundColor White
    Write-Host "  Count: $($mp_Files.Count)" -ForegroundColor Gray
    if ($mp_GB -ge 1) {
        Write-Host "  Size: $mp_GB GB ($mp_MB MB)" -ForegroundColor Cyan
    } else {
        Write-Host "  Size: $mp_MB MB" -ForegroundColor Cyan
    }
    Write-Host ""
    
    # MKV files
    $mkvGB = [math]::Round($mkvSize / 1GB, 2)
    $mkvMB = [math]::Round($mkvSize / 1MB, 2)
    Write-Host "MKV files (.mkv):" -ForegroundColor White
    Write-Host "  Count: $($mkvFiles.Count)" -ForegroundColor Gray
    if ($mkvGB -ge 1) {
        Write-Host "  Size: $mkvGB GB ($mkvMB MB)" -ForegroundColor Cyan
    } else {
        Write-Host "  Size: $mkvMB MB" -ForegroundColor Cyan
    }
    Write-Host ""
    
    # MK_ files (hidden)
    $mk_GB = [math]::Round($mk_Size / 1GB, 2)
    $mk_MB = [math]::Round($mk_Size / 1MB, 2)
    Write-Host "Hidden files (.mk_):" -ForegroundColor White
    Write-Host "  Count: $($mk_Files.Count)" -ForegroundColor Gray
    if ($mk_GB -ge 1) {
        Write-Host "  Size: $mk_GB GB ($mk_MB MB)" -ForegroundColor Cyan
    } else {
        Write-Host "  Size: $mk_MB MB" -ForegroundColor Cyan
    }
    Write-Host ""
    
    # Grand total
    Write-Host "==================================" -ForegroundColor Yellow
    $grandTotalGB = [math]::Round($grandTotal / 1GB, 2)
    $grandTotalMB = [math]::Round($grandTotal / 1MB, 2)
    $totalFiles = $mp4Files.Count + $mp_Files.Count + $mkvFiles.Count + $mk_Files.Count
    Write-Host "Grand Total:" -ForegroundColor White
    Write-Host "  Total files: $totalFiles" -ForegroundColor Gray
    if ($grandTotalGB -ge 1) {
        Write-Host "  Total size: $grandTotalGB GB ($grandTotalMB MB)" -ForegroundColor Green
    } else {
        Write-Host "  Total size: $grandTotalMB MB" -ForegroundColor Green
    }
    Write-Host ""
    
    # Available disk space
    $drive = Split-Path -Qualifier $currentDir
    if ($drive) {
        $diskInfo = Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($diskInfo) {
            $freeSpaceGB = [math]::Round($diskInfo.Free / 1GB, 2)
            $totalSpaceGB = [math]::Round(($diskInfo.Free + $diskInfo.Used) / 1GB, 2)
            $usedPercent = [math]::Round(($diskInfo.Used / ($diskInfo.Free + $diskInfo.Used)) * 100, 1)
            Write-Host "Disk Information (${drive}):" -ForegroundColor White
            Write-Host "  Total capacity: $totalSpaceGB GB" -ForegroundColor Gray
            Write-Host "  Available space: $freeSpaceGB GB" -ForegroundColor Gray
            Write-Host "  Used: $usedPercent%" -ForegroundColor Gray
        }
    }
    Write-Host ""
    exit 0
}

# Handle cleanup mode - remove .mk_ files that have valid .mp4 replacements
if ($Mode -eq "cleanup") {
    $mk_Files = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mk_" -File -ErrorAction SilentlyContinue

    if ($mk_Files.Count -eq 0) {
        Write-Host "No .mk_ files found." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Found $($mk_Files.Count) .mk_ file(s) to analyze" -ForegroundColor Cyan
    Write-Host ""

    $safeToDelete  = [System.Collections.Generic.List[object]]::new()
    $suspicious    = [System.Collections.Generic.List[object]]::new()
    $noMp4         = [System.Collections.Generic.List[object]]::new()
    $subtitleLoss  = [System.Collections.Generic.List[object]]::new()

    if ($SkipSubtitleGuard) {
        Write-Host "WARNING: -SkipSubtitleGuard is set. Sources will be deleted even if" -ForegroundColor Red
        Write-Host "         their subtitles did not survive conversion." -ForegroundColor Red
        Write-Host ""
    }
    elseif (-not $SubtitleToolsAvailable) {
        Write-Error "cleanup needs ffmpeg/ffprobe to verify subtitles survived before deleting sources. Install them, or re-run with -SkipSubtitleGuard to delete anyway."
        exit 1
    }

    # Minimum thresholds for a "real" MP4:
    #   - At least 50 MB absolute
    #   - At least 8% of the .mk_ source size (HandBrake RF18 should never go this low)
    $minMp4Bytes = 50MB
    $minSizeRatio = 0.08

    foreach ($mk_ in $mk_Files) {
        $expectedMp4 = [IO.Path]::ChangeExtension($mk_.FullName, ".mp4")

        if (Test-Path $expectedMp4) {
            $mp4       = Get-Item $expectedMp4
            $sizeRatio = if ($mk_.Length -gt 0) { $mp4.Length / $mk_.Length } else { 0 }
            $mk_MB     = [math]::Round($mk_.Length  / 1MB, 1)
            $mp4MB     = [math]::Round($mp4.Length  / 1MB, 1)
            $ratioPct  = [math]::Round($sizeRatio * 100, 1)

            if ($mp4.Length -lt $minMp4Bytes) {
                $suspicious.Add([PSCustomObject]@{
                    Mk_File   = $mk_
                    Mp4File   = $mp4
                    Mk_MB     = $mk_MB
                    Mp4MB     = $mp4MB
                    Issue     = "MP4 is only ${mp4MB} MB — may be incomplete or wrong file"
                })
            }
            elseif ($sizeRatio -lt $minSizeRatio) {
                $suspicious.Add([PSCustomObject]@{
                    Mk_File   = $mk_
                    Mp4File   = $mp4
                    Mk_MB     = $mk_MB
                    Mp4MB     = $mp4MB
                    Issue     = "MP4 is ${ratioPct}% of source — suspiciously small (expected ≥ $([int]($minSizeRatio*100))%)"
                })
            }
            else {
                # Size looks right - now confirm the subtitles actually made it
                # across before letting the only copy be deleted.
                $lossReason = if ($SkipSubtitleGuard) { $null } else {
                    Get-SubtitleLossReason -SourcePath $mk_.FullName -ReplacementPath $mp4.FullName
                }

                if ($lossReason) {
                    $subtitleLoss.Add([PSCustomObject]@{
                        Mk_File = $mk_
                        Mp4File = $mp4
                        Mk_MB   = $mk_MB
                        Mp4MB   = $mp4MB
                        Issue   = $lossReason
                    })
                }
                else {
                    $safeToDelete.Add([PSCustomObject]@{
                        Mk_File   = $mk_
                        Mp4File   = $mp4
                        Mk_MB     = $mk_MB
                        Mp4MB     = $mp4MB
                        RatioPct  = $ratioPct
                    })
                }
            }
        }
        else {
            # No same-name MP4 — check if any other .mp4 lives in the same folder (name mismatch)
            $otherMp4s = Get-ChildItem -Path $mk_.DirectoryName -Filter "*.mp4" -File -ErrorAction SilentlyContinue
            if ($otherMp4s.Count -gt 0) {
                foreach ($other in $otherMp4s) {
                    $suspicious.Add([PSCustomObject]@{
                        Mk_File  = $mk_
                        Mp4File  = $other
                        Mk_MB    = [math]::Round($mk_.Length  / 1MB, 1)
                        Mp4MB    = [math]::Round($other.Length / 1MB, 1)
                        Issue    = "Name mismatch — .mk_ is '$($mk_.BaseName)' but .mp4 is '$($other.BaseName)'"
                    })
                }
            }
            else {
                $noMp4.Add($mk_)
            }
        }
    }

    # ── Scan report ──────────────────────────────────────────────────────────

    if ($suspicious.Count -gt 0) {
        Write-Host "SUSPICIOUS — requires manual review ($($suspicious.Count) case(s)):" -ForegroundColor Red
        Write-Host "  These will NOT be deleted automatically." -ForegroundColor DarkRed
        Write-Host ""
        foreach ($item in $suspicious) {
            Write-Host "  .mk_ : $($item.Mk_File.FullName) ($($item.Mk_MB) MB)" -ForegroundColor Yellow
            Write-Host "  .mp4 : $($item.Mp4File.FullName) ($($item.Mp4MB) MB)" -ForegroundColor Yellow
            Write-Host "  Issue: $($item.Issue)" -ForegroundColor Red
            Write-Host ""
        }
    }

    if ($subtitleLoss.Count -gt 0) {
        Write-Host "SUBTITLES WOULD BE LOST — blocked ($($subtitleLoss.Count) case(s)):" -ForegroundColor Red
        Write-Host "  These will NOT be deleted. Run 'backfill' first to write sidecar .srt files," -ForegroundColor DarkRed
        Write-Host "  or re-convert with the current script, then re-run cleanup." -ForegroundColor DarkRed
        Write-Host ""
        foreach ($item in $subtitleLoss) {
            Write-Host "  .mk_ : $($item.Mk_File.FullName) ($($item.Mk_MB) MB)" -ForegroundColor Yellow
            Write-Host "  Issue: $($item.Issue)" -ForegroundColor Red
            Write-Host ""
        }
    }

    if ($noMp4.Count -gt 0) {
        Write-Host "NO MP4 FOUND — skipping ($($noMp4.Count) case(s)):" -ForegroundColor DarkGray
        foreach ($mk_ in $noMp4) {
            Write-Host "  $($mk_.FullName)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($safeToDelete.Count -eq 0) {
        Write-Host "No .mk_ files cleared for deletion." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    $reclaimableBytes = ($safeToDelete | Measure-Object -Property { $_.Mk_File.Length } -Sum).Sum
    $reclaimGB = [math]::Round($reclaimableBytes / 1GB, 2)
    $reclaimMB = [math]::Round($reclaimableBytes / 1MB, 1)

    Write-Host "SAFE TO DELETE ($($safeToDelete.Count) case(s)):" -ForegroundColor Green
    foreach ($item in $safeToDelete) {
        Write-Host "  $($item.Mk_File.Name)" -ForegroundColor Cyan
        Write-Host "    source $($item.Mk_MB) MB  →  mp4 $($item.Mp4MB) MB ($($item.RatioPct)% of source)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Space to reclaim: $(if ($reclaimGB -ge 1) { "$reclaimGB GB" } else { "$reclaimMB MB" })" -ForegroundColor Green
    Write-Host ""

    # ── Delete ───────────────────────────────────────────────────────────────

    $deleted = 0
    $deleteFailed = 0
    foreach ($item in $safeToDelete) {
        try {
            Remove-Item -Path $item.Mk_File.FullName -Force
            Write-Host "✓ Deleted: $($item.Mk_File.FullName)" -ForegroundColor Green
            $deleted++
        }
        catch {
            Write-Warning "Failed to delete: $($item.Mk_File.FullName) — $_"
            $deleteFailed++
        }
    }

    Write-Host ""
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Cleanup Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Deleted (.mk_ files removed): $deleted" -ForegroundColor Green
    if ($deleteFailed -gt 0)       { Write-Host "Failed to delete: $deleteFailed"           -ForegroundColor Red     }
    if ($suspicious.Count -gt 0)   { Write-Host "Suspicious (skipped): $($suspicious.Count)" -ForegroundColor Yellow  }
    if ($subtitleLoss.Count -gt 0) { Write-Host "Blocked - subtitle loss: $($subtitleLoss.Count)" -ForegroundColor Red }
    if ($noMp4.Count -gt 0)        { Write-Host "No MP4 found (skipped): $($noMp4.Count)"    -ForegroundColor DarkGray }
    Write-Host ""
    exit 0
}

# Handle backfill mode - write sidecar .srt files for videos that were converted
# before subtitle preservation existed. Requires the original .mkv/.mk_ to still
# be present; the subtitle data cannot be recovered from the .mp4 alone.
if ($Mode -eq "backfill") {
    if (-not $SubtitleToolsAvailable) {
        Write-Error "backfill needs ffmpeg and ffprobe. Install them to C:\Tools\ffmpeg\bin or put them on PATH."
        exit 1
    }

    Write-Host "ffmpeg:  $FFmpeg"  -ForegroundColor DarkGray
    Write-Host "ffprobe: $FFprobe" -ForegroundColor DarkGray
    Write-Host ""

    $mediaFiles = Get-ChildItem -Path $currentDir -Recurse -File -Include "*.mp4", "*.m4v", "*.mkv", "*.mk_" -ErrorAction SilentlyContinue

    if ($mediaFiles.Count -eq 0) {
        Write-Host "No video files found under: $currentDir" -ForegroundColor Yellow
        exit 0
    }

    # Group by folder + basename so a converted pair (Foo.mk_ + Foo.mp4) is a
    # single unit of work: the sidecar is named after the file Plex will play,
    # while the subtitles are read from whichever member still holds them.
    $groups = $mediaFiles | Group-Object { [IO.Path]::Combine($_.DirectoryName, [IO.Path]::GetFileNameWithoutExtension($_.Name)) }

    $items = foreach ($g in $groups) {
        $t = @($g.Group | Where-Object { $_.Extension -in ".mp4", ".m4v" })[0]
        if (-not $t) { $t = @($g.Group | Where-Object { $_.Extension -eq ".mkv" })[0] }
        if (-not $t) { $t = @($g.Group | Where-Object { $_.Extension -eq ".mk_" })[0] }
        if (-not $t) { continue }

        # Prefer the original as the subtitle source; fall back to the playable
        # file, which may still carry an embedded text track worth extracting.
        $s = @($g.Group | Where-Object { $_.Extension -in ".mkv", ".mk_" })[0]
        if (-not $s) { $s = $t }

        [PSCustomObject]@{ Target = $t; Source = $s }
    }
    $items = @($items)

    Write-Host "Scanning $($items.Count) title(s) across $($mediaFiles.Count) file(s)..." -ForegroundColor Cyan
    Write-Host ""

    $written      = @()
    $alreadyHad   = @()
    $hasEmbedded  = @()
    $noSource     = @()
    $bitmapOnly   = @()
    $noSubs       = @()
    $failed       = @()

    $i = 0
    foreach ($item in $items) {
        $i++
        $v = $item.Target
        Write-Progress -Activity "Backfilling subtitles" -Status $v.Name -PercentComplete (($i / $items.Count) * 100)

        $baseDir  = $v.DirectoryName
        $baseName = [IO.Path]::GetFileNameWithoutExtension($v.FullName)

        # Any existing sidecar for this video means there is nothing to do.
        $existing = @(Get-ChildItem -Path $baseDir -Filter "$baseName*.srt" -File -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            $alreadyHad += $v.FullName
            continue
        }

        # A playable file that already carries a text subtitle track works in
        # Plex as-is; a sidecar would just duplicate it.
        if (-not $IncludeEmbedded) {
            $targetSubs = Get-SubtitleStreams -FilePath $v.FullName
            if (@($targetSubs | Where-Object { $_.IsText }).Count -gt 0) {
                $hasEmbedded += $v.FullName
                continue
            }
        }

        $source = $item.Source
        $sourceIsSelf = ($source.FullName -eq $v.FullName)

        $r = Export-SidecarSubtitles -SourcePath $source.FullName -VideoPath $v.FullName

        if ($r.Error) {
            $failed += "$($v.Name) - $($r.Error)"
        }
        elseif ($r.Written.Count -gt 0) {
            $written += $r.Written
            Write-Host "  + $([IO.Path]::GetFileName($r.Written[0]))" -ForegroundColor Green
            foreach ($extra in ($r.Written | Select-Object -Skip 1)) {
                Write-Host "  + $([IO.Path]::GetFileName($extra))" -ForegroundColor Green
            }
        }
        elseif ($r.BitmapOnly) {
            $bitmapOnly += $v.FullName
        }
        elseif ($sourceIsSelf -and $v.Extension -in ".mp4", ".m4v") {
            # Nothing left to read from: the source is gone and the MP4 itself
            # carries no subtitles.
            $noSource += $v.FullName
        }
        else {
            $noSubs += $v.FullName
        }
    }
    Write-Progress -Activity "Backfilling subtitles" -Completed

    Write-Host ""
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "  Backfill summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Titles scanned:              $($items.Count)"
    Write-Host "Sidecar .srt written:        $($written.Count)" -ForegroundColor Green
    if ($alreadyHad.Count -gt 0)  { Write-Host "Already had a sidecar:       $($alreadyHad.Count)"  -ForegroundColor DarkGray }
    if ($hasEmbedded.Count -gt 0) { Write-Host "Embedded text track, no sidecar needed: $($hasEmbedded.Count)" -ForegroundColor DarkGray }
    if ($noSubs.Count -gt 0)     { Write-Host "Source had no subtitles:     $($noSubs.Count)"     -ForegroundColor DarkGray }
    if ($bitmapOnly.Count -gt 0) { Write-Host "Bitmap subs only (need OCR): $($bitmapOnly.Count)" -ForegroundColor Yellow }
    if ($noSource.Count -gt 0)   { Write-Host "No .mkv/.mk_ source left:    $($noSource.Count)"   -ForegroundColor Red }
    if ($failed.Count -gt 0)     { Write-Host "Failed:                      $($failed.Count)"     -ForegroundColor Red }

    if ($bitmapOnly.Count -gt 0) {
        Write-Host ""
        Write-Host "Bitmap-only sources (VobSub/PGS - run these through Subtitle Edit OCR):" -ForegroundColor Yellow
        $bitmapOnly | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        if ($bitmapOnly.Count -gt 20) { Write-Host "  ... and $($bitmapOnly.Count - 20) more" -ForegroundColor DarkYellow }
    }

    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Host "Failures:" -ForegroundColor Red
        $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }

    if ($noSource.Count -gt 0) {
        Write-Host ""
        Write-Host "$($noSource.Count) file(s) have no surviving .mkv/.mk_ - their subtitles" -ForegroundColor Red
        Write-Host "cannot be recovered locally. Use Bazarr or Plex's OpenSubtitles agent." -ForegroundColor Red
    }

    Write-Host ""
    exit 0
}

# Handle hide mode - rename .mkv to .mk_
if ($Mode -eq "hide") {
    $mkvFiles = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mkv" -File
    
    if ($mkvFiles.Count -eq 0) {
        Write-Host "No MKV files found to hide." -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host "Found $($mkvFiles.Count) MKV file(s) to hide" -ForegroundColor Cyan
    Write-Host ""
    
    $hidden = 0
    foreach ($mkv in $mkvFiles) {
        try {
            $newPath = [IO.Path]::ChangeExtension($mkv.FullName, ".mk_")
            Rename-Item -Path $mkv.FullName -NewName ([IO.Path]::GetFileName($newPath)) -Force
            Write-Host "✓ Hidden: $($mkv.FullName)" -ForegroundColor Green
            $hidden++
        }
        catch {
            Write-Warning "Failed to hide: $($mkv.FullName) - $_"
        }
    }
    
    Write-Host ""
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Hide Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Total MKV files found: $($mkvFiles.Count)"
    Write-Host "Hidden (renamed to .mk_): $hidden" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# Handle show mode - rename .mk_ to .mkv
if ($Mode -eq "show") {
    $mk_Files = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mk_" -File
    
    if ($mk_Files.Count -eq 0) {
        Write-Host "No .mk_ files found to show." -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host "Found $($mk_Files.Count) .mk_ file(s) to restore" -ForegroundColor Cyan
    Write-Host ""
    
    $shown = 0
    foreach ($mk_ in $mk_Files) {
        try {
            $newPath = [IO.Path]::ChangeExtension($mk_.FullName, ".mkv")
            Rename-Item -Path $mk_.FullName -NewName ([IO.Path]::GetFileName($newPath)) -Force
            Write-Host "✓ Restored: $newPath" -ForegroundColor Green
            $shown++
        }
        catch {
            Write-Warning "Failed to restore: $($mk_.FullName) - $_"
        }
    }
    
    Write-Host ""
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Show Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Total .mk_ files found: $($mk_Files.Count)"
    Write-Host "Restored (renamed to .mkv): $shown" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# Find all MKV files recursively
$mkvFiles = Get-ChildItem -Path $currentDir -Recurse -Filter "*.mkv" -File

if ($mkvFiles.Count -eq 0) {
    Write-Host "No MKV files found." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($mkvFiles.Count) MKV file(s)" -ForegroundColor Cyan
Write-Host ""

$converted = 0
$skipped = 0
$failed = 0
$totalEstimatedSize = [long]0
$totalEstimatedTime = 0.0
$filesToConvert = 0
$foundWithMp4 = @()

foreach ($mkv in $mkvFiles) {
    # Generate output MP4 path
    $mp4Path = [IO.Path]::ChangeExtension($mkv.FullName, ".mp4")
    
    # Check if MP4 already exists
    if (Test-Path $mp4Path) {
        if ($Mode -eq "find") {
            # Find mode: collect files that have MP4s
            $foundWithMp4 += $mkv
            $mp4Size = (Get-Item $mp4Path).Length
            $mp4SizeMB = [math]::Round($mp4Size / 1MB, 2)
            $relativePath = $mkv.DirectoryName.Replace($currentDir, "").TrimStart('\')
            if ([string]::IsNullOrEmpty($relativePath)) {
                $relativePath = "."
            }
            Write-Host "✓ $relativePath\$($mkv.Name)" -ForegroundColor Green
            Write-Host "  MP4: $mp4SizeMB MB" -ForegroundColor Gray
            Write-Host ""
        }
        else {
            Write-Host "⊘ Skipping (MP4 exists): $($mkv.FullName)" -ForegroundColor DarkGray
        }
        $skipped++
        continue
    }
    
    # Skip further processing in find mode for files without MP4
    if ($Mode -eq "find") {
        continue
    }
    
    # Detect video height
    Write-Host "Analyzing: $($mkv.FullName)" -ForegroundColor White
    $height = Get-VideoHeight -FilePath $mkv.FullName
    
    if ($null -eq $height) {
        Write-Warning "Skipping due to detection failure: $($mkv.FullName)"
        $failed++
        Write-Host ""
        continue
    }
    
    Write-Host "Detected resolution height: ${height}p" -ForegroundColor Gray
    
    # Select preset
    $preset = Get-HandBrakePreset -Height $height
    
    if ($Mode -eq "check") {
        # Check mode: estimate size and time
        $estimatedSize = Get-EstimatedMp4Size -InputPath $mkv.FullName -Height $height
        $estimatedTime = Get-EstimatedConversionTime -InputPath $mkv.FullName -Height $height
        $totalEstimatedSize += $estimatedSize
        $totalEstimatedTime += $estimatedTime
        $filesToConvert++
        
        $estimatedSizeMB = [math]::Round($estimatedSize / 1MB, 2)
        $sourceSizeMB = [math]::Round($mkv.Length / 1MB, 2)
        $estimatedTimeMin = [math]::Round($estimatedTime, 1)
        
        Write-Host "Would convert using preset: $preset" -ForegroundColor Gray
        Write-Host "Source size: $sourceSizeMB MB → Estimated MP4 size: $estimatedSizeMB MB" -ForegroundColor DarkCyan
        Write-Host "Estimated conversion time: ~$estimatedTimeMin minutes" -ForegroundColor DarkCyan
        Write-Host ""
    }
    else {
        # Convert mode: perform actual conversion
        $success = Convert-MkvToMp4 -InputPath $mkv.FullName -OutputPath $mp4Path -Preset $preset
        
        if ($success) {
            $converted++
        }
        else {
            $failed++
        }
        
        Write-Host ""
    }
}

# Summary
Write-Host "==================================" -ForegroundColor Yellow
if ($Mode -eq "find") {
    Write-Host "Find Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Total MKV files found: $($mkvFiles.Count)"
    Write-Host "Files with existing MP4: $($foundWithMp4.Count)" -ForegroundColor Green
    Write-Host "Files without MP4: $($mkvFiles.Count - $skipped)" -ForegroundColor Cyan
    Write-Host ""
    
    if ($foundWithMp4.Count -gt 0) {
        $totalMp4Size = [long]0
        foreach ($mkv in $foundWithMp4) {
            $mp4Path = [IO.Path]::ChangeExtension($mkv.FullName, ".mp4")
            if (Test-Path $mp4Path) {
                $totalMp4Size += (Get-Item $mp4Path).Length
            }
        }
        $totalMp4GB = [math]::Round($totalMp4Size / 1GB, 2)
        $totalMp4MB = [math]::Round($totalMp4Size / 1MB, 2)
        
        Write-Host "Total MP4 size:" -ForegroundColor White
        if ($totalMp4GB -ge 1) {
            Write-Host "  $totalMp4GB GB ($totalMp4MB MB)" -ForegroundColor Green
        }
        else {
            Write-Host "  $totalMp4MB MB" -ForegroundColor Green
        }
    }
}
elseif ($Mode -eq "check") {
    Write-Host "Check Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Total MKV files found: $($mkvFiles.Count)"
    Write-Host "Already have MP4: $skipped" -ForegroundColor DarkGray
    Write-Host "Would convert: $filesToConvert" -ForegroundColor Cyan
    Write-Host "Failed to analyze: $failed" -ForegroundColor Red
    Write-Host ""
    
    if ($filesToConvert -gt 0) {
        $totalEstimatedGB = [math]::Round($totalEstimatedSize / 1GB, 2)
        $totalEstimatedMB = [math]::Round($totalEstimatedSize / 1MB, 2)
        
        Write-Host "Estimated total new MP4 size:" -ForegroundColor White
        if ($totalEstimatedGB -ge 1) {
            Write-Host "  $totalEstimatedGB GB ($totalEstimatedMB MB)" -ForegroundColor Cyan
        }
        else {
            Write-Host "  $totalEstimatedMB MB" -ForegroundColor Cyan
        }
        Write-Host ""
        
        # Display estimated total time
        $perfData = Get-PerformanceData
        $estimateSource = if ($null -ne $perfData) { 
            "based on $($perfData.TotalConversions) previous conversion(s)"
        } else { 
            "based on default estimates"
        }
        
        Write-Host "Estimated total conversion time ($estimateSource):" -ForegroundColor White
        if ($totalEstimatedTime -ge 60) {
            $hours = [math]::Floor($totalEstimatedTime / 60)
            $minutes = [math]::Round($totalEstimatedTime % 60)
            Write-Host "  ~$hours hour(s) $minutes minute(s)" -ForegroundColor Cyan
        }
        else {
            $minutes = [math]::Round($totalEstimatedTime)
            Write-Host "  ~$minutes minute(s)" -ForegroundColor Cyan
        }
        
        if ($null -ne $perfData) {
            $rate = [math]::Round($perfData.MbitsPerMinute, 1)
            Write-Host "  (Average encoding rate: $rate Mbits/minute)" -ForegroundColor Gray
        }
        Write-Host ""
        
        # Get available disk space
        $drive = Split-Path -Qualifier $currentDir
        if ($drive) {
            $diskInfo = Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction SilentlyContinue
            if ($diskInfo) {
                $freeSpaceGB = [math]::Round($diskInfo.Free / 1GB, 2)
                Write-Host "Available disk space on ${drive}: $freeSpaceGB GB" -ForegroundColor White
                
                $requiredGB = [math]::Round($totalEstimatedSize / 1GB, 2)
                if ($diskInfo.Free -gt $totalEstimatedSize) {
                    $remainingGB = [math]::Round(($diskInfo.Free - $totalEstimatedSize) / 1GB, 2)
                    Write-Host "✓ Sufficient space available (${remainingGB} GB remaining after conversion)" -ForegroundColor Green
                }
                else {
                    $shortfallGB = [math]::Round(($totalEstimatedSize - $diskInfo.Free) / 1GB, 2)
                    Write-Host "✗ Insufficient space! Need ${shortfallGB} GB more" -ForegroundColor Red
                }
            }
        }
        Write-Host ""
        Write-Host "To proceed with conversion, run:" -ForegroundColor Yellow
        Write-Host "  .\Convert-MkvToMp4.ps1 -Mode convert" -ForegroundColor White
    }
}
else {
    Write-Host "Conversion Summary" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    Write-Host "Total MKV files found: $($mkvFiles.Count)"
    Write-Host "Converted: $converted" -ForegroundColor Green
    Write-Host "Skipped (already exists): $skipped" -ForegroundColor DarkGray
    Write-Host "Failed: $failed" -ForegroundColor Red
}
Write-Host ""
