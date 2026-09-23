# Set output encoding to UTF-8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Color definitions (compatible with PowerShell 5.1 and 7.x)
$ESC = [char]27
$RED = "$ESC[31m"
$GREEN = "$ESC[32m"
$YELLOW = "$ESC[33m"
$BLUE = "$ESC[34m"
$NC = "$ESC[0m"

# Try resizing terminal window to 120x40 (Columns x Rows) on startup; silently ignore if unsupported/fails
function Try-ResizeTerminalWindow {
    param(
        [int]$Columns = 120,
        [int]$Rows = 40
    )

    # Method 1: Adjust via PowerShell Host RawUI (traditional console, ConEmu, etc.)
    try {
        $rawUi = $null
        if ($Host -and $Host.UI -and $Host.UI.RawUI) {
            $rawUi = $Host.UI.RawUI
        }

        if ($rawUi) {
            try {
                # BufferSize must be >= WindowSize, otherwise throws exception
                $bufferSize = $rawUi.BufferSize
                $newBufferSize = New-Object System.Management.Automation.Host.Size (
                    ([Math]::Max($bufferSize.Width, $Columns)),
                    ([Math]::Max($bufferSize.Height, $Rows))
                )
                $rawUi.BufferSize = $newBufferSize
            } catch {
                # Silently ignore
            }

            try {
                $rawUi.WindowSize = New-Object System.Management.Automation.Host.Size ($Columns, $Rows)
            } catch {
                # Silently ignore
            }
        }
    } catch {
        # Silently ignore
    }

    # Method 2: Try ANSI escape sequence (Windows Terminal, etc.)
    try {
        if (-not [Console]::IsOutputRedirected) {
            $escChar = [char]27
            [Console]::Out.Write("$escChar[8;${Rows};${Columns}t")
        }
    } catch {
        # Silently ignore
    }
}

Try-ResizeTerminalWindow -Columns 120 -Rows 40

# Path resolution: Prefer .NET system directories to avoid missing env var issues
function Get-FolderPathSafe {
    param(
        [Parameter(Mandatory = $true)][System.Environment+SpecialFolder]$SpecialFolder,
        [Parameter(Mandatory = $true)][string]$EnvVarName,
        [Parameter(Mandatory = $true)][string]$FallbackRelative,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $path = [Environment]::GetFolderPath($SpecialFolder)
    if ([string]::IsNullOrWhiteSpace($path)) {
        $envValue = [Environment]::GetEnvironmentVariable($EnvVarName)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            $path = $envValue
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $userProfile = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            $userProfile = [Environment]::GetEnvironmentVariable("USERPROFILE")
        }
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
            $path = Join-Path $userProfile $FallbackRelative
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host "$YELLOW⚠️  [Path]$NC $Label could not be resolved, will try fallback methods"
    } else {
        Write-Host "$BLUEℹ️  [Path]$NC ${Label}: $path"
    }
    return $path
}

function Initialize-CursorPaths {
    Write-Host "$BLUEℹ️  [Path]$NC Resolving Cursor-related paths..."
    $global:CursorAppDataRoot = Get-FolderPathSafe `
        -SpecialFolder ([System.Environment+SpecialFolder]::ApplicationData) `
        -EnvVarName "APPDATA" `
        -FallbackRelative "AppData\Roaming" `
        -Label "Roaming AppData"
    $global:CursorLocalAppDataRoot = Get-FolderPathSafe `
        -SpecialFolder ([System.Environment+SpecialFolder]::LocalApplicationData) `
        -EnvVarName "LOCALAPPDATA" `
        -FallbackRelative "AppData\Local" `
        -Label "Local AppData"
    $global:CursorUserProfileRoot = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($global:CursorUserProfileRoot)) {
        $global:CursorUserProfileRoot = [Environment]::GetEnvironmentVariable("USERPROFILE")
    }
    if (-not [string]::IsNullOrWhiteSpace($global:CursorUserProfileRoot)) {
        Write-Host "$BLUEℹ️  [Path]$NC User profile directory: $global:CursorUserProfileRoot"
    }
    $global:CursorAppDataDir = if ($global:CursorAppDataRoot) { Join-Path $global:CursorAppDataRoot "Cursor" } else { $null }
    $global:CursorLocalAppDataDir = if ($global:CursorLocalAppDataRoot) { Join-Path $global:CursorLocalAppDataRoot "Cursor" } else { $null }
    $global:CursorStorageDir = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir "User\globalStorage" } else { $null }
    $global:CursorStorageFile = if ($global:CursorStorageDir) { Join-Path $global:CursorStorageDir "storage.json" } else { $null }
    $global:CursorBackupDir = if ($global:CursorStorageDir) { Join-Path $global:CursorStorageDir "backups" } else { $null }

    if ($global:CursorStorageDir -and -not (Test-Path $global:CursorStorageDir)) {
        Write-Host "$YELLOW⚠️  [Path]$NC Global storage directory does not exist: $global:CursorStorageDir"
    }
    if ($global:CursorStorageFile) {
        if (Test-Path $global:CursorStorageFile) {
            Write-Host "$GREEN✅ [Path]$NC Found configuration file: $global:CursorStorageFile"
        } else {
            Write-Host "$YELLOW⚠️  [Path]$NC Configuration file does not exist: $global:CursorStorageFile"
        }
    }
}

function Normalize-CursorInstallCandidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $candidate = $Path.Trim().Trim('"')
    if (Test-Path $candidate -PathType Leaf) {
        $candidate = Split-Path -Parent $candidate
    }
    return $candidate
}

function Test-CursorInstallPath {
    param([string]$Path)
    $candidate = Normalize-CursorInstallCandidate -Path $Path
    if (-not $candidate) {
        return $false
    }
    $exePath = Join-Path $candidate "Cursor.exe"
    return (Test-Path $exePath)
}

function Get-CursorInstallPathFromRegistry {
    $results = @()
    $uninstallKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($key in $uninstallKeys) {
        try {
            $items = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                if (-not $item.DisplayName -or $item.DisplayName -notlike "*Cursor*") {
                    continue
                }
                $candidate = $null
                if ($item.InstallLocation) {
                    $candidate = $item.InstallLocation
                } elseif ($item.DisplayIcon) {
                    $candidate = $item.DisplayIcon.Split(',')[0].Trim('"')
                } elseif ($item.UninstallString) {
                    $candidate = $item.UninstallString.Split(' ')[0].Trim('"')
                }
                if ($candidate) {
                    $results += $candidate
                }
            }
        } catch {
            Write-Host "$YELLOW⚠️  [Path]$NC Failed to read registry key: $key"
        }
    }
    return $results | Where-Object { $_ } | Select-Object -Unique
}

function Request-CursorInstallPathFromUser {
    Write-Host "$YELLOW💡 [Tip]$NC Auto-detection failed. You can manually select the Cursor install directory (containing Cursor.exe)"
    $selectedPath = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Please select the Cursor installation directory (containing Cursor.exe)"
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selectedPath = $dialog.SelectedPath
        }
    } catch {
        Write-Host "$YELLOW⚠️  [Tip]$NC Could not open folder dialog, falling back to console input"
    }
    if (-not $selectedPath) {
        $manualInput = Read-Host "Please enter the Cursor installation directory (containing Cursor.exe), or press Enter to cancel"
        if (-not [string]::IsNullOrWhiteSpace($manualInput)) {
            $selectedPath = $manualInput
        }
    }
    if ($selectedPath) {
        $normalized = Normalize-CursorInstallCandidate -Path $selectedPath
        if ($normalized -and (Test-CursorInstallPath -Path $normalized)) {
            Write-Host "$GREEN✅ [Found]$NC Manually specified install path: $normalized"
            return $normalized
        }
        Write-Host "$RED❌ [Error]$NC Invalid manual path: $selectedPath"
    }
    return $null
}

function Resolve-CursorInstallPath {
    param([switch]$AllowPrompt)
    if ($global:CursorInstallPath -and (Test-CursorInstallPath -Path $global:CursorInstallPath)) {
        return $global:CursorInstallPath
    }

    Write-Host "$BLUE🔎 [Path]$NC Detecting Cursor installation directory..."
    $candidates = @()
    if ($global:CursorLocalAppDataRoot) {
        $candidates += (Join-Path $global:CursorLocalAppDataRoot "Programs\Cursor")
    }
    $programFiles = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles)
    if ($programFiles) {
        $candidates += (Join-Path $programFiles "Cursor")
    }
    $programFilesX86 = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
    if ($programFilesX86) {
        $candidates += (Join-Path $programFilesX86 "Cursor")
    }

    $regCandidates = @(Get-CursorInstallPathFromRegistry)
    if ($regCandidates.Count -gt 0) {
        Write-Host "$BLUEℹ️  [Path]$NC Found candidate path(s) from registry: $($regCandidates -join '; ')"
        $candidates += $regCandidates
    }

    $fixedDrives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' }
    foreach ($drive in $fixedDrives) {
        $root = $drive.RootDirectory.FullName
        $candidates += (Join-Path $root "Program Files\Cursor")
        $candidates += (Join-Path $root "Program Files (x86)\Cursor")
        $candidates += (Join-Path $root "Cursor")
    }

    $candidates = $candidates | Where-Object { $_ } | Select-Object -Unique
    $totalCandidates = $candidates.Count
    for ($i = 0; $i -lt $totalCandidates; $i++) {
        $candidate = Normalize-CursorInstallCandidate -Path $candidates[$i]
        $attempt = $i + 1
        if (-not $candidate) {
            continue
        }
        Write-Host "$BLUE⏳ [Path]$NC ($attempt/$totalCandidates) Trying install path: $candidate"
        if (Test-CursorInstallPath -Path $candidate) {
            $global:CursorInstallPath = $candidate
            Write-Host "$GREEN✅ [Found]$NC Found Cursor install path: $candidate"
            return $candidate
        }
    }

    if ($AllowPrompt) {
        $manualPath = Request-CursorInstallPathFromUser
        if ($manualPath) {
            $global:CursorInstallPath = $manualPath
            return $manualPath
        }
    }

    Write-Host "$RED❌ [Error]$NC Cursor application install path not found"
    Write-Host "$YELLOW💡 [Tip]$NC Please ensure Cursor is properly installed or specify the path manually"
    return $null
}

# Configuration file paths (use global variables after initialization)
Initialize-CursorPaths
$STORAGE_FILE = $global:CursorStorageFile
$BACKUP_DIR = $global:CursorBackupDir

# Native PowerShell random string generation
function Generate-RandomString {
    param([int]$Length)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $result = ""
    for ($i = 0; $i -lt $Length; $i++) {
        $result += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $result
}

# 🔍 Lightweight JavaScript brace matcher (locates function boundaries within snippets without broken regexes)
# Note: Lightweight parser capable of handling minified function bodies in main.js (with try/catch, strings, comments).
function Find-JsMatchingBraceEnd {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$OpenBraceIndex,
        [int]$MaxScan = 20000
    )

    if ($OpenBraceIndex -lt 0 -or $OpenBraceIndex -ge $Text.Length) {
        return -1
    }

    $limit = [Math]::Min($Text.Length, $OpenBraceIndex + $MaxScan)

    $depth = 1
    $inSingle = $false
    $inDouble = $false
    $inTemplate = $false
    $inLineComment = $false
    $inBlockComment = $false
    $escape = $false

    for ($i = $OpenBraceIndex + 1; $i -lt $limit; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $limit) { $Text[$i + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($ch -eq "`n") { $inLineComment = $false }
            continue
        }
        if ($inBlockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $inBlockComment = $false; $i++; continue }
            continue
        }

        if ($inSingle) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq "'") { $inSingle = $false }
            continue
        }
        if ($inDouble) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq '"') { $inDouble = $false }
            continue
        }
        if ($inTemplate) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq '`') { $inTemplate = $false }
            continue
        }

        # Comment detection (only when not in a string)
        if ($ch -eq '/' -and $next -eq '/') { $inLineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $inBlockComment = $true; $i++; continue }

        # String / Template literals
        if ($ch -eq "'") { $inSingle = $true; continue }
        if ($ch -eq '"') { $inDouble = $true; continue }
        if ($ch -eq '`') { $inTemplate = $true; continue }

        # Brace depth
        if ($ch -eq '{') { $depth++; continue }
        if ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

# 🔧 Modify Cursor core JS files for device ID bypass (Enhanced triple-method approach)
# Method A: someValue placeholder replacement - stable anchor, independent of obfuscated function names
# Method B: b6 targeted rewrite - machine code source function returns fixed values directly
# Method C: Loader Stub + External Hook - main/shared processes load external hook file
function Modify-CursorJSFiles {
    Write-Host ""
    Write-Host "$BLUE🔧 [Kernel Patch]$NC Starting modification of Cursor core JS files for device ID bypass..."
    Write-Host "$BLUE💡 [Method]$NC Using enhanced triple-method approach: Placeholder replacement + b6 rewrite + Loader Stub + External Hook"
    Write-Host ""

    # Windows Cursor application path (auto-detect + manual fallback)
    $cursorAppPath = Resolve-CursorInstallPath -AllowPrompt
    if (-not $cursorAppPath) {
        return $false
    }

    # Generate or reuse device identifiers (prioritize configured values)
    $useConfigIds = $false
    if ($global:CursorIds -and $global:CursorIds.machineId -and $global:CursorIds.macMachineId -and $global:CursorIds.devDeviceId -and $global:CursorIds.sqmId) {
        $machineId = [string]$global:CursorIds.machineId
        $macMachineId = [string]$global:CursorIds.macMachineId
        $deviceId = [string]$global:CursorIds.devDeviceId
        $sqmId = [string]$global:CursorIds.sqmId
        # Machine GUID for emulating registry / raw machine ID reading
        $machineGuid = if ($global:CursorIds.machineGuid) { [string]$global:CursorIds.machineGuid } else { [System.Guid]::NewGuid().ToString().ToLower() }
        $sessionId = if ($global:CursorIds.sessionId) { [string]$global:CursorIds.sessionId } else { [System.Guid]::NewGuid().ToString().ToLower() }
        # Generate/normalize firstSessionDate with UTC time to avoid timezone semantic errors; also handle DateTime from ConvertFrom-Json
        $firstSessionDateValue = if ($global:CursorIds.firstSessionDate) {
            $rawFirstSessionDate = $global:CursorIds.firstSessionDate
            if ($rawFirstSessionDate -is [DateTime]) {
                $rawFirstSessionDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            } elseif ($rawFirstSessionDate -is [DateTimeOffset]) {
                $rawFirstSessionDate.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            } else {
                [string]$rawFirstSessionDate
            }
        } else {
            (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        }
        $macAddress = if ($global:CursorIds.macAddress) { [string]$global:CursorIds.macAddress } else { "00:11:22:33:44:55" }
        $useConfigIds = $true
    } else {
        $randomBytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rng.GetBytes($randomBytes)
        $machineId = [System.BitConverter]::ToString($randomBytes) -replace '-',''
        $rng.Dispose()
        $deviceId = [System.Guid]::NewGuid().ToString().ToLower()
        $randomBytes2 = New-Object byte[] 32
        $rng2 = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rng2.GetBytes($randomBytes2)
        $macMachineId = [System.BitConverter]::ToString($randomBytes2) -replace '-',''
        $rng2.Dispose()
        $sqmId = "{" + [System.Guid]::NewGuid().ToString().ToUpper() + "}"
        # Machine GUID for emulating registry / raw machine ID reading
        $machineGuid = [System.Guid]::NewGuid().ToString().ToLower()
        $sessionId = [System.Guid]::NewGuid().ToString().ToLower()
        # Generate firstSessionDate with UTC time
        $firstSessionDateValue = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $macAddress = "00:11:22:33:44:55"
    }

    if ($useConfigIds) {
        Write-Host "$GREEN🔑 [Prepare]$NC Using configured device identifiers"
    } else {
        Write-Host "$GREEN🔑 [Generate]$NC Generated new device identifiers"
    }
    Write-Host "   machineId: $($machineId.Substring(0,16))..."
    Write-Host "   machineGuid: $($machineGuid.Substring(0,16))..."
    Write-Host "   deviceId: $($deviceId.Substring(0,16))..."
    Write-Host "   macMachineId: $($macMachineId.Substring(0,16))..."
    Write-Host "   sqmId: $sqmId"

    # Save ID configuration to user profile (for Hook to read)
    # Remove old config on each run to ensure fresh identifiers
    $idsConfigPath = "$env:USERPROFILE\.cursor_ids.json"
    if (Test-Path $idsConfigPath) {
        Remove-Item -Path $idsConfigPath -Force
        Write-Host "$YELLOW🗑️  [Clean]$NC Removed old ID configuration file"
    }
    $idsConfig = @{
        machineId = $machineId
        machineGuid = $machineGuid
        macMachineId = $macMachineId
        devDeviceId = $deviceId
        sqmId = $sqmId
        macAddress = $macAddress
        sessionId = $sessionId
        firstSessionDate = $firstSessionDateValue
        createdAt = $firstSessionDateValue
    }
    $idsConfig | ConvertTo-Json | Set-Content -Path $idsConfigPath -Encoding UTF8
    Write-Host "$GREEN💾 [Save]$NC New ID configuration saved to: $idsConfigPath"

    # Deploy external Hook file (loaded by Loader Stub, with multi-mirror download fallback)
    $hookTargetPath = "$env:USERPROFILE\.cursor_hook.js"
    # Compatibility: When executed via `irm ... | iex`, $PSScriptRoot might be empty
    $hookSourceCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $hookSourceCandidates += (Join-Path $PSScriptRoot "..\hook\cursor_hook.js")
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (-not [string]::IsNullOrWhiteSpace($scriptDir)) {
            $hookSourceCandidates += (Join-Path $scriptDir "..\hook\cursor_hook.js")
        }
    }
    $cwdPath = $null
    try { $cwdPath = (Get-Location).Path } catch { $cwdPath = $null }
    if (-not [string]::IsNullOrWhiteSpace($cwdPath)) {
        $hookSourceCandidates += (Join-Path $cwdPath "scripts\hook\cursor_hook.js")
    }
    $hookSourcePath = $hookSourceCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $hookDownloadUrls = @(
        "https://raw.githubusercontent.com/yuaotian/go-cursor-help/master/scripts/hook/cursor_hook.js",
        "https://wget.la/https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://down.npee.cn/?https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://xget.xi-xu.me/gh/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://gh-proxy.com/https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://gh.chjina.com/https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
    )
    # Support overriding download mirrors via environment variable (comma-separated)
    if ($env:CURSOR_HOOK_DOWNLOAD_URLS) {
        $hookDownloadUrls = $env:CURSOR_HOOK_DOWNLOAD_URLS -split '\s*,\s*' | Where-Object { $_ }
        Write-Host "$BLUEℹ️  [Hook]$NC Custom download mirror list detected, prioritizing custom mirrors"
    }
    if ($hookSourcePath) {
        try {
            Copy-Item -Path $hookSourcePath -Destination $hookTargetPath -Force
            Write-Host "$GREEN✅ [Hook]$NC External Hook deployed: $hookTargetPath"
        } catch {
            Write-Host "$YELLOW⚠️  [Hook]$NC Failed to copy local Hook file, attempting online download..."
        }
    }
    if (-not (Test-Path $hookTargetPath)) {
        Write-Host "$BLUEℹ️  [Hook]$NC Downloading external Hook for device ID interception..."
        $originalProgressPreference = $ProgressPreference
        $ProgressPreference = 'Continue'
        try {
            if ($hookDownloadUrls.Count -eq 0) {
                Write-Host "$YELLOW⚠️  [Hook]$NC Download URL list is empty, skipping online download"
            } else {
                $totalUrls = $hookDownloadUrls.Count
                for ($i = 0; $i -lt $totalUrls; $i++) {
                    $url = $hookDownloadUrls[$i]
                    $attempt = $i + 1
                    Write-Host "$BLUE⏳ [Hook]$NC ($attempt/$totalUrls) Current download mirror: $url"
                    try {
                        Invoke-WebRequest -Uri $url -OutFile $hookTargetPath -UseBasicParsing -ErrorAction Stop
                        Write-Host "$GREEN✅ [Hook]$NC External Hook downloaded successfully: $hookTargetPath"
                        break
                    } catch {
                        Write-Host "$YELLOW⚠️  [Hook]$NC External Hook download failed: $url"
                        if (Test-Path $hookTargetPath) {
                            Remove-Item -Path $hookTargetPath -Force
                        }
                    }
                }
            }
        } finally {
            $ProgressPreference = $originalProgressPreference
        }
        if (-not (Test-Path $hookTargetPath)) {
            Write-Host "$YELLOW⚠️  [Hook]$NC All external Hook downloads failed"
        }
    }

    # Target JS files (Windows paths, in priority order)
    $jsFiles = @(
        "$cursorAppPath\resources\app\out\main.js",
        # Shared process aggregates telemetry and requires synchronous injection
        "$cursorAppPath\resources\app\out\vs\code\electron-utility\sharedProcess\sharedProcessMain.js"
    )

    $modifiedCount = 0

    # Stop Cursor processes
    Write-Host "$BLUE🔄 [Close]$NC Stopping Cursor processes for file modification..."
    Stop-AllCursorProcesses -MaxRetries 3 -WaitSeconds 3 | Out-Null

    # Create backup directory
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = "$cursorAppPath\resources\app\out\backups"

    Write-Host "$BLUE💾 [Backup]$NC Creating Cursor JS file backups..."
    try {
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

        # Check for original backups
        $originalBackup = "$backupPath\main.js.original"

        foreach ($file in $jsFiles) {
            if (-not (Test-Path $file)) {
                Write-Host "$YELLOW⚠️  [Warning]$NC File does not exist: $(Split-Path $file -Leaf)"
                continue
            }

            $fileName = Split-Path $file -Leaf
            $fileOriginalBackup = "$backupPath\$fileName.original"

            # Create original backup if not present
            if (-not (Test-Path $fileOriginalBackup)) {
                # Check if current file has already been modified
                $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
                if ($content -and $content -match "__cursor_patched__") {
                    Write-Host "$YELLOW⚠️  [Warning]$NC File already modified without original backup, using current version as base"
                }
                Copy-Item $file $fileOriginalBackup -Force
                Write-Host "$GREEN✅ [Backup]$NC Original backup created: $fileName"
            } else {
                # Restore from original backup to ensure clean injection every time
                Write-Host "$BLUE🔄 [Restore]$NC Restoring from original backup: $fileName"
                Copy-Item $fileOriginalBackup $file -Force
            }
        }

        # Create timestamped backup (records state before modification)
        foreach ($file in $jsFiles) {
            if (Test-Path $file) {
                $fileName = Split-Path $file -Leaf
                Copy-Item $file "$backupPath\$fileName.backup_$timestamp" -Force
            }
        }
        Write-Host "$GREEN✅ [Backup]$NC Timestamped backup created: $backupPath"
    } catch {
        Write-Host "$RED❌ [Error]$NC Backup creation failed: $($_.Exception.Message)"
        return $false
    }

    # Modify JS files (re-injecting cleanly since restored from original backup)
    Write-Host "$BLUE🔧 [Modify]$NC Modifying JS files (applying device identifiers)..."

    foreach ($file in $jsFiles) {
        if (-not (Test-Path $file)) {
            Write-Host "$YELLOW⚠️  [Skip]$NC File does not exist: $(Split-Path $file -Leaf)"
            continue
        }

        Write-Host "$BLUE📝 [Process]$NC Processing: $(Split-Path $file -Leaf)"

        try {
            $content = Get-Content $file -Raw -Encoding UTF8
            $replaced = $false
            $replacedB6 = $false

            # ========== Method A: someValue Placeholder Replacement (Stable Anchor) ==========
            # These strings are fixed placeholders across versions and are not altered by obfuscators.
            # Important note:
            # In Cursor's main.js, placeholders appear as string literals, e.g.:
            #   this.machineId="someValue.machineId"
            # If someValue.machineId is replaced directly with "\"<value>\"", it results in ""<value>"" causing JS syntax errors.
            # Therefore, we replace full string literals (including quotes) safely using JSON string encoding.

            # firstSessionDate (reset first session date)
            if (-not $firstSessionDateValue) {
                $firstSessionDateValue = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            }

            $placeholders = @(
                @{ Name = 'someValue.machineId';         Value = [string]$machineId },
                @{ Name = 'someValue.macMachineId';      Value = [string]$macMachineId },
                @{ Name = 'someValue.devDeviceId';       Value = [string]$deviceId },
                @{ Name = 'someValue.sqmId';             Value = [string]$sqmId },
                @{ Name = 'someValue.sessionId';         Value = [string]$sessionId },
                @{ Name = 'someValue.firstSessionDate';  Value = [string]$firstSessionDateValue }
            )

            foreach ($ph in $placeholders) {
                $name = $ph.Name
                $jsonValue = ($ph.Value | ConvertTo-Json -Compress)  # Generates double-quoted JSON string literal

                $changed = $false

                # Prioritize replacing quoted placeholder literals to avoid broken syntax
                $doubleLiteral = '"' + $name + '"'
                if ($content.Contains($doubleLiteral)) {
                    $content = $content.Replace($doubleLiteral, $jsonValue)
                    $changed = $true
                }
                $singleLiteral = "'" + $name + "'"
                if ($content.Contains($singleLiteral)) {
                    $content = $content.Replace($singleLiteral, $jsonValue)
                    $changed = $true
                }

                # Fallback: If placeholder appears unquoted, replace with JSON string literal (includes quotes)
                if (-not $changed -and $content.Contains($name)) {
                    $content = $content.Replace($name, $jsonValue)
                    $changed = $true
                }

                if ($changed) {
                    Write-Host "   $GREEN✓$NC [Method A] Replaced $name"
                    $replaced = $true
                }
            }

            # ========== Method B: b6 Targeted Rewrite (Machine code source function, main.js only) ==========
            # Note: b6(t) is the core generation function for machineId: t=true returns raw value, t=false returns hash
            if ((Split-Path $file -Leaf) -eq "main.js") {
                # Match within out-build/vs/base/node/id.js module + brace pairing for function boundaries
                # Purpose: Increase cross-version reliability without risking cross-module syntax corruption.
                try {
                    $moduleMarker = "out-build/vs/base/node/id.js"
                    $markerIndex = $content.IndexOf($moduleMarker)
                    if ($markerIndex -lt 0) {
                        throw "id.js module marker not found"
                    }

                    $windowLen = [Math]::Min($content.Length - $markerIndex, 200000)
                    $windowText = $content.Substring($markerIndex, $windowLen)

                    $hashRegex = [regex]::new('createHash\(["'']sha256["'']\)')
                    $hashMatches = $hashRegex.Matches($windowText)
                    Write-Host "   $BLUEℹ️  $NC [Method B Diag] id.js offset=$markerIndex | sha256 createHash hits=$($hashMatches.Count)"
                    $patched = $false
                    $diagLines = @()
                    $candidateNo = 0

                    foreach ($hm in $hashMatches) {
                        $candidateNo++
                        $hashPos = $hm.Index
                        $funcStart = $windowText.LastIndexOf("async function", $hashPos)
                        if ($funcStart -lt 0) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate #${candidateNo}: 'async function' start not found" }
                            continue
                        }

                        $openBrace = $windowText.IndexOf("{", $funcStart)
                        if ($openBrace -lt 0) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate #${candidateNo}: Opening brace not found" }
                            continue
                        }

                        $endBrace = Find-JsMatchingBraceEnd -Text $windowText -OpenBraceIndex $openBrace -MaxScan 20000
                        if ($endBrace -lt 0) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate #${candidateNo}: Brace matching failed (not closed within scan limit)" }
                            continue
                        }

                        $funcText = $windowText.Substring($funcStart, $endBrace - $funcStart + 1)
                        if ($funcText.Length -gt 8000) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate #${candidateNo}: Function body too long (len=$($funcText.Length)), skipped" }
                            continue
                        }

                        $sig = [regex]::Match($funcText, '^async function (\w+)\((\w+)\)')
                        if (-not $sig.Success) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate #${candidateNo}: Failed to parse function signature (async function name(param))" }
                            continue
                        }
                        $fn = $sig.Groups[1].Value
                        $param = $sig.Groups[2].Value

                        # Signature check: sha256 + hex digest + return param ? raw : hash
                        $hasDigest = ($funcText -match '\.digest\(["'']hex["'']\)')
                        $hasReturn = ($funcText -match ('return\s+' + [regex]::Escape($param) + '\?\w+:\w+\}'))
                        if ($candidateNo -le 3) {
                            $diagLines += "Candidate #${candidateNo}: $fn($param) len=$($funcText.Length) digest=$hasDigest return=$hasReturn"
                        }
                        if (-not $hasDigest) { continue }
                        if (-not $hasReturn) { continue }

                        $replacement = "async function $fn($param){return $param?'$machineGuid':'$machineId';}"
                        $absStart = $markerIndex + $funcStart
                        $absEnd = $markerIndex + $endBrace
                        $content = $content.Substring(0, $absStart) + $replacement + $content.Substring($absEnd + 1)

                        Write-Host "   $BLUEℹ️  $NC [Method B Diag] Matched candidate #${candidateNo}: $fn($param) len=$($funcText.Length)"
                        Write-Host "   $GREEN✓$NC [Method B] Rewrote $fn($param) machine code source function"
                        $replacedB6 = $true
                        $patched = $true
                        break
                    }

                    if (-not $patched) {
                        Write-Host "   $YELLOW⚠️  $NC [Method B] Machine code source function signature not found, skipped"
                        foreach ($d in ($diagLines | Select-Object -First 3)) {
                            Write-Host "      $BLUEℹ️  $NC [Method B Diag] $d"
                        }
                    }
                } catch {
                    Write-Host "   $YELLOW⚠️  $NC [Method B] Locate failed, skipped: $($_.Exception.Message)"
                }
            }

            # ========== Method C: Loader Stub Injection ==========
            # Note: Injects a lightweight loader into main/shared process; hook logic is maintained in external cursor_hook.js

            $injectCode = @"
// ========== Cursor Hook Loader Start ==========
;(async function(){/*__cursor_patched__*/
'use strict';
if (globalThis.__cursor_hook_loaded__) return;
globalThis.__cursor_hook_loaded__ = true;

try {
    // ESM/CJS compatibility: Avoid import.meta, dynamically import modules
    var fsMod = await import('fs');
    var pathMod = await import('path');
    var osMod = await import('os');
    var urlMod = await import('url');

    var fs = fsMod && (fsMod.default || fsMod);
    var path = pathMod && (pathMod.default || pathMod);
    var os = osMod && (osMod.default || osMod);
    var url = urlMod && (urlMod.default || urlMod);

    if (fs && path && os && url && typeof url.pathToFileURL === 'function') {
        var hookPath = path.join(os.homedir(), '.cursor_hook.js');
        if (typeof fs.existsSync === 'function' && fs.existsSync(hookPath)) {
            await import(url.pathToFileURL(hookPath).href);
        }
    }
} catch (e) {
    // Silently fail to avoid disrupting application startup
}
})();
// ========== Cursor Hook Loader End ==========

"@

            # Find end of copyright header and inject (inject once only to prevent duplication)
            if ($content -match "__cursor_patched__") {
                Write-Host "   $YELLOW⚠️  $NC [Method C] Existing patch tag detected, skipping duplicate injection"
            } elseif ($content -match '(\*/\s*\n)') {
                $replacement = '$1' + $injectCode
                $content = [regex]::Replace($content, '(\*/\s*\n)', $replacement, 1)
                Write-Host "   $GREEN✓$NC [Method C] Loader Stub injected (after copyright header)"
            } else {
                # Fallback: Inject at the beginning of the file
                $content = $injectCode + $content
                Write-Host "   $GREEN✓$NC [Method C] Loader Stub injected (file beginning)"
            }

            # Verify patch tag count
            $patchedCount = ([regex]::Matches($content, "__cursor_patched__")).Count
            if ($patchedCount -gt 1) {
                throw "Duplicate injection tag detected: $patchedCount"
            }

            # Write modified content
            Set-Content -Path $file -Value $content -Encoding UTF8 -NoNewline

            # Summarize applied methods
            $summaryParts = @()
            if ($replaced) { $summaryParts += "someValue Replacement" }
            if ($replacedB6) { $summaryParts += "b6 Targeted Rewrite" }
            $summaryParts += "Hook Loader"
            $summaryText = ($summaryParts -join " + ")
            Write-Host "$GREEN✅ [Success]$NC Modified successfully with: $summaryText"
            $modifiedCount++

        } catch {
            Write-Host "$RED❌ [Error]$NC File modification failed: $($_.Exception.Message)"
            # Attempt restore from backup
            $fileName = Split-Path $file -Leaf
            $backupFile = "$backupPath\$fileName.original"
            if (Test-Path $backupFile) {
                Copy-Item $backupFile $file -Force
                Write-Host "$YELLOW🔄 [Restore]$NC Restored file from backup"
            }
        }
    }

    if ($modifiedCount -gt 0) {
        Write-Host ""
        Write-Host "$GREEN🎉 [Complete]$NC Successfully modified $modifiedCount JS file(s)"
        Write-Host "$BLUE💾 [Backup]$NC Original backup directory: $backupPath"
        Write-Host "$BLUE💡 [Description]$NC Applied enhanced triple-method approach:"
        Write-Host "   • Method A: someValue placeholder replacement (stable anchor across versions)"
        Write-Host "   • Method B: b6 targeted rewrite (machine code source function)"
        Write-Host "   • Method C: Loader Stub + External Hook (cursor_hook.js)"
        Write-Host "$BLUE📁 [Config]$NC ID configuration file: $idsConfigPath"
        return $true
    } else {
        Write-Host "$RED❌ [Failed]$NC No files were successfully modified"
        return $false
    }
}


# 🚀 Cursor trial folder cleanup function
function Remove-CursorTrialFolders {
    Write-Host ""
    Write-Host "$GREEN🎯 [Core Feature]$NC Executing Cursor trial folder cleanup..."
    Write-Host "$BLUE📋 [Description]$NC This function removes specified Cursor-related directories to reset trial state"
    Write-Host ""

    # Define directories to remove
    $foldersToDelete = @()

    # Windows Administrator profile paths
    $adminPaths = @(
        "C:\Users\Administrator\.cursor",
        "C:\Users\Administrator\AppData\Roaming\Cursor"
    )

    # Current user paths (using resolved user directory and AppData)
    $currentUserPaths = @()
    $userProfileRoot = if ($global:CursorUserProfileRoot) { $global:CursorUserProfileRoot } else { [Environment]::GetEnvironmentVariable("USERPROFILE") }
    if ($userProfileRoot) {
        $currentUserPaths += (Join-Path $userProfileRoot ".cursor")
    }
    if ($global:CursorAppDataDir) {
        $currentUserPaths += $global:CursorAppDataDir
    }

    # Combine all paths
    $foldersToDelete += $adminPaths
    $foldersToDelete += $currentUserPaths

    Write-Host "$BLUE📂 [Detection]$NC Checking the following directories:"
    foreach ($folder in $foldersToDelete) {
        Write-Host "   📁 $folder"
    }
    Write-Host ""

    $deletedCount = 0
    $skippedCount = 0
    $errorCount = 0

    # Delete specified folders
    foreach ($folder in $foldersToDelete) {
        Write-Host "$BLUE🔍 [Check]$NC Checking folder: $folder"

        if (Test-Path $folder) {
            try {
                Write-Host "$YELLOW⚠️  [Warning]$NC Found existing folder, deleting..."
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Host "$GREEN✅ [Success]$NC Deleted folder: $folder"
                $deletedCount++
            }
            catch {
                Write-Host "$RED❌ [Error]$NC Failed to delete folder: $folder"
                Write-Host "$RED💥 [Details]$NC Error: $($_.Exception.Message)"
                $errorCount++
            }
        } else {
            Write-Host "$YELLOW⏭️  [Skip]$NC Folder does not exist: $folder"
            $skippedCount++
        }
        Write-Host ""
    }

    # Display operation statistics
    Write-Host "$GREEN📊 [Stats]$NC Cleanup Summary:"
    Write-Host "   ✅ Successfully deleted: $deletedCount folder(s)"
    Write-Host "   ⏭️  Skipped: $skippedCount folder(s)"
    Write-Host "   ❌ Failed to delete: $errorCount folder(s)"
    Write-Host ""

    if ($deletedCount -gt 0) {
        Write-Host "$GREEN🎉 [Complete]$NC Cursor trial folder cleanup completed!"

        # Pre-create required directory structure to avoid permission issues
        Write-Host "$BLUE🔧 [Fix]$NC Pre-creating required directory structure to avoid permission issues..."

        $cursorAppData = $global:CursorAppDataDir
        $cursorLocalAppData = $global:CursorLocalAppDataDir
        $cursorUserProfile = if ($userProfileRoot) { Join-Path $userProfileRoot ".cursor" } else { "$env:USERPROFILE\.cursor" }

        # Create main directories
        try {
            if ($cursorAppData -and -not (Test-Path $cursorAppData)) {
                New-Item -ItemType Directory -Path $cursorAppData -Force | Out-Null
            }
            if ($cursorUserProfile -and -not (Test-Path $cursorUserProfile)) {
                New-Item -ItemType Directory -Path $cursorUserProfile -Force | Out-Null
            }
            Write-Host "$GREEN✅ [Complete]$NC Directory structure pre-created successfully"
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Issue encountered while pre-creating directories: $($_.Exception.Message)"
        }
    } else {
        Write-Host "$YELLOW🤔 [Tip]$NC No target folders found; they may have already been cleaned"
    }
    Write-Host ""
}

# 🔄 Restart Cursor and wait for configuration file generation
function Restart-CursorAndWait {
    Write-Host ""
    Write-Host "$GREEN🔄 [Restart]$NC Restarting Cursor to regenerate configuration files..."

    if (-not $global:CursorProcessInfo) {
        Write-Host "$RED❌ [Error]$NC Cursor process info not found, unable to restart"
        return $false
    }

    $cursorPath = $global:CursorProcessInfo.Path

    # Ensure path is a string type
    if ($cursorPath -is [array]) {
        $cursorPath = $cursorPath[0]
    }

    # Validate path is not empty
    if ([string]::IsNullOrEmpty($cursorPath)) {
        Write-Host "$RED❌ [Error]$NC Cursor path is empty"
        return $false
    }

    Write-Host "$BLUE📍 [Path]$NC Using path: $cursorPath"

    if (-not (Test-Path $cursorPath)) {
        Write-Host "$RED❌ [Error]$NC Cursor executable does not exist: $cursorPath"

        # Try to re-resolve install path
        $installPath = Resolve-CursorInstallPath -AllowPrompt
        $foundPath = if ($installPath) { Join-Path $installPath "Cursor.exe" } else { $null }
        if ($foundPath -and (Test-Path $foundPath)) {
            Write-Host "$GREEN💡 [Found]$NC Using fallback path: $foundPath"
        } else {
            $foundPath = $null
        }

        if (-not $foundPath) {
            Write-Host "$RED❌ [Error]$NC Unable to find a valid Cursor executable"
            return $false
        }

        $cursorPath = $foundPath
    }

    try {
        Write-Host "$GREEN🚀 [Launch]$NC Starting Cursor..."
        $process = Start-Process -FilePath $cursorPath -PassThru -WindowStyle Hidden

        Write-Host "$YELLOW⏳ [Wait]$NC Waiting 20 seconds for Cursor to fully launch and generate configuration files..."
        Start-Sleep -Seconds 20

        # Check if configuration file was generated
        $configPath = $STORAGE_FILE
        if (-not $configPath) {
            Write-Host "$RED❌ [Error]$NC Cannot resolve configuration file path"
            return $false
        }
        $maxWait = 45
        $waited = 0

        while (-not (Test-Path $configPath) -and $waited -lt $maxWait) {
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting for configuration file generation... ($waited/$maxWait s)"
            Start-Sleep -Seconds 1
            $waited++
        }

        if (Test-Path $configPath) {
            Write-Host "$GREEN✅ [Success]$NC Configuration file generated: $configPath"

            # Extra wait to ensure file is completely written
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting 5 seconds to ensure configuration file is fully written..."
            Start-Sleep -Seconds 5
        } else {
            Write-Host "$YELLOW⚠️  [Warning]$NC Configuration file was not generated within expected time"
            Write-Host "$BLUE💡 [Tip]$NC You may need to manually launch Cursor once to generate the config file"
        }

        # Force close Cursor
        Write-Host "$YELLOW🔄 [Close]$NC Closing Cursor for configuration modification..."
        if ($process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(5000)
        }

        # Ensure all Cursor processes are terminated
        Get-Process -Name "Cursor" -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-Process -Name "cursor" -ErrorAction SilentlyContinue | Stop-Process -Force

        Write-Host "$GREEN✅ [Complete]$NC Cursor restart workflow complete"
        return $true

    } catch {
        Write-Host "$RED❌ [Error]$NC Failed to restart Cursor: $($_.Exception.Message)"
        Write-Host "$BLUE💡 [Debug]$NC Error details: $($_.Exception.GetType().FullName)"
        return $false
    }
}

# 🔒 Force close all Cursor processes (Enhanced)
function Stop-AllCursorProcesses {
    param(
        [int]$MaxRetries = 3,
        [int]$WaitSeconds = 5
    )

    Write-Host "$BLUE🔒 [Process Check]$NC Checking and terminating all Cursor-related processes..."

    # Define all possible Cursor process names
    $cursorProcessNames = @(
        "Cursor",
        "cursor",
        "Cursor Helper",
        "Cursor Helper (GPU)",
        "Cursor Helper (Plugin)",
        "Cursor Helper (Renderer)",
        "CursorUpdater"
    )

    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        Write-Host "$BLUE🔍 [Check]$NC Process check attempt $retry/$MaxRetries..."

        $foundProcesses = @()
        foreach ($processName in $cursorProcessNames) {
            $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($processes) {
                $foundProcesses += $processes
                Write-Host "$YELLOW⚠️  [Found]$NC Process: $processName (PID: $($processes.Id -join ', '))"
            }
        }

        if ($foundProcesses.Count -eq 0) {
            Write-Host "$GREEN✅ [Success]$NC All Cursor processes have been stopped"
            return $true
        }

        Write-Host "$YELLOW🔄 [Close]$NC Stopping $($foundProcesses.Count) Cursor process(es)..."

        # Attempt graceful close first
        foreach ($process in $foundProcesses) {
            try {
                $process.CloseMainWindow() | Out-Null
                Write-Host "$BLUE  • Graceful close: $($process.ProcessName) (PID: $($process.Id))$NC"
            } catch {
                Write-Host "$YELLOW  • Graceful close failed: $($process.ProcessName)$NC"
            }
        }

        Start-Sleep -Seconds 3

        # Force kill remaining processes
        foreach ($processName in $cursorProcessNames) {
            $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($processes) {
                foreach ($process in $processes) {
                    try {
                        Stop-Process -Id $process.Id -Force
                        Write-Host "$RED  • Forced termination: $($process.ProcessName) (PID: $($process.Id))$NC"
                    } catch {
                        Write-Host "$RED  • Forced termination failed: $($process.ProcessName)$NC"
                    }
                }
            }
        }

        if ($retry -lt $MaxRetries) {
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting $WaitSeconds seconds before re-checking..."
            Start-Sleep -Seconds $WaitSeconds
        }
    }

    Write-Host "$RED❌ [Failed]$NC Cursor processes are still running after $MaxRetries attempts"
    return $false
}

# 🔐 Check file permissions and lock status
function Test-FileAccessibility {
    param(
        [string]$FilePath
    )

    Write-Host "$BLUE🔐 [Permission Check]$NC Checking access permissions: $(Split-Path $FilePath -Leaf)"

    if (-not (Test-Path $FilePath)) {
        Write-Host "$RED❌ [Error]$NC File does not exist"
        return $false
    }

    # Check if file is locked
    try {
        $fileStream = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
        $fileStream.Close()
        Write-Host "$GREEN✅ [Permission]$NC File is readable and writable, not locked"
        return $true
    } catch [System.IO.IOException] {
        Write-Host "$RED❌ [Locked]$NC File is locked by another process: $($_.Exception.Message)"
        return $false
    } catch [System.UnauthorizedAccessException] {
        Write-Host "$YELLOW⚠️  [Permission]$NC File permission restricted, attempting to fix..."

        # Attempt to modify file permissions
        try {
            $file = Get-Item $FilePath
            if ($file.IsReadOnly) {
                $file.IsReadOnly = $false
                Write-Host "$GREEN✅ [Fix]$NC Removed read-only attribute"
            }

            # Test again
            $fileStream = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
            $fileStream.Close()
            Write-Host "$GREEN✅ [Permission]$NC Permissions fixed successfully"
            return $true
        } catch {
            Write-Host "$RED❌ [Permission]$NC Unable to fix permissions: $($_.Exception.Message)"
            return $false
        }
    } catch {
        Write-Host "$RED❌ [Error]$NC Unknown error: $($_.Exception.Message)"
        return $false
    }
}

# 🧹 Cursor initialization cleanup function
function Invoke-CursorInitialization {
    Write-Host ""
    Write-Host "$GREEN🧹 [Initialize]$NC Running Cursor initialization cleanup..."
    $BASE_PATH = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir "User" } else { $null }
    if (-not $BASE_PATH) {
        Write-Host "$RED❌ [Error]$NC Cannot resolve Cursor user directory; aborting initialization cleanup"
        return
    }

    $filesToDelete = @(
        (Join-Path -Path $BASE_PATH -ChildPath "globalStorage\state.vscdb"),
        (Join-Path -Path $BASE_PATH -ChildPath "globalStorage\state.vscdb.backup")
    )

    $folderToCleanContents = Join-Path -Path $BASE_PATH -ChildPath "History"
    $folderToDeleteCompletely = Join-Path -Path $BASE_PATH -ChildPath "workspaceStorage"

    Write-Host "$BLUE🔍 [Debug]$NC Base path: $BASE_PATH"

    # Delete specified files
    foreach ($file in $filesToDelete) {
        Write-Host "$BLUE🔍 [Check]$NC Checking file: $file"
        if (Test-Path $file) {
            try {
                Remove-Item -Path $file -Force -ErrorAction Stop
                Write-Host "$GREEN✅ [Success]$NC Deleted file: $file"
            }
            catch {
                Write-Host "$RED❌ [Error]$NC Failed to delete file $file: $($_.Exception.Message)"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Skip]$NC File does not exist, skipping deletion: $file"
        }
    }

    # Clear specified folder contents
    Write-Host "$BLUE🔍 [Check]$NC Checking directory to clear: $folderToCleanContents"
    if (Test-Path $folderToCleanContents) {
        try {
            Get-ChildItem -Path $folderToCleanContents -Recurse | Remove-Item -Force -Recurse -ErrorAction Stop
            Write-Host "$GREEN✅ [Success]$NC Cleared directory contents: $folderToCleanContents"
        }
        catch {
            Write-Host "$RED❌ [Error]$NC Failed to clear directory $folderToCleanContents: $($_.Exception.Message)"
        }
    } else {
        Write-Host "$YELLOW⚠️  [Skip]$NC Directory does not exist, skipping clear: $folderToCleanContents"
    }

    # Delete specified folder completely
    Write-Host "$BLUE🔍 [Check]$NC Checking directory to remove completely: $folderToDeleteCompletely"
    if (Test-Path $folderToDeleteCompletely) {
        try {
            Remove-Item -Path $folderToDeleteCompletely -Recurse -Force -ErrorAction Stop
            Write-Host "$GREEN✅ [Success]$NC Deleted directory: $folderToDeleteCompletely"
        }
        catch {
            Write-Host "$RED❌ [Error]$NC Failed to delete directory $folderToDeleteCompletely: $($_.Exception.Message)"
        }
    } else {
        Write-Host "$YELLOW⚠️  [Skip]$NC Directory does not exist, skipping deletion: $folderToDeleteCompletely"
    }

    Write-Host "$GREEN✅ [Complete]$NC Cursor initialization cleanup complete"
    Write-Host ""
}

# 🔧 Modify system registry MachineGuid
function Update-MachineGuid {
    try {
        Write-Host "$BLUE🔧 [Registry]$NC Updating system registry MachineGuid..."

        # Check if registry path exists, create if missing
        $registryPath = "HKLM:\SOFTWARE\Microsoft\Cryptography"
        if (-not (Test-Path $registryPath)) {
            Write-Host "$YELLOW⚠️  [Warning]$NC Registry path does not exist: $registryPath, creating..."
            New-Item -Path $registryPath -Force | Out-Null
            Write-Host "$GREEN✅ [Info]$NC Registry path created successfully"
        }

        # Get current MachineGuid, default to empty string if missing
        $originalGuid = ""
        try {
            $currentGuid = Get-ItemProperty -Path $registryPath -Name MachineGuid -ErrorAction SilentlyContinue
            if ($currentGuid) {
                $originalGuid = $currentGuid.MachineGuid
                Write-Host "$GREEN✅ [Info]$NC Current registry value:"
                Write-Host "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography"
                Write-Host "    MachineGuid    REG_SZ    $originalGuid"
            } else {
                Write-Host "$YELLOW⚠️  [Warning]$NC MachineGuid value does not exist, will create new value"
            }
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Failed to read registry: $($_.Exception.Message)"
            Write-Host "$YELLOW⚠️  [Warning]$NC Will attempt to create new MachineGuid value"
        }

        # Create backup file (only if original value exists)
        $backupFile = $null
        if ($originalGuid) {
            $backupFile = "$BACKUP_DIR\MachineGuid_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
            Write-Host "$BLUE💾 [Backup]$NC Backing up registry key..."
            $backupResult = Start-Process "reg.exe" -ArgumentList "export", "`"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography`"", "`"$backupFile`"" -NoNewWindow -Wait -PassThru

            if ($backupResult.ExitCode -eq 0) {
                Write-Host "$GREEN✅ [Backup]$NC Registry key backed up to: $backupFile"
            } else {
                Write-Host "$YELLOW⚠️  [Warning]$NC Registry backup failed, continuing..."
                $backupFile = $null
            }
        }

        # Generate new GUID
        $newGuid = [System.Guid]::NewGuid().ToString()
        Write-Host "$BLUE🔄 [Generate]$NC New MachineGuid: $newGuid"

        # Update or create registry value
        Set-ItemProperty -Path $registryPath -Name MachineGuid -Value $newGuid -Force -ErrorAction Stop

        # Verify update
        $verifyGuid = (Get-ItemProperty -Path $registryPath -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($verifyGuid -ne $newGuid) {
            throw "Registry verification failed: updated value ($verifyGuid) does not match expected value ($newGuid)"
        }

        Write-Host "$GREEN✅ [Success]$NC Registry updated successfully:"
        Write-Host "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography"
        Write-Host "    MachineGuid    REG_SZ    $newGuid"
        return $true
    }
    catch {
        Write-Host "$RED❌ [Error]$NC Registry operation failed: $($_.Exception.Message)"

        # Attempt to restore backup if available
        if ($backupFile -and (Test-Path $backupFile)) {
            Write-Host "$YELLOW🔄 [Restore]$NC Restoring from backup..."
            $restoreResult = Start-Process "reg.exe" -ArgumentList "import", "`"$backupFile`"" -NoNewWindow -Wait -PassThru

            if ($restoreResult.ExitCode -eq 0) {
                Write-Host "$GREEN✅ [Restored]$NC Original registry value restored successfully"
            } else {
                Write-Host "$RED❌ [Error]$NC Restore failed. Please manually import backup file: $backupFile"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Warning]$NC Backup file not found or creation failed; cannot auto-restore"
        }

        return $false
    }
}

# 🚫 Disable Cursor Auto-Update (Windows)
function Disable-CursorAutoUpdate {
    Write-Host ""
    Write-Host "$BLUE🚫 [Disable Updates]$NC Attempting to disable Cursor automatic updates..."

    # Detect Cursor installation path (auto-detect + manual fallback)
    $cursorAppPath = Resolve-CursorInstallPath -AllowPrompt
    if (-not $cursorAppPath) {
        Write-Host "$YELLOW⚠️  [Warning]$NC Cursor install path not found, skipping update disablement"
        return $false
    }

    # Update configuration files (JSON/YAML)
    $updateFiles = @()
    $updateFiles += "$cursorAppPath\resources\app-update.yml"
    $updateFiles += "$cursorAppPath\resources\app\update-config.json"
    if ($global:CursorAppDataDir) {
        $updateFiles += (Join-Path $global:CursorAppDataDir "update-config.json")
        $updateFiles += (Join-Path $global:CursorAppDataDir "settings.json")
    }
    $updateFiles = $updateFiles | Where-Object { $_ }

    foreach ($file in $updateFiles) {
        if (-not (Test-Path $file)) { continue }

        try {
            Copy-Item $file "$file.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')" -Force
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Backup failed: $file"
        }

        if ($file -like "*.yml") {
            Set-Content -Path $file -Value "# update disabled by script $(Get-Date)" -Encoding UTF8
            Write-Host "$GREEN✅ [Complete]$NC Processed update configuration: $file"
            continue
        }

        if ($file -like "*update-config.json") {
            $config = @{ autoCheck = $false; autoDownload = $false }
            $config | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding UTF8
            Write-Host "$GREEN✅ [Complete]$NC Processed update configuration: $file"
            continue
        }

        if ($file -like "*settings.json") {
            try {
                $settings = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $settings = @{}
            }
            if ($settings -is [hashtable]) {
                $settings["update.mode"] = "none"
            } else {
                $settings | Add-Member -MemberType NoteProperty -Name "update.mode" -Value "none" -Force
            }
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
            Write-Host "$GREEN✅ [Complete]$NC Processed update configuration: $file"
            continue
        }
    }

    # Attempt to disable updater executables
    $updaterCandidates = @()
    $updaterCandidates += "$cursorAppPath\Update.exe"
    if ($global:CursorLocalAppDataDir) {
        $updaterCandidates += (Join-Path $global:CursorLocalAppDataDir "Update.exe")
    }
    $updaterCandidates += "$cursorAppPath\CursorUpdater.exe"
    $updaterCandidates = $updaterCandidates | Where-Object { $_ }

    foreach ($updater in $updaterCandidates) {
        if (-not (Test-Path $updater)) { continue }
        $backup = "$updater.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        try {
            Move-Item -Path $updater -Destination $backup -Force
            Write-Host "$GREEN✅ [Complete]$NC Disabled updater: $updater"
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Failed to disable updater: $updater"
        }
    }

    return $true
}

# Check configuration files and environment
function Test-CursorEnvironment {
    param(
        [string]$Mode = "FULL"
    )

    Write-Host ""
    Write-Host "$BLUE🔍 [Env Check]$NC Checking Cursor environment..."

    $configPath = $STORAGE_FILE
    $cursorAppData = $global:CursorAppDataDir
    $issues = @()

    # Check configuration file
    if (-not $configPath) {
        $issues += "Cannot resolve configuration file path"
    } elseif (-not (Test-Path $configPath)) {
        $issues += "Configuration file does not exist: $configPath"
    } else {
        try {
            $content = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
            $config = $content | ConvertFrom-Json -ErrorAction Stop
            Write-Host "$GREEN✅ [Check]$NC Configuration file format is valid"
        } catch {
            $issues += "Configuration file format error: $($_.Exception.Message)"
        }
    }

    # Check Cursor directory structure
    if (-not $cursorAppData -or -not (Test-Path $cursorAppData)) {
        $issues += "Cursor application data directory does not exist: $cursorAppData"
    }

    # Check Cursor installation
    $cursorPaths = @()
    $installPath = Resolve-CursorInstallPath
    if ($installPath) {
        $cursorPaths = @(Join-Path $installPath "Cursor.exe")
    }

    $cursorFound = $false
    foreach ($path in $cursorPaths) {
        if (Test-Path $path) {
            Write-Host "$GREEN✅ [Check]$NC Found Cursor installation: $path"
            $cursorFound = $true
            break
        }
    }

    if (-not $cursorFound) {
        $issues += "Cursor installation not found; please confirm Cursor is properly installed"
    }

    # Return check results
    if ($issues.Count -eq 0) {
        Write-Host "$GREEN✅ [Env Check]$NC All checks passed"
        return @{ Success = $true; Issues = @() }
    } else {
        Write-Host "$RED❌ [Env Check]$NC Found $($issues.Count) issue(s):"
        foreach ($issue in $issues) {
            Write-Host "$RED  • ${issue}$NC"
        }
        return @{ Success = $false; Issues = $issues }
    }
}

# 🛠️ Modify machine code configuration (Enhanced)
function Modify-MachineCodeConfig {
    param(
        [string]$Mode = "FULL"
    )

    Write-Host ""
    Write-Host "$GREEN🛠️  [Config]$NC Modifying machine code configuration..."

    $configPath = $STORAGE_FILE
    if (-not $configPath) {
        Write-Host "$RED❌ [Error]$NC Cannot resolve configuration file path"
        return $false
    }

    # Enhanced configuration file check
    if (-not (Test-Path $configPath)) {
        Write-Host "$RED❌ [Error]$NC Configuration file does not exist: $configPath"
        Write-Host ""
        Write-Host "$YELLOW💡 [Solution]$NC Please try the following steps:"
        Write-Host "$BLUE  1️⃣  Manually launch the Cursor application$NC"
        Write-Host "$BLUE  2️⃣  Wait for Cursor to fully load (~30 seconds)$NC"
        Write-Host "$BLUE  3️⃣  Close the Cursor application$NC"
        Write-Host "$BLUE  4️⃣  Re-run this script$NC"
        Write-Host ""
        Write-Host "$YELLOW⚠️  [Alternative]$NC If the issue persists:"
        Write-Host "$BLUE  • Choose the 'Reset Environment + Modify Machine IDs' option in this script$NC"
        Write-Host "$BLUE  • That option will automatically regenerate the configuration file$NC"
        Write-Host ""

        # Provide user prompt
        $userChoice = Read-Host "Attempt to launch Cursor now to generate config file? (y/n)"
        if ($userChoice -match "^(y|yes)$") {
            Write-Host "$BLUE🚀 [Attempt]$NC Attempting to launch Cursor..."
            return Start-CursorToGenerateConfig
        }

        return $false
    }

    # Ensure processes are stopped even in Modify-Only mode
    if ($Mode -eq "MODIFY_ONLY") {
        Write-Host "$BLUE🔒 [Security Check]$NC Ensuring Cursor processes are completely closed..."
        if (-not (Stop-AllCursorProcesses -MaxRetries 3 -WaitSeconds 3)) {
            Write-Host "$RED❌ [Error]$NC Unable to close all Cursor processes; modification may fail"
            $userChoice = Read-Host "Force continue? (y/n)"
            if ($userChoice -notmatch "^(y|yes)$") {
                return $false
            }
        }
    }

    # Check file permissions and lock status
    if (-not (Test-FileAccessibility -FilePath $configPath)) {
        Write-Host "$RED❌ [Error]$NC Cannot access configuration file; it may be locked or lack permissions"
        return $false
    }

    # Verify configuration file format and display structure
    try {
        Write-Host "$BLUE🔍 [Verification]$NC Checking configuration file format..."
        $originalContent = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
        $config = $originalContent | ConvertFrom-Json -ErrorAction Stop
        Write-Host "$GREEN✅ [Verification]$NC Configuration file format is valid"

        # Display current telemetry properties
        Write-Host "$BLUE📋 [Current Config]$NC Checking existing telemetry properties:"
        $telemetryProperties = @('telemetry.machineId', 'telemetry.macMachineId', 'telemetry.devDeviceId', 'telemetry.sqmId')
        foreach ($prop in $telemetryProperties) {
            if ($config.PSObject.Properties[$prop]) {
                $value = $config.$prop
                $displayValue = if ($value.Length -gt 20) { "$($value.Substring(0,20))..." } else { $value }
                Write-Host "$GREEN  ✓ ${prop}$NC = $displayValue"
            } else {
                Write-Host "$YELLOW  - ${prop}$NC (does not exist, will be created)"
            }
        }
        Write-Host ""
    } catch {
        Write-Host "$RED❌ [Error]$NC Configuration file format error: $($_.Exception.Message)"
        Write-Host "$YELLOW💡 [Tip]$NC Configuration file may be corrupted; recommend choosing 'Reset Environment + Modify Machine IDs'"
        return $false
    }

    # Implement atomic file operations and retry mechanism
    $maxRetries = 3
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        $retryCount++
        Write-Host ""
        Write-Host "$BLUE🔄 [Attempt]$NC Modification attempt $retryCount/$maxRetries..."

        try {
            # Display operation progress
            Write-Host "$BLUE⏳ [Progress]$NC 1/7 - Generating new device identifiers..."

            # Generate new IDs
            $MAC_MACHINE_ID = [System.Guid]::NewGuid().ToString()
            $UUID = [System.Guid]::NewGuid().ToString()
            $prefixBytes = [System.Text.Encoding]::UTF8.GetBytes("auth0|user_")
            $prefixHex = -join ($prefixBytes | ForEach-Object { '{0:x2}' -f $_ })
            $randomBytes = New-Object byte[] 32
            $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $rng.GetBytes($randomBytes)
            $randomPart = [System.BitConverter]::ToString($randomBytes) -replace '-',''
            $rng.Dispose()
            $MACHINE_ID = "${prefixHex}${randomPart}"
            $SQM_ID = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
            # serviceMachineId (for storage.serviceMachineId)
            $SERVICE_MACHINE_ID = [System.Guid]::NewGuid().ToString()
            # firstSessionDate (reset first session date, UTC timestamp)
            $FIRST_SESSION_DATE = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            $SESSION_ID = [System.Guid]::NewGuid().ToString()

            # Shared IDs (ensures config stays consistent with JS injection)
            $global:CursorIds = @{
                machineId        = $MACHINE_ID
                macMachineId     = $MAC_MACHINE_ID
                devDeviceId      = $UUID
                sqmId            = $SQM_ID
                firstSessionDate = $FIRST_SESSION_DATE
                sessionId        = $SESSION_ID
                macAddress       = "00:11:22:33:44:55"
            }

            Write-Host "$GREEN✅ [Progress]$NC 1/7 - Device identifiers generated"

            Write-Host "$BLUE⏳ [Progress]$NC 2/7 - Creating backup directory..."

            # Backup original values
            $backupDir = $BACKUP_DIR
            if (-not $backupDir) {
                throw "Failed to resolve backup directory path"
            }
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
            }

            $backupName = "storage.json.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')_retry$retryCount"
            $backupPath = "$backupDir\$backupName"

            Write-Host "$BLUE⏳ [Progress]$NC 3/7 - Backing up original configuration..."
            Copy-Item $configPath $backupPath -ErrorAction Stop

            # Verify backup success
            if (Test-Path $backupPath) {
                $backupSize = (Get-Item $backupPath).Length
                $originalSize = (Get-Item $configPath).Length
                if ($backupSize -eq $originalSize) {
                    Write-Host "$GREEN✅ [Progress]$NC 3/7 - Configuration backed up: $backupName"
                } else {
                    Write-Host "$YELLOW⚠️  [Warning]$NC Backup file size mismatch, continuing..."
                }
            } else {
                throw "Backup file creation failed"
            }

            Write-Host "$BLUE⏳ [Progress]$NC 4/7 - Reading original configuration into memory..."

            # Atomic operation: read original content into memory
            $originalContent = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
            $config = $originalContent | ConvertFrom-Json -ErrorAction Stop

            Write-Host "$BLUE⏳ [Progress]$NC 5/7 - Updating configuration in memory..."

            # Update configuration values safely
            $propertiesToUpdate = @{
                'telemetry.machineId' = $MACHINE_ID
                'telemetry.macMachineId' = $MAC_MACHINE_ID
                'telemetry.devDeviceId' = $UUID
                'telemetry.sqmId' = $SQM_ID
                'storage.serviceMachineId' = $SERVICE_MACHINE_ID
                'telemetry.firstSessionDate' = $FIRST_SESSION_DATE
            }

            foreach ($property in $propertiesToUpdate.GetEnumerator()) {
                $key = $property.Key
                $value = $property.Value

                # Safely assign or add member
                if ($config.PSObject.Properties[$key]) {
                    # Property exists, update directly
                    $config.$key = $value
                    Write-Host "$BLUE  ✓ Updated property: ${key}$NC"
                } else {
                    # Property missing, add new property
                    $config | Add-Member -MemberType NoteProperty -Name $key -Value $value -Force
                    Write-Host "$BLUE  + Added property: ${key}$NC"
                }
            }

            Write-Host "$BLUE⏳ [Progress]$NC 6/7 - Writing new configuration file atomically..."

            # Atomic operation: write to temporary file, then move
            $tempPath = "$configPath.tmp"
            $updatedJson = $config | ConvertTo-Json -Depth 10

            # Write to temp file
            [System.IO.File]::WriteAllText($tempPath, $updatedJson, [System.Text.Encoding]::UTF8)

            # Verify temp file
            $tempContent = Get-Content $tempPath -Raw -Encoding UTF8 -ErrorAction Stop
            $tempConfig = $tempContent | ConvertFrom-Json -ErrorAction Stop

            # Normalize values for date comparisons across string vs DateTime
            $toComparableString = {
                param([object]$v)
                if ($null -eq $v) { return $null }
                if ($v -is [DateTime]) { return $v.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
                if ($v -is [DateTimeOffset]) { return $v.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
                return [string]$v
            }

            # Verify all properties written correctly
            $tempVerificationPassed = $true
            foreach ($property in $propertiesToUpdate.GetEnumerator()) {
                $key = $property.Key
                $expectedValue = $property.Value
                $actualValue = $tempConfig.$key

                $expectedComparable = & $toComparableString $expectedValue
                $actualComparable = & $toComparableString $actualValue

                if ($actualComparable -ne $expectedComparable) {
                    $tempVerificationPassed = $false
                    Write-Host "$RED  ✗ Temp file verification failed for: ${key}$NC"
                    $expectedType = if ($null -eq $expectedValue) { '<null>' } else { $expectedValue.GetType().FullName }
                    $actualType = if ($null -eq $actualValue) { '<null>' } else { $actualValue.GetType().FullName }
                    Write-Host "$YELLOW    [Debug] Type: Expected=${expectedType}; Actual=${actualType}$NC"
                    Write-Host "$YELLOW    [Debug] Normalized value: Expected=${expectedComparable}; Actual=${actualComparable}$NC"
                    break
                }
            }

            if (-not $tempVerificationPassed) {
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                throw "Temporary file verification failed"
            }

            # Atomic replace
            Remove-Item $configPath -Force
            Move-Item $tempPath $configPath

            # Keep writable for future changes
            $file = Get-Item $configPath
            $file.IsReadOnly = $false

            # Final verification
            Write-Host "$BLUE⏳ [Progress]$NC 7/7 - Verifying new configuration file..."

            $verifyContent = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
            $verifyConfig = $verifyContent | ConvertFrom-Json -ErrorAction Stop

            $verificationPassed = $true
            $verificationResults = @()

            foreach ($property in $propertiesToUpdate.GetEnumerator()) {
                $key = $property.Key
                $expectedValue = $property.Value
                $actualValue = $verifyConfig.$key

                $expectedComparable = & $toComparableString $expectedValue
                $actualComparable = & $toComparableString $actualValue

                if ($actualComparable -eq $expectedComparable) {
                    $verificationResults += "✓ ${key}: Verified"
                } else {
                    $expectedType = if ($null -eq $expectedValue) { '<null>' } else { $expectedValue.GetType().FullName }
                    $actualType = if ($null -eq $actualValue) { '<null>' } else { $actualValue.GetType().FullName }
                    $verificationResults += "✗ ${key}: Verification failed (Expected: ${expectedComparable}, Actual: ${actualComparable})"
                    $verificationPassed = $false
                }
            }

            # Display verification results
            Write-Host "$BLUE📋 [Verification Details]$NC"
            foreach ($result in $verificationResults) {
                Write-Host "   $result"
            }

            if ($verificationPassed) {
                Write-Host "$GREEN✅ [Success]$NC Modification succeeded on attempt $retryCount!"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC Machine code configuration update complete!"
                Write-Host "$BLUE📋 [Details]$NC Updated identifiers:"
                Write-Host "   🔹 machineId: $MACHINE_ID"
                Write-Host "   🔹 macMachineId: $MAC_MACHINE_ID"
                Write-Host "   🔹 devDeviceId: $UUID"
                Write-Host "   🔹 sqmId: $SQM_ID"
                Write-Host "   🔹 serviceMachineId: $SERVICE_MACHINE_ID"
                Write-Host "   🔹 firstSessionDate: $FIRST_SESSION_DATE"
                Write-Host ""
                Write-Host "$GREEN💾 [Backup]$NC Original configuration backed up to: $backupName"

                # Update machineid file
                Write-Host "$BLUE🔧 [machineid]$NC Updating machineid file..."
                $machineIdFilePath = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir "machineid" } else { $null }
                if (-not $machineIdFilePath) {
                    Write-Host "$YELLOW⚠️  [machineid]$NC Cannot resolve machineid file path, skipping update"
                } else {
                    try {
                        if (Test-Path $machineIdFilePath) {
                            $machineIdBackup = "$backupDir\machineid.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                            Copy-Item $machineIdFilePath $machineIdBackup -Force
                            Write-Host "$GREEN💾 [Backup]$NC machineid file backed up: $machineIdBackup"
                        }
                        [System.IO.File]::WriteAllText($machineIdFilePath, $SERVICE_MACHINE_ID, [System.Text.Encoding]::UTF8)
                        Write-Host "$GREEN✅ [machineid]$NC machineid file updated: $SERVICE_MACHINE_ID"

                        $machineIdFile = Get-Item $machineIdFilePath
                        $machineIdFile.IsReadOnly = $true
                        Write-Host "$GREEN🔒 [Protection]$NC machineid file set to read-only"
                    } catch {
                        Write-Host "$YELLOW⚠️  [machineid]$NC Failed to update machineid file: $($_.Exception.Message)"
                        Write-Host "$BLUE💡 [Tip]$NC You can manually edit file: $machineIdFilePath"
                    }
                }

                # Update .updaterId file
                Write-Host "$BLUE🔧 [updaterId]$NC Updating .updaterId file..."
                $updaterIdFilePath = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir ".updaterId" } else { $null }
                if (-not $updaterIdFilePath) {
                    Write-Host "$YELLOW⚠️  [updaterId]$NC Cannot resolve .updaterId file path, skipping update"
                } else {
                    try {
                        if (Test-Path $updaterIdFilePath) {
                            $updaterIdBackup = "$backupDir\.updaterId.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                            Copy-Item $updaterIdFilePath $updaterIdBackup -Force
                            Write-Host "$GREEN💾 [Backup]$NC .updaterId file backed up: $updaterIdBackup"
                        }
                        $newUpdaterId = [System.Guid]::NewGuid().ToString()
                        [System.IO.File]::WriteAllText($updaterIdFilePath, $newUpdaterId, [System.Text.Encoding]::UTF8)
                        Write-Host "$GREEN✅ [updaterId]$NC .updaterId file updated: $newUpdaterId"

                        $updaterIdFile = Get-Item $updaterIdFilePath
                        $updaterIdFile.IsReadOnly = $true
                        Write-Host "$GREEN🔒 [Protection]$NC .updaterId file set to read-only"
                    } catch {
                        Write-Host "$YELLOW⚠️  [updaterId]$NC Failed to update .updaterId file: $($_.Exception.Message)"
                        Write-Host "$BLUE💡 [Tip]$NC You can manually edit file: $updaterIdFilePath"
                    }
                }

                # Add configuration file protection
                Write-Host "$BLUE🔒 [Protection]$NC Setting configuration file protection..."
                try {
                    $configFile = Get-Item $configPath
                    $configFile.IsReadOnly = $true
                    Write-Host "$GREEN✅ [Protection]$NC Configuration file set to read-only to prevent Cursor overwrite"
                    Write-Host "$BLUE💡 [Tip]$NC File path: $configPath"
                } catch {
                    Write-Host "$YELLOW⚠️  [Protection]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                    Write-Host "$BLUE💡 [Tip]$NC You can manually right-click file -> Properties -> check 'Read-only'"
                }
                Write-Host "$BLUE🔒 [Security]$NC Please restart Cursor to ensure new configuration takes effect"
                return $true
            } else {
                Write-Host "$RED❌ [Failed]$NC Verification failed on attempt $retryCount"
                if ($retryCount -lt $maxRetries) {
                    Write-Host "$BLUE🔄 [Restore]$NC Restoring backup, preparing retry..."
                    Copy-Item $backupPath $configPath -Force
                    Start-Sleep -Seconds 2
                    continue
                } else {
                    Write-Host "$RED❌ [Final Failure]$NC All retries failed, restoring original configuration"
                    Copy-Item $backupPath $configPath -Force
                    return $false
                }
            }

        } catch {
            Write-Host "$RED❌ [Exception]$NC Exception on attempt $retryCount: $($_.Exception.Message)"
            Write-Host "$BLUE💡 [Debug Info]$NC Error type: $($_.Exception.GetType().FullName)"

            # Clean temporary file
            if (Test-Path "$configPath.tmp") {
                Remove-Item "$configPath.tmp" -Force -ErrorAction SilentlyContinue
            }

            if ($retryCount -lt $maxRetries) {
                Write-Host "$BLUE🔄 [Restore]$NC Restoring backup, preparing retry..."
                if (Test-Path $backupPath) {
                    Copy-Item $backupPath $configPath -Force
                }
                Start-Sleep -Seconds 3
                continue
            } else {
                Write-Host "$RED❌ [Final Failure]$NC All retry attempts failed"
                if (Test-Path $backupPath) {
                    Write-Host "$BLUE🔄 [Restore]$NC Restoring backup configuration..."
                    try {
                        Copy-Item $backupPath $configPath -Force
                        Write-Host "$GREEN✅ [Restore]$NC Restored original configuration"
                    } catch {
                        Write-Host "$RED❌ [Error]$NC Failed to restore backup: $($_.Exception.Message)"
                    }
                }
                return $false
            }
        }
    }

    Write-Host "$RED❌ [Final Failure]$NC Unable to complete modifications after $maxRetries attempts"
    return $false
}

# Launch Cursor to generate configuration files
function Start-CursorToGenerateConfig {
    Write-Host "$BLUE🚀 [Launch]$NC Attempting to launch Cursor to generate configuration..."

    # Locate Cursor executable (auto-detect + manual fallback)
    $installPath = Resolve-CursorInstallPath -AllowPrompt
    $cursorPath = if ($installPath) { Join-Path $installPath "Cursor.exe" } else { $null }

    if (-not $cursorPath) {
        Write-Host "$RED❌ [Error]$NC Cursor installation not found. Please ensure Cursor is properly installed"
        return $false
    }

    try {
        Write-Host "$BLUE📍 [Path]$NC Using Cursor path: $cursorPath"

        # Start Cursor
        $process = Start-Process -FilePath $cursorPath -PassThru -WindowStyle Normal
        Write-Host "$GREEN🚀 [Launch]$NC Cursor started with PID: $($process.Id)"

        Write-Host "$YELLOW⏳ [Wait]$NC Please wait for Cursor to fully load (~30 seconds)..."
        Write-Host "$BLUE💡 [Tip]$NC You may manually close Cursor after it loads"

        # Wait for configuration file generation
        $configPath = $STORAGE_FILE
        if (-not $configPath) {
            Write-Host "$RED❌ [Error]$NC Cannot resolve configuration file path"
            return $false
        }
        $maxWait = 60
        $waited = 0

        while (-not (Test-Path $configPath) -and $waited -lt $maxWait) {
            Start-Sleep -Seconds 2
            $waited += 2
            if ($waited % 10 -eq 0) {
                Write-Host "$YELLOW⏳ [Wait]$NC Waiting for configuration file to generate... ($waited/$maxWait s)"
            }
        }

        if (Test-Path $configPath) {
            Write-Host "$GREEN✅ [Success]$NC Configuration file generated successfully!"
            Write-Host "$BLUE💡 [Tip]$NC You can now close Cursor and re-run the script"
            return $true
        } else {
            Write-Host "$YELLOW⚠️  [Timeout]$NC Configuration file was not generated within the expected time"
            Write-Host "$BLUE💡 [Tip]$NC Please interact with Cursor (e.g., create a new file) to trigger configuration generation"
            return $false
        }

    } catch {
        Write-Host "$RED❌ [Error]$NC Failed to launch Cursor: $($_.Exception.Message)"
        return $false
    }
}

# Check administrator privileges
function Test-Administrator {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($user)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "$RED[Error]$NC Please run this script as Administrator"
    Write-Host "Right-click the script and select 'Run with PowerShell as Administrator'"
    Read-Host "Press Enter to exit"
    exit 1
}

# Display Logo & Banner
Clear-Host
Write-Host @"

    ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
   ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
   ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
   ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
   ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝

"@
Write-Host "$BLUE========================================$NC"
Write-Host "$GREEN🚀   Cursor Machine ID Modifier & Reset Tool  $NC"
Write-Host "$BLUE========================================$NC"
Write-Host ""

# 🎯 User Selection Menu
Write-Host ""
Write-Host "$GREEN🎯 [Select Mode]$NC Please select an operation:"
Write-Host ""
Write-Host "$BLUE  1️⃣  Modify Machine IDs Only$NC"
Write-Host "$YELLOW      • Modifies machine telemetry identifiers$NC"
Write-Host "$YELLOW      • Injects device ID bypass hook into core JS files$NC"
Write-Host "$YELLOW      • Skips folder deletion / environment reset$NC"
Write-Host "$YELLOW      • Preserves existing Cursor settings and data$NC"
Write-Host ""
Write-Host "$BLUE  2️⃣  Reset Environment + Modify Machine IDs$NC"
Write-Host "$RED      • Performs complete environment reset (deletes Cursor trial folders)$NC"
Write-Host "$RED      • ⚠️  Settings will be reset, please ensure backups$NC"
Write-Host "$YELLOW      • Modifies machine telemetry identifiers$NC"
Write-Host "$YELLOW      • Injects device ID bypass hook into core JS files$NC"
Write-Host "$YELLOW      • Recommended for a full clean reset$NC"
Write-Host ""

# Get user selection
do {
    $userChoice = Read-Host "Please enter your choice (1 or 2)"
    if ($userChoice -eq "1") {
        Write-Host "$GREEN✅ [Selected]$NC You selected: Modify Machine IDs Only"
        $executeMode = "MODIFY_ONLY"
        break
    } elseif ($userChoice -eq "2") {
        Write-Host "$GREEN✅ [Selected]$NC You selected: Reset Environment + Modify Machine IDs"
        Write-Host "$RED⚠️  [Important Warning]$NC This operation will delete Cursor trial/configuration folders!"
        $confirmReset = Read-Host "Confirm full reset? (Type 'yes' to confirm, any other key to cancel)"
        if ($confirmReset -eq "yes") {
            $executeMode = "RESET_AND_MODIFY"
            break
        } else {
            Write-Host "$YELLOW👋 [Cancelled]$NC Full reset cancelled by user"
            continue
        }
    } else {
        Write-Host "$RED❌ [Error]$NC Invalid choice, please enter 1 or 2"
    }
} while ($true)

Write-Host ""

# 📋 Display execution workflow based on selection
if ($executeMode -eq "MODIFY_ONLY") {
    Write-Host "$GREEN📋 [Execution Flow]$NC Modify Machine IDs Only mode will execute the following steps:"
    Write-Host "$BLUE  1️⃣  Detect Cursor configuration file$NC"
    Write-Host "$BLUE  2️⃣  Backup existing configuration file$NC"
    Write-Host "$BLUE  3️⃣  Update machine code configuration$NC"
    Write-Host "$BLUE  4️⃣  Display operation completion summary$NC"
    Write-Host ""
    Write-Host "$YELLOW⚠️  [Important Notes]$NC"
    Write-Host "$YELLOW  • Will not delete folders or reset environment$NC"
    Write-Host "$YELLOW  • Preserves all existing configurations and data$NC"
    Write-Host "$YELLOW  • Original configuration file is automatically backed up$NC"
} else {
    Write-Host "$GREEN📋 [Execution Flow]$NC Reset Environment + Modify Machine IDs mode will execute the following steps:"
    Write-Host "$BLUE  1️⃣  Detect and terminate Cursor processes$NC"
    Write-Host "$BLUE  2️⃣  Save Cursor application path information$NC"
    Write-Host "$BLUE  3️⃣  Delete specified Cursor trial-related folders$NC"
    Write-Host "$BLUE      📁 C:\Users\Administrator\.cursor$NC"
    Write-Host "$BLUE      📁 C:\Users\Administrator\AppData\Roaming\Cursor$NC"
    Write-Host "$BLUE      📁 C:\Users\%USERNAME%\.cursor$NC"
    Write-Host "$BLUE      📁 C:\Users\%USERNAME%\AppData\Roaming\Cursor$NC"
    Write-Host "$BLUE  3.5️⃣ Pre-create required directory structure to avoid permission issues$NC"
    Write-Host "$BLUE  4️⃣  Restart Cursor to generate fresh configuration files$NC"
    Write-Host "$BLUE  5️⃣  Wait for configuration file generation (up to 45s)$NC"
    Write-Host "$BLUE  6️⃣  Stop Cursor processes$NC"
    Write-Host "$BLUE  7️⃣  Modify newly generated machine code configuration$NC"
    Write-Host "$BLUE  8️⃣  Display operation completion statistics$NC"
    Write-Host ""
    Write-Host "$YELLOW⚠️  [Important Notes]$NC"
    Write-Host "$YELLOW  • Do not manually interact with Cursor during script execution$NC"
    Write-Host "$YELLOW  • Recommend closing all Cursor windows before starting$NC"
    Write-Host "$YELLOW  • Restart Cursor after execution completes$NC"
    Write-Host "$YELLOW  • Original configuration is automatically backed up to the backups folder$NC"
}
Write-Host ""

# 🤔 User Confirmation
Write-Host "$GREEN🤔 [Confirmation]$NC Please confirm that you have reviewed the execution flow above"
$confirmation = Read-Host "Continue execution? (Type 'y' or 'yes' to continue, any other key to exit)"
if ($confirmation -notmatch "^(y|yes)$") {
    Write-Host "$YELLOW👋 [Exit]$NC Execution cancelled by user. Exiting script..."
    Read-Host "Press Enter to exit"
    exit 0
}
Write-Host "$GREEN✅ [Confirmed]$NC User confirmed to proceed"
Write-Host ""

# Retrieve and display Cursor version
function Get-CursorVersion {
    try {
        # Primary detection path (based on resolved install path)
        $installPath = Resolve-CursorInstallPath
        $packagePath = if ($installPath) { Join-Path $installPath "resources\app\package.json" } else { $null }
        if ($packagePath -and (Test-Path $packagePath)) {
            $packageJson = Get-Content $packagePath -Raw | ConvertFrom-Json
            if ($packageJson.version) {
                Write-Host "$GREEN[Info]$NC Currently installed Cursor version: v$($packageJson.version)"
                return $packageJson.version
            }
        }

        # Fallback path detection (compatibility with older directory structures)
        $altPath = if ($global:CursorLocalAppDataRoot) { Join-Path $global:CursorLocalAppDataRoot "cursor\resources\app\package.json" } else { $null }
        if ($altPath -and (Test-Path $altPath)) {
            $packageJson = Get-Content $altPath -Raw | ConvertFrom-Json
            if ($packageJson.version) {
                Write-Host "$GREEN[Info]$NC Currently installed Cursor version: v$($packageJson.version)"
                return $packageJson.version
            }
        }

        Write-Host "$YELLOW[Warning]$NC Unable to detect Cursor version"
        Write-Host "$YELLOW[Tip]$NC Please ensure Cursor is properly installed"
        return $null
    }
    catch {
        Write-Host "$RED[Error]$NC Failed to retrieve Cursor version: $_"
        return $null
    }
}

# Display version information
$cursorVersion = Get-CursorVersion
Write-Host ""

Write-Host "$YELLOW💡 [Tip]$NC Latest 1.0.x versions supported"

Write-Host ""

# 🔍 Check and stop Cursor processes
Write-Host "$GREEN🔍 [Check]$NC Checking Cursor processes..."

function Get-ProcessDetails {
    param($processName)
    Write-Host "$BLUE🔍 [Debug]$NC Retrieving detailed info for $processName process:"
    Get-WmiObject Win32_Process -Filter "name='$processName'" |
        Select-Object ProcessId, ExecutablePath, CommandLine |
        Format-List
}

# Define max retries and wait time
$MAX_RETRIES = 5
$WAIT_TIME = 1

# 🔄 Handle process termination and save process info
function Close-CursorProcessAndSaveInfo {
    param($processName)

    $global:CursorProcessInfo = $null

    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if ($processes) {
        Write-Host "$YELLOW⚠️  [Warning]$NC Found running process: $processName"

        # Save process info for later restart
        $firstProcess = if ($processes -is [array]) { $processes[0] } else { $processes }
        $processPath = $firstProcess.Path

        # Ensure path is a string, not an array
        if ($processPath -is [array]) {
            $processPath = $processPath[0]
        }

        $global:CursorProcessInfo = @{
            ProcessName = $firstProcess.ProcessName
            Path = $processPath
            StartTime = $firstProcess.StartTime
        }
        Write-Host "$GREEN💾 [Save]$NC Saved process info: $($global:CursorProcessInfo.Path)"

        Get-ProcessDetails $processName

        Write-Host "$YELLOW🔄 [Action]$NC Attempting to stop $processName..."
        Stop-Process -Name $processName -Force

        $retryCount = 0
        while ($retryCount -lt $MAX_RETRIES) {
            $process = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if (-not $process) { break }

            $retryCount++
            if ($retryCount -ge $MAX_RETRIES) {
                Write-Host "$RED❌ [Error]$NC Unable to stop $processName after $MAX_RETRIES attempts"
                Get-ProcessDetails $processName
                Write-Host "$RED💥 [Error]$NC Please close the process manually and retry"
                Read-Host "Press Enter to exit"
                exit 1
            }
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting for process to exit, attempt $retryCount/$MAX_RETRIES..."
            Start-Sleep -Seconds $WAIT_TIME
        }
        Write-Host "$GREEN✅ [Success]$NC $processName stopped successfully"
    } else {
        Write-Host "$BLUE💡 [Tip]$NC No running $processName process found"
        # Try to locate Cursor install path
        $installPath = Resolve-CursorInstallPath
        $candidatePath = if ($installPath) { Join-Path $installPath "Cursor.exe" } else { $null }
        if ($candidatePath -and (Test-Path $candidatePath)) {
            $global:CursorProcessInfo = @{
                ProcessName = "Cursor"
                Path = $candidatePath
                StartTime = $null
            }
            Write-Host "$GREEN💾 [Found]$NC Found Cursor install path: $candidatePath"
        }

        if (-not $global:CursorProcessInfo) {
            Write-Host "$YELLOW⚠️  [Warning]$NC Cursor install path not found, using default path"
            $defaultInstallPath = if ($global:CursorLocalAppDataRoot) { Join-Path $global:CursorLocalAppDataRoot "Programs\cursor\Cursor.exe" } else { "$env:LOCALAPPDATA\Programs\cursor\Cursor.exe" }
            $global:CursorProcessInfo = @{
                ProcessName = "Cursor"
                Path = $defaultInstallPath
                StartTime = $null
            }
        }
    }
}

# Ensure backup directory exists
if (-not $BACKUP_DIR) {
    Write-Host "$YELLOW⚠️  [Warning]$NC Cannot resolve backup directory path, skipping creation"
} elseif (-not (Test-Path $BACKUP_DIR)) {
    try {
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
        Write-Host "$GREEN✅ [Backup Directory]$NC Backup directory created: $BACKUP_DIR"
    } catch {
        Write-Host "$YELLOW⚠️  [Warning]$NC Backup directory creation failed: $($_.Exception.Message)"
    }
}

# 🚀 Execute selected mode
if ($executeMode -eq "MODIFY_ONLY") {
    Write-Host "$GREEN🚀 [Start]$NC Starting Modify Machine IDs Only execution..."

    # Environment check first
    $envCheck = Test-CursorEnvironment -Mode "MODIFY_ONLY"
    if (-not $envCheck.Success) {
        Write-Host ""
        Write-Host "$RED❌ [Env Check Failed]$NC Cannot continue execution; the following issues were found:"
        foreach ($issue in $envCheck.Issues) {
            Write-Host "$RED  • ${issue}$NC"
        }
        Write-Host ""
        Write-Host "$YELLOW💡 [Recommendations]$NC Please try one of the following:"
        Write-Host "$BLUE  1️⃣  Select 'Reset Environment + Modify Machine IDs' (Recommended)$NC"
        Write-Host "$BLUE  2️⃣  Launch Cursor manually once, then re-run this script$NC"
        Write-Host "$BLUE  3️⃣  Verify that Cursor is properly installed$NC"
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }

    # Execute machine code modification
    $configSuccess = Modify-MachineCodeConfig -Mode "MODIFY_ONLY"

    if ($configSuccess) {
        Write-Host ""
        Write-Host "$GREEN🎉 [Config File]$NC Machine code configuration modified successfully!"

        # Registry modification
        Write-Host "$BLUE🔧 [Registry]$NC Modifying system registry..."
        $registrySuccess = Update-MachineGuid

        # JavaScript injection (Enhanced device ID bypass)
        Write-Host ""
        Write-Host "$BLUE🔧 [Device ID Bypass]$NC Executing JavaScript kernel injection..."
        Write-Host "$BLUE💡 [Description]$NC Modifying Cursor core JS files for deep device identifier bypass"
        $jsSuccess = Modify-CursorJSFiles

        if ($registrySuccess) {
            Write-Host "$GREEN✅ [Registry]$NC System registry modified successfully"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection executed successfully"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All machine code modifications completed (Enhanced)! "
                Write-Host "$BLUE📋 [Details]$NC Completed modifications:"
                Write-Host "$GREEN  ✓ Cursor configuration file (storage.json)$NC"
                Write-Host "$GREEN  ✓ System registry (MachineGuid)$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel patch (Device ID Bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection failed, but other modifications succeeded"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC Machine code modifications completed!"
                Write-Host "$BLUE📋 [Details]$NC Completed modifications:"
                Write-Host "$GREEN  ✓ Cursor configuration file (storage.json)$NC"
                Write-Host "$GREEN  ✓ System registry (MachineGuid)$NC"
                Write-Host "$YELLOW  ⚠ JavaScript kernel patch (Partial failure)$NC"
            }

            # Add configuration file protection
            Write-Host "$BLUE🔒 [Protection]$NC Setting configuration file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Cannot resolve configuration file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protection]$NC Configuration file set to read-only to prevent Cursor overwrite"
                Write-Host "$BLUE💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protection]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "$BLUE💡 [Tip]$NC You can manually right-click file -> Properties -> check 'Read-only'"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Registry]$NC Registry modification failed, but configuration file update succeeded"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection executed successfully"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Config file and JS injection succeeded; registry modification failed"
                Write-Host "$BLUE💡 [Tip]$NC Administrator privileges may be required to modify the registry"
                Write-Host "$BLUE📋 [Details]$NC Completed modifications:"
                Write-Host "$GREEN  ✓ Cursor configuration file (storage.json)$NC"
                Write-Host "$YELLOW  ⚠ System registry (MachineGuid) - Failed$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel patch (Device ID Bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection failed"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Config file update succeeded; registry and JS injection failed"
                Write-Host "$BLUE💡 [Tip]$NC Administrator privileges may be required to modify the registry"
            }

            # Protect configuration file even if registry fails
            Write-Host "$BLUE🔒 [Protection]$NC Setting configuration file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Cannot resolve configuration file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protection]$NC Configuration file set to read-only to prevent Cursor overwrite"
                Write-Host "$BLUE💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protection]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "$BLUE💡 [Tip]$NC You can manually right-click file -> Properties -> check 'Read-only'"
            }
        }

        Write-Host ""
        Write-Host "$BLUE🚫 [Disable Updates]$NC Disabling Cursor automatic updates..."
        if (Disable-CursorAutoUpdate) {
            Write-Host "$GREEN✅ [Disable Updates]$NC Automatic updates processed"
        } else {
            Write-Host "$YELLOW⚠️  [Disable Updates]$NC Could not confirm update disablement; manual review may be required"
        }

        Write-Host "$BLUE💡 [Tip]$NC You may now start Cursor with the new machine identifiers"
    } else {
        Write-Host ""
        Write-Host "$RED❌ [Failed]$NC Machine code configuration modification failed!"
        Write-Host "$YELLOW💡 [Tip]$NC Please try the 'Reset Environment + Modify Machine IDs' option"
    }
} else {
    # Full Reset Environment + Modify Machine IDs workflow
    Write-Host "$GREEN🚀 [Start]$NC Starting Reset Environment + Modify Machine IDs execution..."

    # Close all Cursor processes and save info
    Close-CursorProcessAndSaveInfo "Cursor"
    if (-not $global:CursorProcessInfo) {
        Close-CursorProcessAndSaveInfo "cursor"
    }

    # Important warning notice
    Write-Host ""
    Write-Host "$RED🚨 [Important Warning]$NC ============================================"
    Write-Host "$YELLOW⚠️  [Risk Notice]$NC Cursor security verification is strict."
    Write-Host "$YELLOW⚠️  [Required Deletion]$NC Target trial directories must be fully cleared to avoid residual telemetry."
    Write-Host "$YELLOW⚠️  [Trial Protection]$NC Thorough cleanup ensures fresh trial environment initialization."
    Write-Host "$RED🚨 [Important Warning]$NC ============================================"
    Write-Host ""

    # Execute trial folder cleanup
    Write-Host "$GREEN🚀 [Start]$NC Executing core folder cleanup..."
    Remove-CursorTrialFolders

    # Restart Cursor to regenerate fresh configuration files
    Restart-CursorAndWait

    # Modify machine code configuration
    $configSuccess = Modify-MachineCodeConfig
    
    # Execute Cursor initialization cleanup
    Invoke-CursorInitialization

    if ($configSuccess) {
        Write-Host ""
        Write-Host "$GREEN🎉 [Config File]$NC Machine code configuration modified successfully!"

        # Registry modification
        Write-Host "$BLUE🔧 [Registry]$NC Modifying system registry..."
        $registrySuccess = Update-MachineGuid

        # JavaScript injection (Enhanced device ID bypass)
        Write-Host ""
        Write-Host "$BLUE🔧 [Device ID Bypass]$NC Executing JavaScript kernel injection..."
        Write-Host "$BLUE💡 [Description]$NC Modifying Cursor core JS files for deep device identifier bypass"
        $jsSuccess = Modify-CursorJSFiles

        if ($registrySuccess) {
            Write-Host "$GREEN✅ [Registry]$NC System registry modified successfully"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection executed successfully"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All operations completed successfully (Enhanced)!"
                Write-Host "$BLUE📋 [Details]$NC Completed operations:"
                Write-Host "$GREEN  ✓ Removed Cursor trial directories$NC"
                Write-Host "$GREEN  ✓ Cursor initialization cleanup$NC"
                Write-Host "$GREEN  ✓ Regenerated configuration files$NC"
                Write-Host "$GREEN  ✓ Modified machine code configuration$NC"
                Write-Host "$GREEN  ✓ Updated system registry$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel patch (Device ID Bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection failed, but other operations succeeded"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All operations completed!"
                Write-Host "$BLUE📋 [Details]$NC Completed operations:"
                Write-Host "$GREEN  ✓ Removed Cursor trial directories$NC"
                Write-Host "$GREEN  ✓ Cursor initialization cleanup$NC"
                Write-Host "$GREEN  ✓ Regenerated configuration files$NC"
                Write-Host "$GREEN  ✓ Modified machine code configuration$NC"
                Write-Host "$GREEN  ✓ Updated system registry$NC"
                Write-Host "$YELLOW  ⚠ JavaScript kernel patch (Partial failure)$NC"
            }

            # Add configuration file protection
            Write-Host "$BLUE🔒 [Protection]$NC Setting configuration file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Cannot resolve configuration file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protection]$NC Configuration file set to read-only to prevent Cursor overwrite"
                Write-Host "$BLUE💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protection]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "$BLUE💡 [Tip]$NC You can manually right-click file -> Properties -> check 'Read-only'"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Registry]$NC Registry modification failed, but other operations succeeded"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection executed successfully"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Most operations completed; registry modification failed"
                Write-Host "$BLUE💡 [Tip]$NC Administrator privileges may be required to modify the registry"
                Write-Host "$BLUE📋 [Details]$NC Completed operations:"
                Write-Host "$GREEN  ✓ Removed Cursor trial directories$NC"
                Write-Host "$GREEN  ✓ Cursor initialization cleanup$NC"
                Write-Host "$GREEN  ✓ Regenerated configuration files$NC"
                Write-Host "$GREEN  ✓ Modified machine code configuration$NC"
                Write-Host "$YELLOW  ⚠ System registry update - Failed$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel patch (Device ID Bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection failed"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Most operations completed; registry and JS injection failed"
                Write-Host "$BLUE💡 [Tip]$NC Administrator privileges may be required to modify the registry"
            }

            # Protect configuration file even if registry fails
            Write-Host "$BLUE🔒 [Protection]$NC Setting configuration file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Cannot resolve configuration file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protection]$NC Configuration file set to read-only to prevent Cursor overwrite"
                Write-Host "$BLUE💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protection]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "$BLUE💡 [Tip]$NC You can manually right-click file -> Properties -> check 'Read-only'"
            }
        }

        Write-Host ""
        Write-Host "$BLUE🚫 [Disable Updates]$NC Disabling Cursor automatic updates..."
        if (Disable-CursorAutoUpdate) {
            Write-Host "$GREEN✅ [Disable Updates]$NC Automatic updates processed"
        } else {
            Write-Host "$YELLOW⚠️  [Disable Updates]$NC Could not confirm update disablement; manual review may be required"
        }
    } else {
        Write-Host ""
        Write-Host "$RED❌ [Failed]$NC Machine code configuration update failed!"
        Write-Host "$YELLOW💡 [Tip]$NC Please check error messages and retry"
    }
}

# 🎉 Script Execution Completed
Write-Host ""
Write-Host "$GREEN🎉 [Complete]$NC Cursor Machine ID Modifier execution finished!"
Write-Host "$BLUE💡 [Tip]$NC If you encounter any issues, please re-run the script as Administrator"
Write-Host ""
Read-Host "Press Enter to exit"
