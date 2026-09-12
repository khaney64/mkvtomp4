<#
.SYNOPSIS
    Compare files in active folders vs #recycle bin to find files that only exist in recycle.

.DESCRIPTION
    Compares Movies and TV Shows folders against their counterparts in #recycle bin.
    Reports any files that exist in #recycle but NOT in the active folders.
    This helps ensure you don't permanently delete files that aren't duplicates.

.PARAMETER MediaRoot
    Root of the media share. Defaults to \\localcloud\media.

.PARAMETER RecycleRoot
    Location of the recycle bin. Defaults to the #recycle folder inside
    MediaRoot, which is where Synology puts it.

.PARAMETER Folders
    Library folders to compare. Defaults to Movies and TV Shows.

.NOTES
    Created: December 9, 2025
    Purpose: Safety check before emptying Synology #recycle bin

.EXAMPLE
    .\Compare-RecycleBin.ps1

.EXAMPLE
    .\Compare-RecycleBin.ps1 -MediaRoot '\\nas\media' -Folders 'Movies','Music'

.EXAMPLE
    # recycle bin somewhere other than inside the share
    .\Compare-RecycleBin.ps1 -MediaRoot 'D:\Media' -RecycleRoot 'E:\Trash'
#>

[CmdletBinding()]
param(
    [string]$MediaRoot = '\\localcloud\media',
    [string]$RecycleRoot,
    [string[]]$Folders = @('Movies', 'TV Shows'),

    # Path segments to ignore. A git repo living inside the library churns
    # hundreds of transient .git lock files, and Synology captures every one of
    # them in #recycle - they would otherwise swamp the real findings.
    # NOTE: do not add '#recycle' here - the recycle path itself contains that
    # segment, so it would filter out every file being checked and wrongly
    # report the bin as safe to empty.
    [string[]]$ExcludeFolders = @('.git', '@eaDir')
)

$mediaRoot = $MediaRoot.TrimEnd('\')
# Synology keeps the bin inside the share; allow it to sit elsewhere.
$recycleRoot = if ($RecycleRoot) { $RecycleRoot.TrimEnd('\') } else { Join-Path $mediaRoot '#recycle' }

if (-not (Test-Path -LiteralPath $mediaRoot)) { throw "MediaRoot not found: $mediaRoot" }
if (-not (Test-Path -LiteralPath $recycleRoot)) {
    Write-Host "No recycle bin at $recycleRoot - nothing to check." -ForegroundColor Green
    return
}

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "Recycle Bin Safety Check" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

# True when any path segment matches one of -ExcludeFolders.
function Test-Excluded {
    param([string]$FullPath)
    foreach ($seg in ($FullPath -split '[\\/]')) {
        if ($ExcludeFolders -contains $seg) { return $true }
    }
    return $false
}

# Function to get relative path from base
function Get-RelativePath {
    param($FullPath, $BasePath)
    return $FullPath.Replace($BasePath, "").TrimStart('\')
}

# Function to compare folders
function Compare-Folders {
    param(
        [string]$ActivePath,
        [string]$RecyclePath,
        [string]$FolderName
    )
    
    Write-Host "Checking: $FolderName" -ForegroundColor Cyan
    Write-Host "Active: $ActivePath" -ForegroundColor Gray
    Write-Host "Recycle: $RecyclePath" -ForegroundColor Gray
    Write-Host ""
    
    if (-not (Test-Path $ActivePath)) {
        Write-Warning "Active folder not found: $ActivePath"
        return
    }
    
    if (-not (Test-Path $RecyclePath)) {
        Write-Host "No recycle folder found for $FolderName - nothing to worry about!" -ForegroundColor Green
        Write-Host ""
        return
    }
    
    # Get all files from active folder
    Write-Host "Scanning active $FolderName folder..." -ForegroundColor Gray
    $activeFiles = Get-ChildItem -Path $ActivePath -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { -not (Test-Excluded $_.FullName) }
    $activeFileSet = @{}
    foreach ($file in $activeFiles) {
        $relativePath = Get-RelativePath -FullPath $file.FullName -BasePath $ActivePath
        $activeFileSet[$relativePath.ToLower()] = $file
    }
    Write-Host "  Found $($activeFiles.Count) files in active folder" -ForegroundColor Gray
    
    # Get all files from recycle folder
    Write-Host "Scanning recycle $FolderName folder..." -ForegroundColor Gray
    $recycleFiles = @(Get-ChildItem -Path $RecyclePath -Recurse -File -ErrorAction SilentlyContinue |
                      Where-Object { -not (Test-Excluded $_.FullName) })
    Write-Host "  Found $($recycleFiles.Count) files in recycle folder" -ForegroundColor Gray
    Write-Host ""
    
    # Check for files in recycle that don't exist in active, and compare sizes for duplicates
    $uniqueToRecycle = @()
    $sizeMismatches = @()
    $exactDuplicates = 0
    
    foreach ($recycleFile in $recycleFiles) {
        $relativePath = Get-RelativePath -FullPath $recycleFile.FullName -BasePath $RecyclePath
        $relativePathLower = $relativePath.ToLower()
        
        if (-not $activeFileSet.ContainsKey($relativePathLower)) {
            # File only exists in recycle
            $uniqueToRecycle += [PSCustomObject]@{
                RelativePath = $relativePath
                FullPath = $recycleFile.FullName
                SizeMB = [math]::Round($recycleFile.Length / 1MB, 2)
                LastModified = $recycleFile.LastWriteTime
            }
        }
        else {
            # File exists in both - compare sizes
            $activeFile = $activeFileSet[$relativePathLower]
            if ($recycleFile.Length -ne $activeFile.Length) {
                $sizeMismatches += [PSCustomObject]@{
                    RelativePath = $relativePath
                    RecycleSizeMB = [math]::Round($recycleFile.Length / 1MB, 2)
                    ActiveSizeMB = [math]::Round($activeFile.Length / 1MB, 2)
                    RecycleModified = $recycleFile.LastWriteTime
                    ActiveModified = $activeFile.LastWriteTime
                }
            }
            else {
                $exactDuplicates++
            }
        }
    }
    
    # Report results
    Write-Host "Exact duplicates (same size): $exactDuplicates" -ForegroundColor Green
    Write-Host ""
    
    if ($uniqueToRecycle.Count -eq 0 -and $sizeMismatches.Count -eq 0) {
        Write-Host "✓ SAFE: All files in recycle exist in active $FolderName folder with matching sizes" -ForegroundColor Green
        Write-Host "  You can safely delete the recycle bin for this folder." -ForegroundColor Green
    }
    else {
        if ($uniqueToRecycle.Count -gt 0) {
            Write-Host "⚠ WARNING: Found $($uniqueToRecycle.Count) file(s) ONLY in recycle bin!" -ForegroundColor Red
            Write-Host "  These files DO NOT exist in the active folder:" -ForegroundColor Red
            Write-Host ""
            
            $totalSizeMB = ($uniqueToRecycle | Measure-Object -Property SizeMB -Sum).Sum
            
            foreach ($file in $uniqueToRecycle | Sort-Object RelativePath) {
                Write-Host "  • $($file.RelativePath)" -ForegroundColor Yellow
                Write-Host "    Size: $($file.SizeMB) MB | Modified: $($file.LastModified)" -ForegroundColor Gray
            }
            
            Write-Host ""
            Write-Host "  Total unique files: $($uniqueToRecycle.Count)" -ForegroundColor Red
            Write-Host "  Total size: $([math]::Round($totalSizeMB / 1024, 2)) GB ($totalSizeMB MB)" -ForegroundColor Red
            Write-Host ""
        }
        
        if ($sizeMismatches.Count -gt 0) {
            Write-Host "⚠ SIZE MISMATCH: Found $($sizeMismatches.Count) file(s) with different sizes!" -ForegroundColor Magenta
            Write-Host "  Files exist in both places but have different sizes:" -ForegroundColor Magenta
            Write-Host ""
            
            foreach ($file in $sizeMismatches | Sort-Object RelativePath) {
                Write-Host "  • $($file.RelativePath)" -ForegroundColor Yellow
                Write-Host "    Recycle: $($file.RecycleSizeMB) MB (Modified: $($file.RecycleModified))" -ForegroundColor Gray
                Write-Host "    Active:  $($file.ActiveSizeMB) MB (Modified: $($file.ActiveModified))" -ForegroundColor Gray
                $sizeDiff = [math]::Round([math]::Abs($file.RecycleSizeMB - $file.ActiveSizeMB), 2)
                Write-Host "    Difference: $sizeDiff MB" -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  ⚠ These may be different versions - review before deleting!" -ForegroundColor Magenta
            Write-Host ""
        }
        
        if ($uniqueToRecycle.Count -gt 0 -or $sizeMismatches.Count -gt 0) {
            Write-Host "  ⚠ Review these files before emptying recycle bin!" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "------------------------------------------" -ForegroundColor Gray
    Write-Host ""
    
    return @{
        UniqueToRecycle = $uniqueToRecycle
        SizeMismatches = $sizeMismatches
        ExactDuplicates = $exactDuplicates
    }
}

# Compare each requested library folder
$allResults = foreach ($folder in $Folders) {
    Compare-Folders `
        -ActivePath (Join-Path $mediaRoot $folder) `
        -RecyclePath (Join-Path $recycleRoot $folder) `
        -FolderName $folder
}

# Final summary
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "Final Summary" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow

$totalUnique = 0
$totalMismatches = 0
$totalExactDuplicates = 0

foreach ($r in $allResults) {
    if (-not $r) { continue }
    $totalUnique += $r.UniqueToRecycle.Count
    $totalMismatches += $r.SizeMismatches.Count
    $totalExactDuplicates += $r.ExactDuplicates
}

Write-Host "Total exact duplicates: $totalExactDuplicates" -ForegroundColor Green
Write-Host "Total unique to recycle: $totalUnique" -ForegroundColor $(if ($totalUnique -eq 0) { "Green" } else { "Red" })
Write-Host "Total size mismatches: $totalMismatches" -ForegroundColor $(if ($totalMismatches -eq 0) { "Green" } else { "Magenta" })
Write-Host ""

if ($totalUnique -eq 0 -and $totalMismatches -eq 0) {
    Write-Host "✓ ALL CLEAR!" -ForegroundColor Green
    Write-Host "  All files in #recycle are exact duplicates of active files." -ForegroundColor Green
    Write-Host "  It's safe to empty the recycle bin." -ForegroundColor Green
}
else {
    Write-Host "⚠ CAUTION REQUIRED!" -ForegroundColor Red
    if ($totalUnique -gt 0) {
        Write-Host "  Found $totalUnique unique file(s) only in recycle bin." -ForegroundColor Red
    }
    if ($totalMismatches -gt 0) {
        Write-Host "  Found $totalMismatches file(s) with size mismatches." -ForegroundColor Magenta
    }
    Write-Host "  Review the files listed above before permanently deleting." -ForegroundColor Red
}

Write-Host ""
