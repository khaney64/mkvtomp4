<#
.SYNOPSIS
    Converts MKV files to MP4 using HandBrakeCLI with automatic preset selection.

.DESCRIPTION
    Recursively scans the current directory for .mkv files and converts them to .mp4
    if the .mp4 doesn't already exist. Automatically selects the appropriate HandBrake
    preset based on video resolution (480p or 1080p).

.PARAMETER Mode
    Operation mode: "check" (default) to scan and estimate, "convert" to perform conversions, "find" to list files that already have MP4s, "hide" to rename .mkv to .mk_ (hide from Plex), or "show" to rename .mk_ back to .mkv.

.PARAMETER Path
    The directory path to scan. Defaults to the current directory if not specified.

.NOTES
    - Requires HandBrakeCLI.exe to be installed
    - Uses H.264 encoding with RF 18 quality
    - Web-optimized MP4 output
    - AC3 audio passthrough when available
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "convert", "find", "hide", "show")]
    [string]$Mode = "check",
    
    [Parameter(Position = 1)]
    [string]$Path = (Get-Location).Path
)

# Configuration
$HandBrakeCLI = "C:\Tools\HandBrake\HandBrakeCLI.exe"
$PerformanceDataFile = "$PSScriptRoot\handbrake_performance.json"

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
function Convert-MkvToMp4 {
    param (
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Preset
    )
    
    try {
        # Use temporary extension .mp_ during conversion
        $tempOutputPath = [IO.Path]::ChangeExtension($OutputPath, ".mp_")
        
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
        # -e x264: H.264 encoder
        # -q 18: RF 18 quality
        # -O: Web optimized
        # --audio-copy-mask ac3: AC3 passthrough
        # --audio-fallback: Default audio fallback
        $arguments = @(
            "--preset", "`"$Preset`"",
            "-e", "x264",
            "-q", "18",
            "-O",
            "--audio-copy-mask", "ac3",
            "--audio-fallback", "av_aac",
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
