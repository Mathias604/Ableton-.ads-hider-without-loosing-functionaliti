<#
    Ableton ASD Hider
    -----------------
    Hides/unhides files while:
    - respecting include/exclude paths
    - tracking already hidden files
    - avoiding redundant operations
    - providing interactive menu mode
#>

[CmdletBinding()]
param (
    [ValidateSet("hide", "unhide")]
    [string]$Mode,

    [ValidatePattern('^[a-zA-Z0-9]{1,10}$')]
    [string]$Extension = "asd",

    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ────────────────────────────────────────────────
# Script paths
# ────────────────────────────────────────────────

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$includeFile      = Join-Path $scriptRoot "include_paths.txt"
$excludeFile      = Join-Path $scriptRoot "exclude_paths.txt"
$hiddenCacheFile  = Join-Path $scriptRoot "already_hidden.txt"

# ────────────────────────────────────────────────
# Interactive mode
# ────────────────────────────────────────────────

if (-not $Mode) {

    Write-Host ""
    Write-Host "========== ASD FILE MANAGER ==========" -ForegroundColor Cyan
    Write-Host "1. Hide .$Extension files"
    Write-Host "2. Unhide .$Extension files"
    Write-Host "3. Exit"
    Write-Host ""

    $choice = Read-Host "Choose"

    switch ($choice) {
        "1" { $Mode = "hide" }
        "2" { $Mode = "unhide" }
        default { exit }
    }
}

# ────────────────────────────────────────────────
# Validate include file
# ────────────────────────────────────────────────

if (-not (Test-Path $includeFile -PathType Leaf)) {
    Write-Error "Missing include_paths.txt"
    exit 1
}

# ────────────────────────────────────────────────
# Load include paths
# ────────────────────────────────────────────────

$includePaths = Get-Content $includeFile -Encoding UTF8 |
    ForEach-Object { $_.Trim() } |
    Where-Object {
        $_ -and
        (Test-Path $_ -ErrorAction Ignore)
    } |
    Sort-Object -Unique

if (-not $includePaths) {
    Write-Warning "No valid include paths found."
    exit 0
}

# ────────────────────────────────────────────────
# Load exclude paths
# ────────────────────────────────────────────────

$excludeRoots = @()

if (Test-Path $excludeFile) {

    $excludeRoots = Get-Content $excludeFile -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Sort-Object -Unique
}

# Faster lookup
$excludeSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($e in $excludeRoots) {
    $null = $excludeSet.Add($e)
}

# ────────────────────────────────────────────────
# Hidden cache
# ────────────────────────────────────────────────

if (-not (Test-Path $hiddenCacheFile)) {
    New-Item -ItemType File -Path $hiddenCacheFile -Force | Out-Null
}

$hiddenSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

Get-Content $hiddenCacheFile -Encoding UTF8 -ErrorAction Ignore |
    ForEach-Object {
        if ($_) {
            $null = $hiddenSet.Add($_)
        }
    }

# ────────────────────────────────────────────────
# Logging
# ────────────────────────────────────────────────

$logDir = Join-Path $scriptRoot "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = Join-Path $logDir "$Mode`_$Extension`_$timestamp.txt"

function Write-Log {

    param(
        [string]$Message,
        [ConsoleColor]$Color = "White"
    )

    Write-Host $Message -ForegroundColor $Color
    $Message | Add-Content -Path $logFile -Encoding UTF8
}

# ────────────────────────────────────────────────
# Header
# ────────────────────────────────────────────────

Write-Log ""
Write-Log "========== ASD FILE MANAGER ==========" Cyan
Write-Log "Mode        : $Mode" Cyan
Write-Log "Extension   : .$Extension" Cyan
Write-Log "Dry Run     : $DryRun" Cyan
Write-Log "Started     : $(Get-Date)" Cyan
Write-Log ""

# ────────────────────────────────────────────────
# Counters
# ────────────────────────────────────────────────

$processed = 0
$skipped   = 0
$failed    = 0
$cached    = 0

# ────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────

function Is-Excluded {

    param([string]$Path)

    foreach ($ex in $excludeRoots) {

        if ($Path.StartsWith($ex, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# ────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────

foreach ($root in $includePaths) {

    Write-Log "Scanning → $root" Yellow

    try {

        Get-ChildItem `
            -Path $root `
            -Recurse `
            -File `
            -Filter "*.$Extension" `
            -Force `
            -ErrorAction SilentlyContinue |

        ForEach-Object {

            $file = $_
            $path = $file.FullName

            # Excluded?
            if (Is-Excluded $path) {
                $skipped++
                return
            }

            # ─────────────────────────────
            # HIDE MODE
            # ─────────────────────────────

            if ($Mode -eq "hide") {

                # Already cached
                if ($hiddenSet.Contains($path)) {
                    $cached++
                    return
                }

                # Already hidden?
                if ($file.Attributes -band [IO.FileAttributes]::Hidden) {

                    $null = $hiddenSet.Add($path)
                    $cached++
                    return
                }

                Write-Log "Hiding   → $path" Green

                if (-not $DryRun) {

                    attrib +h +s "$path"

                    $null = $hiddenSet.Add($path)
                }

                $processed++
            }

            # ─────────────────────────────
            # UNHIDE MODE
            # ─────────────────────────────

            else {

                Write-Log "Unhiding → $path" Green

                if (-not $DryRun) {

                    attrib -h -s "$path"

                    if ($hiddenSet.Contains($path)) {
                        $hiddenSet.Remove($path) | Out-Null
                    }
                }

                $processed++
            }
        }

    }
    catch {

        Write-Log "FAILED → $root ($($_.Exception.Message))" Red
        $failed++
    }
}

# ────────────────────────────────────────────────
# Save cache
# ────────────────────────────────────────────────

$hiddenSet |
    Sort-Object |
    Set-Content -Path $hiddenCacheFile -Encoding UTF8

# ────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────

Write-Log ""
Write-Log ("-" * 60)

Write-Log "Processed : $processed" Cyan
Write-Log "Cached    : $cached" DarkGray
Write-Log "Skipped   : $skipped" DarkGray
Write-Log "Failed    : $failed" Red

Write-Log ""
Write-Log "Finished  : $(Get-Date)" Cyan
Write-Log "Log File  : $logFile" Magenta

Write-Host ""
Pause
