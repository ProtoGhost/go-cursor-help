# ========================================
# Cursor Hook Injection Script (Windows)
# ========================================
#
# 🎯 Feature: Injects cursor_hook.js into the top of Cursor's main.js file
# 
# 📦 Usage:
# 1. Open PowerShell as Administrator
# 2. Run: .\inject_hook_win.ps1
#
# ⚠️ Notes:
# - Automatically creates a backup of the original main.js file
# - Supports rollback to the original version
# - Re-injection is required after Cursor updates
#
# ========================================

param(
    [switch]$Rollback,  # Rollback to original version
    [switch]$Force,     # Force re-injection
    [switch]$Debug      # Enable debug mode
)

# Color definitions
$RED = "`e[31m"
$GREEN = "`e[32m"
$YELLOW = "`e[33m"
$BLUE = "`e[34m"
$NC = "`e[0m"

# Logging function
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "INFO"  { Write-Host "$GREEN[INFO]$NC $Message" }
        "WARN"  { Write-Host "$YELLOW[WARN]$NC $Message" }
        "ERROR" { Write-Host "$RED[ERROR]$NC $Message" }
        "DEBUG" { if ($Debug) { Write-Host "$BLUE[DEBUG]$NC $Message" } }
    }
}

# Get Cursor installation path
function Get-CursorPath {
    $possiblePaths = @(
        "$env:LOCALAPPDATA\Programs\cursor\resources\app\out\main.js",
        "$env:LOCALAPPDATA\Programs\Cursor\resources\app\out\main.js",
        "C:\Program Files\Cursor\resources\app\out\main.js",
        "C:\Program Files (x86)\Cursor\resources\app\out\main.js"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

# Get Hook script path
function Get-HookScriptPath {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $hookPath = Join-Path $scriptDir "cursor_hook.js"
    
    if (Test-Path $hookPath) {
        return $hookPath
    }
    
    # Try locating from current directory
    $currentDir = Get-Location
    $hookPath = Join-Path $currentDir "cursor_hook.js"
    
    if (Test-Path $hookPath) {
        return $hookPath
    }
    
    return $null
}

# Check if already injected
function Test-AlreadyInjected {
    param([string]$MainJsPath)
    
    $content = Get-Content $MainJsPath -Raw -Encoding UTF8
    return $content -match "__cursor_patched__"
}

# Backup original file
function Backup-MainJs {
    param([string]$MainJsPath)
    
    $backupDir = Join-Path (Split-Path -Parent $MainJsPath) "backups"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = Join-Path $backupDir "main.js.backup_$timestamp"
    
    # Check if original backup exists
    $originalBackup = Join-Path $backupDir "main.js.original"
    if (-not (Test-Path $originalBackup)) {
        Copy-Item $MainJsPath $originalBackup -Force
        Write-Log "Created original backup: $originalBackup"
    }
    
    Copy-Item $MainJsPath $backupPath -Force
    Write-Log "Created timestamped backup: $backupPath"
    
    return $originalBackup
}

# Rollback to original version
function Restore-MainJs {
    param([string]$MainJsPath)
    
    $backupDir = Join-Path (Split-Path -Parent $MainJsPath) "backups"
    $originalBackup = Join-Path $backupDir "main.js.original"
    
    if (Test-Path $originalBackup) {
        Copy-Item $originalBackup $MainJsPath -Force
        Write-Log "Rolled back to original version successfully" "INFO"
        return $true
    } else {
        Write-Log "Original backup file not found" "ERROR"
        return $false
    }
}

# Inject Hook code
function Inject-Hook {
    param(
        [string]$MainJsPath,
        [string]$HookScriptPath
    )
    
    # Read Hook script content
    $hookContent = Get-Content $HookScriptPath -Raw -Encoding UTF8
    
    # Read main.js content
    $mainContent = Get-Content $MainJsPath -Raw -Encoding UTF8
    
    # Find injection point: after Sentry initialization code
    # Sentry initialization signature: _sentryDebugIds
    $sentryPattern = '(?<=\}\(\);)\s*(?=var\s+\w+\s*=\s*function)'
    
    if ($mainContent -match $sentryPattern) {
        # Inject after Sentry initialization
        $injectionPoint = $mainContent.IndexOf('}();') + 4
        $newContent = $mainContent.Substring(0, $injectionPoint) + "`n`n// ========== Cursor Hook Injection Start ==========`n" + $hookContent + "`n// ========== Cursor Hook Injection End ==========`n`n" + $mainContent.Substring($injectionPoint)
    } else {
        # Fallback: Inject at the beginning of the file (after copyright header)
        $copyrightEnd = $mainContent.IndexOf('*/') + 2
        if ($copyrightEnd -gt 2) {
            $newContent = $mainContent.Substring(0, $copyrightEnd) + "`n`n// ========== Cursor Hook Injection Start ==========`n" + $hookContent + "`n// ========== Cursor Hook Injection End ==========`n`n" + $mainContent.Substring($copyrightEnd)
        } else {
            $newContent = "// ========== Cursor Hook Injection Start ==========`n" + $hookContent + "`n// ========== Cursor Hook Injection End ==========`n`n" + $mainContent
        }
    }
    
    # Write modified content
    Set-Content -Path $MainJsPath -Value $newContent -Encoding UTF8 -NoNewline

    return $true
}

# Stop Cursor processes
function Stop-CursorProcess {
    $cursorProcesses = Get-Process -Name "Cursor*" -ErrorAction SilentlyContinue

    if ($cursorProcesses) {
        Write-Log "Cursor processes found running, terminating..."
        $cursorProcesses | Stop-Process -Force
        Start-Sleep -Seconds 2
        Write-Log "Cursor processes stopped"
    }
}

# Main function
function Main {
    Write-Host ""
    Write-Host "$BLUE========================================$NC"
    Write-Host "$BLUE   Cursor Hook Injection Tool (Windows) $NC"
    Write-Host "$BLUE========================================$NC"
    Write-Host ""

    # Locate Cursor main.js path
    $mainJsPath = Get-CursorPath
    if (-not $mainJsPath) {
        Write-Log "Cursor installation path not found" "ERROR"
        Write-Log "Please ensure Cursor is properly installed" "ERROR"
        exit 1
    }
    Write-Log "Found Cursor main.js: $mainJsPath"

    # Rollback mode
    if ($Rollback) {
        Write-Log "Executing rollback operation..."
        Stop-CursorProcess
        if (Restore-MainJs -MainJsPath $mainJsPath) {
            Write-Log "Rollback completed successfully!" "INFO"
        } else {
            Write-Log "Rollback failed!" "ERROR"
            exit 1
        }
        exit 0
    }

    # Check if already injected
    if ((Test-AlreadyInjected -MainJsPath $mainJsPath) -and -not $Force) {
        Write-Log "Hook is already injected; no action needed" "WARN"
        Write-Log "To force re-injection, use the -Force parameter" "INFO"
        exit 0
    }

    # Get Hook script path
    $hookScriptPath = Get-HookScriptPath
    if (-not $hookScriptPath) {
        Write-Log "cursor_hook.js file not found" "ERROR"
        Write-Log "Please ensure cursor_hook.js is in the same directory as this script" "ERROR"
        exit 1
    }
    Write-Log "Found Hook script: $hookScriptPath"

    # Terminate Cursor processes
    Stop-CursorProcess

    # Backup original file
    Write-Log "Backing up original file..."
    $backupPath = Backup-MainJs -MainJsPath $mainJsPath

    # Inject Hook code
    Write-Log "Injecting Hook code..."
    try {
        if (Inject-Hook -MainJsPath $mainJsPath -HookScriptPath $hookScriptPath) {
            Write-Log "Hook injected successfully!" "INFO"
        } else {
            Write-Log "Hook injection failed!" "ERROR"
            exit 1
        }
    } catch {
        Write-Log "Error occurred during injection: $_" "ERROR"
        Write-Log "Rolling back..." "WARN"
        Restore-MainJs -MainJsPath $mainJsPath
        exit 1
    }

    Write-Host ""
    Write-Host "$GREEN========================================$NC"
    Write-Host "$GREEN   ✅ Hook Injection Complete!          $NC"
    Write-Host "$GREEN========================================$NC"
    Write-Host ""
    Write-Log "You can now launch Cursor"
    Write-Log "ID configuration file location: $env:USERPROFILE\.cursor_ids.json"
    Write-Host ""
    Write-Host "${YELLOW}Notes:$NC"
    Write-Host "  - To rollback: .\inject_hook_win.ps1 -Rollback"
    Write-Host "  - To force re-inject: .\inject_hook_win.ps1 -Force"
    Write-Host "  - To enable debug logging: .\inject_hook_win.ps1 -Debug"
    Write-Host ""
}

# Execute main function
Main
