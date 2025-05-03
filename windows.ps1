#Requires -Version 5.1

<#
.SYNOPSIS
Checks for and optionally installs required development tools (Python, Node.js, uv) for the MCP environment on Windows.
Prioritizes winget, falls back to official installers/scripts, then pip for uv.

.DESCRIPTION
This script verifies that compatible versions of Python (>= 3.10) and Node.js (>= 16.0) are installed and accessible.
It also checks for and installs the 'uv' Python package manager/resolver.
If dependencies are missing or incompatible, it attempts installation using this priority:
1. winget (if available)
2. Official Installer/Script (Node.js MSI, uv powershell script)
3. pip (for uv as last resort)

It checks if winget is installed and provides guidance if it's missing.
It checks if necessary installation directories are in the user's PATH and attempts to add them persistently and to the current session.

.PARAMETER TargetPythonVersion
The minimum required Python version (default: "3.10").

.PARAMETER TargetNodeVersion
The minimum required Node.js version (default: "16.0").

.EXAMPLE
.\windows.ps1

.EXAMPLE
.\windows.ps1 -TargetPythonVersion "3.11" -TargetNodeVersion "18.0"

.NOTES
- Run this script from an administrative PowerShell terminal for potentially smoother installations (especially MSI/winget).
- You might need to adjust PowerShell's execution policy. Run once:
  Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
- Or bypass it for a single run:
  powershell.exe -ExecutionPolicy Bypass -File .\windows.ps1
- PATH environment variable changes might require restarting the PowerShell session or logging out/in to take full effect outside this script run.
#>
param(
    [ValidatePattern("^\d+\.\d+(\.\d+)?$")]
    [string]$TargetPythonVersion = "3.10",

    [ValidatePattern("^\d+\.\d+(\.\d+)?$")]
    [string]$TargetNodeVersion = "16.0"
)

# --- Script Setup ---
# Stop on errors initially, but allow continuation within specific try/catch blocks
$ErrorActionPreference = 'Stop'
# Use TLS 1.2 for web requests (good practice)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#####################################################
### Helper Functions                              ###
#####################################################

# Function to check if a command exists in PATH
function Test-CommandExists {
    param($CommandName)
    # Force command discovery refresh before checking
    Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
    Get-Command -Name $CommandName -ErrorAction SilentlyContinue | Out-Null # Populate cache
    return (Get-Command $CommandName -ErrorAction SilentlyContinue) -ne $null
}

# Function to get the version of a command
function Get-CommandVersion {
    param(
        [string]$Command,
        [string]$VersionArg = "--version"
    )
    try {
        Write-Verbose "Running: $Command $VersionArg"
        # Use Invoke-Expression to handle potential aliases or functions correctly
        # Redirect stderr to stdout (2>&1) to capture version info sometimes printed there
        $output = Invoke-Expression "$Command $VersionArg 2>&1"
        Write-Verbose "Output from $Command $VersionArg : $output"

        # Handle multi-line output (rare, but possible)
        if ($output -is [array]) { $output = $output[0] }

        # Extract version number (match digits.digits.digits or digits.digits)
        if ($output -match '(\d+\.\d+[\.\d]*)([a-zA-Z]+\d*)?') {
            $versionString = $matches[1]
            # Clean common prefixes like 'v' from Node.js
            return $versionString.TrimStart('v')
        } else {
            Write-Verbose "Could not parse version from output: $output"
            return $null
        }
    } catch {
        Write-Verbose "Command '$Command' failed or doesn't support '$VersionArg'. Error: $($_.Exception.Message)"
        return $null
    }
}

# Function to compare semantic versions (e.g., "3.11.2" -ge "3.10")
function Compare-Versions {
    param(
        [string]$VersionA,
        [string]$VersionB
    )
    try {
        # Pad versions with .0 for comparison consistency (e.g., 3.10 -> 3.10.0)
        $vA_str = if ($VersionA -notmatch '\.\d+\.') { "$VersionA.0" } else { $VersionA }
        $vB_str = if ($VersionB -notmatch '\.\d+\.') { "$VersionB.0" } else { $VersionB }
        $vA = [System.Version]$vA_str # Use .NET Version class for robust comparison
        $vB = [System.Version]$vB_str
        return $vA -ge $vB
    } catch {
        Write-Warning "Could not compare versions '$VersionA' and '$VersionB' using System.Version. Falling back to basic split comparison."
        try {
            # Fallback basic comparison (handles cases like '16' vs '16.0')
            $verA = $VersionA.Split('.') | ForEach-Object { [int]$_ }
            $verB = $VersionB.Split('.') | ForEach-Object { [int]$_ }

            for ($i = 0; $i -lt [math]::Max($verA.Length, $verB.Length); $i++) {
                $a = if ($i -lt $verA.Length) { $verA[$i] } else { 0 }
                $b = if ($i -lt $verB.Length) { $verB[$i] } else { 0 }

                if ($a -gt $b) { return $true }
                if ($a -lt $b) { return $false }
            }
            return $true # Equal
        } catch {
             Write-Warning "Fallback version comparison failed for '$VersionA' and '$VersionB'. Assuming check failed."
             return $false
        }
    }
}

# Function to check if a directory is in the PATH environment variable (User or System or Process)
function Test-PathContains {
    param([string]$Directory)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ -ne '' }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ -ne '' }
    $currentProcessPath = $env:PATH -split ';' | Where-Object { $_ -ne '' }

    # Normalize paths for comparison (remove trailing slashes, case-insensitive on Windows)
    $normalizedDir = $Directory.TrimEnd('\')
    $allPaths = $userPath + $machinePath + $currentProcessPath | Select-Object -Unique
    $isInPath = $allPaths | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir -or $_ -eq ($normalizedDir + '\') } # Check with/without trailing slash just in case

    # Return true if found in any scope
    return ($isInPath.Count -gt 0)
}


# Function to add a directory to the User PATH persistently and optionally to the current process PATH
# Returns $true if added to User or Process path in this run, $false otherwise (already exists or error)
function Add-DirectoryToUserPath {
    param(
        [string]$Directory,
        [switch]$ForceAddToProcessPath # Add to current process even if already in User/Machine PATH
    )

    $dirExists = Test-Path -Path $Directory -PathType Container
    if (-not $dirExists) {
        Write-Warning "Directory '$Directory' does not exist. Cannot add to PATH."
        return $false
    }

    # Check persistent PATH first
    $userPathStr = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePathStr = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPathArray = $userPathStr -split ';' | Where-Object { $_ -ne '' }
    $machinePathArray = $machinePathStr -split ';' | Where-Object { $_ -ne '' }
    $normalizedDir = $Directory.TrimEnd('\')

    $isInUser = $userPathArray | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir }
    $isInMachine = $machinePathArray | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir }

    $addedToUserPath = $false
    $persistentlyInPath = ($isInUser.Count -gt 0) -or ($isInMachine.Count -gt 0)

    # Add to User PATH persistently if not in User or Machine PATH
    if (-not $persistentlyInPath) {
        try {
            # Ensure no trailing semicolon and handle empty initial path
            $cleanUserPath = $userPathStr.TrimEnd(';')
            if ($cleanUserPath) {
                $newUserPath = "$cleanUserPath;$Directory"
            } else {
                $newUserPath = $Directory
            }

            Write-Host "  Adding '$Directory' to the User PATH (persistent)..." -ForegroundColor Yellow
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
            $addedToUserPath = $true
            Write-Host "  NOTE: You may need to restart your PowerShell session or log out/in for persistent PATH changes to be fully effective." -ForegroundColor Cyan
        } catch {
            Write-Error "Failed to add '$Directory' to User PATH. You might need to run PowerShell as Administrator or add it manually. Error: $($_.Exception.Message)"
            # Allow script to continue, but warn heavily.
            $ErrorActionPreference = 'Continue'
            Write-Warning "Continuing script despite User PATH update failure for '$Directory'."
            $ErrorActionPreference = 'Stop'
            # Do not return yet, still attempt to add to process path if forced
        }
    } else {
        Write-Verbose "Directory '$Directory' is already present in User or Machine PATH (persistent)."
    }

    # Check if in current process PATH
    $processPathArray = $env:PATH -split ';' | Where-Object { $_ -ne '' }
    $isInProcess = $processPathArray | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir }

    # Add to current process PATH if forced, or if newly added to user path, or if not already in process path
    $shouldAddToProcess = $ForceAddToProcessPath -or $addedToUserPath -or ($isInProcess.Count -eq 0)

    if ($shouldAddToProcess -and ($isInProcess.Count -eq 0)) {
         Write-Host "  Adding '$Directory' to PATH for current session..." -ForegroundColor Green
        $env:PATH = "$Directory;$($env:PATH -join ';')"
         return $true
    } elseif ($isInProcess.Count -gt 0) {
        Write-Verbose "Directory '$Directory' is already in the current process PATH."
        return $addedToUserPath # Return true only if it was added persistently in this run
    } else {
        # Not added to process path (was already there, or shouldn't be added)
        return $addedToUserPath # Return true only if it was added persistently in this run
    }
}

$SysInfo = Get-ComputerInfo # Requires PS 5.1+
$OsArch = $SysInfo.OsArchitecture

#####################################################
### Main Script Logic                             ###
#####################################################

Write-Host "Starting MCP environment setup/check (Windows)..." -ForegroundColor Cyan
Write-Host "Using effective requirements: Python >= $TargetPythonVersion, Node.js >= $TargetNodeVersion"
Write-Host "Script will attempt fallbacks but exit if essential steps fail."

# check Windows version
$WindowsVersion = [System.Environment]::OSVersion.Version
$IsSupportedWindows = ($WindowsVersion.Major -ge 10 -and $WindowsVersion.Build -ge 17763) # Win 10 1809+ generally recommended for winget

# Check winget availability
$WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
$WingetAvailable = $WingetCmd -ne $null

# if the windows version is supported and winget is not available, try to install winget
if ($IsSupportedWindows -and -not $WingetAvailable) {
    Write-Host "Winget not found. Attempting to install via App Installer (requires Microsoft Store access)..." -ForegroundColor Yellow
    try {
        # Check if App Installer is installed first
        $appInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
        if ($appInstaller) {
            Write-Host "App Installer found. Trying to update it to get winget..."
             # This command updates the package, which often includes winget
            Add-AppxPackage -RegisterByFamilyName -MainPackage $appInstaller.PackageFamilyName
            Start-Sleep -Seconds 5 # Give it a moment
            $WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
            $WingetAvailable = $WingetCmd -ne $null
        } else {
             Write-Host "App Installer not found. Opening Microsoft Store page..."
             Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1"
             Write-Warning "Please install 'App Installer' from the Microsoft Store, then re-run this script."
             Write-Warning "If Store access is blocked, search for offline winget installation methods."
             # Cannot proceed reliably without winget or manual intervention here
             # Exit 1 # Optional: Exit if winget is critical and cannot be installed
        }

        if ($WingetAvailable) {
            Write-Host "Winget is now available!" -ForegroundColor Green
        } else {
            Write-Warning "Winget installation/update attempt failed or requires manual action in the Store."
        }
    } catch {
        Write-Warning "Winget installation/update attempt failed: $($_.Exception.Message)"
    }
}

$NodeInstalled = $false
$UvInstalled = $false
$FoundPythonCmd = $null
$FoundPythonVersion = $null
$FoundNodeCmd = $null
$FoundNodeVersion = $null
$FoundUvCmd = $null
$FoundUvVersion = $null


# --- Check/Install Winget (Confirmation) ---
Write-Host "`n--- Checking Winget ---" -ForegroundColor Cyan
if ($WingetAvailable) {
    Write-Host "Winget found at: $($WingetCmd.Source)" -ForegroundColor Green
} else {
    Write-Warning "Winget package manager not found or installation failed."
    Write-Warning "Will attempt fallbacks, but winget is preferred."
}

#####################################################
### Check Python (Python >= $TargetPythonVersion) ###
#####################################################
function Get-LatestPythonVersion {
    $pythonEolApi = "https://endoflife.date/api/python.json"
    try {
        # 获取并解析 JSON 数据
        $allVersions = Invoke-RestMethod -Uri $pythonEolApi -UseBasicParsing

        # 过滤有效版本（未过 EOL 且包含 latest 字段）
        $activeVersions = $allVersions | Where-Object {
            ([datetime]::Parse($_.eol)) -gt (Get-Date) -and
            $_.latest -match '\d+\.\d+\.\d+'
        }

        if (-not $activeVersions) {
            Write-Error "No active Python versions found"
            exit 1
        }

        # 提取所有 latest 版本并排序
        $latestVersion = $activeVersions |
            ForEach-Object {
                [System.Version]$_.latest
            } |
            Sort-Object -Descending |
            Select-Object -First 1

        return "$latestVersion"
    }
    catch {
        Write-Error "Failed to fetch Python versions: $_, using default version 3.13.3"
        return "3.13.3"
    }
}

 # Choose a reliable version >= TargetPythonVersion. Ex: Latest 3.11 or 3.12 if Target is 3.10
 $PythonManualVersion = Get-LatestPythonVersion # Use a recent PATCH version of a stable minor release
 # Global status flags
 $PythonWingetIdVersion = ($PythonManualVersion -split '\.')[0..1] -join '.' # e.g., 3.13
 $PythonInstalled = $false

Write-Host "`n--- Checking Python ---" -ForegroundColor Cyan
Write-Host "Required version: >= $TargetPythonVersion"

# Prefer 'py' launcher if available, then 'python', then 'python3'
$PythonCheckOrder = @('py', 'python', 'python3')
foreach ($pyCmd in $PythonCheckOrder) {
    if (Test-CommandExists $pyCmd) {
        $versionArg = if ($pyCmd -eq 'py') { '-V' } else { '--version' }
        $version = Get-CommandVersion -Command $pyCmd -VersionArg $versionArg
        if ($version -and (Compare-Versions $version $TargetPythonVersion)) {
            Write-Host "Found compatible Python using '$pyCmd': Version $version" -ForegroundColor Green
            $PythonInstalled = $true
            $FoundPythonCmd = $pyCmd
            $FoundPythonVersion = $version
            break
        } elseif ($version) {
             Write-Host "Found Python using '$pyCmd' (Version $version), but it's < $TargetPythonVersion." -ForegroundColor Yellow
        } else {
             Write-Host "Found command '$pyCmd', but could not determine its version." -ForegroundColor Yellow
        }
    } else { Write-Verbose "Command '$pyCmd' not found." }
}

# --- Install Python if needed ---
if (-not $PythonInstalled) {
    Write-Host "Compatible Python not found. Attempting installation..." -ForegroundColor Yellow
    $PythonSuccessfullyInstalledOrFound = $false # Use a clearer flag

    # --- Attempt 1: Winget ---
    if ($WingetAvailable) {
        Write-Host "Attempting to install Python $PythonWingetIdVersion using winget..."
        $PythonWingetId = "Python.Python.$PythonWingetIdVersion" # e.g., Python.Python.3.11
        $WingetScopeArg = "--scope user" # More likely to succeed without elevation

        try {
            Write-Host "Running: winget install --id $PythonWingetId -e --accept-package-agreements --accept-source-agreements $WingetScopeArg"
            winget install --id $PythonWingetId -e --accept-package-agreements --accept-source-agreements $WingetScopeArg
            Write-Host "Winget install command finished. Verifying..." -ForegroundColor Green

            # !! Add PATH to current session & Refresh Cache !!
            Write-Host "  Attempting to update session PATH and refresh cache after Winget install..."
            Start-Sleep -Seconds 5 # Give winget/PATH a moment
            # Try to find the installed python to add its path
            $WingetPyPathFound = $false
            foreach ($pyCmdCheck in $PythonCheckOrder) {
                $cmdInfo = Get-Command $pyCmdCheck -ErrorAction SilentlyContinue
                if ($cmdInfo) {
                    try {
                        $pyExePath = $cmdInfo.Source
                        $pyInstallDir = Split-Path $pyExePath -Parent
                        $scriptsDir = Join-Path $pyInstallDir "Scripts"
                        Write-Host "  Adding Winget-installed Python paths to current session PATH..."
                        Add-DirectoryToUserPath -Directory $pyInstallDir -ForceAddToProcessPath
                        Add-DirectoryToUserPath -Directory $scriptsDir -ForceAddToProcessPath
                        $WingetPyPathFound = $true
                        break # Found one, paths added
                    } catch { Write-Warning "Could not determine Python path from '$pyCmdCheck' after winget install to update session PATH." }
                }
            }
            if ($WingetPyPathFound) {
                 Write-Host "  Refreshing command cache after PATH update..."
                 Start-Sleep -Seconds 2
                 Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                 Get-Command -Name py, python, python3 -ErrorAction SilentlyContinue | Out-Null
            } else {
                 Write-Warning "  Could not find installed Python executable via winget to update session PATH reliably."
            }

            # --- Verification after Winget ---
            Write-Host "  Re-running verification checks..."
            foreach ($pyCmd in $PythonCheckOrder) {
                 if (Test-CommandExists $pyCmd) {
                    $versionArg = if ($pyCmd -eq 'py') { '-V' } else { '--version' }
                    $version = Get-CommandVersion -Command $pyCmd -VersionArg $versionArg
                    if ($version -and (Compare-Versions $version $TargetPythonVersion)) {
                        Write-Host "Found compatible Python using '$pyCmd' after winget installation: Version $version" -ForegroundColor Green
                        $PythonInstalled = $true
                        $FoundPythonCmd = $pyCmd
                        $FoundPythonVersion = $version
                        $PythonSuccessfullyInstalledOrFound = $true
                        break # Exit foreach loop
                    }
                }
            } # End foreach verification loop

            if (-not $PythonSuccessfullyInstalledOrFound) {
                 Write-Warning "Winget install command finished, but a compatible Python was not detected afterwards."
            }

        } catch {
            Write-Warning "Failed to install Python using winget. Error: $($_.Exception.Message)"
            # Do not set $PythonSuccessfullyInstalledOrFound to true, let it fall through to manual
        }
    } else {
        Write-Host "Winget not available. Proceeding to manual download attempt."
    } # End Winget attempt

    # --- Attempt 2: Manual Download and Install (if Winget failed or wasn't available/successful) ---
    if (-not $PythonSuccessfullyInstalledOrFound) {
        Write-Host "Attempting manual download and silent install of Python..." -ForegroundColor Yellow

        $archMap = @{
            # Assume AMD64 for 'X64'
            'X64'    = '-amd64'
            # Windows ARM device (Surface Pro X etc.)
            'ARM64'  = '-arm64'
            # 32 system (Windows 10 32-bit)
            'X86'    = ''
        }
        if (-not $archMap.ContainsKey($OsArch)) {
            $supported = $archMap.Keys -join ', '
            Write-Error "The OS architecture [$OsArch] is not supported."
            Write-Error "This script supports the following architectures: $supported."
            Write-Error "Please manually download the Python installer package:"
            Write-Error "https://www.python.org/downloads/"
            exit 1
        }
        $PythonArchString = $($archMap[$sysArch])

        # --- Configuration for Manual Install ---
        if (-not (Compare-Versions $PythonManualVersion $TargetPythonVersion)) {
            Write-Warning "The hardcoded manual install version ($PythonManualVersion) does not meet the target ($TargetPythonVersion). Check script logic."
        }
        $PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonManualVersion/python-$PythonManualVersion$PythonArchString.exe"
        $TempInstallerPath = Join-Path $env:TEMP "python-$PythonManualVersion$PythonArchString-installer.exe"
        # User install is safer: no admin needed, installs to %LOCALAPPDATA%\Programs\Python\PythonXYZ
        # PrependPath=1 attempts to add to USER path registry key.
        $InstallArgs = "/quiet InstallAllUsers=0 PrependPath=1 Include_test=0"
        # Determine expected path (Python installer default for user install)
        $PythonVersionNoDots = ($PythonManualVersion -split '\.')[0..1] -join '' # e.g., 3.11.9 -> 311
        $ExpectedInstallBase = Join-Path $env:LOCALAPPDATA "Programs\Python"
        $ExpectedInstallDir = Join-Path $ExpectedInstallBase "Python$PythonVersionNoDots" # e.g., C:\Users\...\AppData\Local\Programs\Python\Python311
        $ExpectedScriptsDir = Join-Path $ExpectedInstallDir "Scripts"
        Write-Verbose "Expected Python install directory: $ExpectedInstallDir"
        Write-Verbose "Expected Python Scripts directory: $ExpectedScriptsDir"
        # --- End Configuration ---

        try {
            Write-Host "  Downloading Python $PythonManualVersion ($PythonArchString) installer..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $TempInstallerPath -UseBasicParsing -ErrorAction Stop
            Write-Host "  Download complete: $TempInstallerPath" -ForegroundColor Green

            Write-Host "  Running Python silent install (User scope)..."
            Write-Host "  Arguments: $InstallArgs"
            $process = Start-Process -FilePath $TempInstallerPath -ArgumentList $InstallArgs -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -ne 0) {
                Write-Warning "Python installer process exited with code $($process.ExitCode). Verification will determine success."
            } else {
                    Write-Host "  Python installer process completed successfully (Exit Code 0)."
            }

            Write-Host "  Verifying installation after manual attempt..."

            # --- Verification after Manual Install ---
            # Give file system and potentially registry changes a moment
            Write-Host "  Waiting briefly for installation finalization..."
            Start-Sleep -Seconds 7

            # !! CRITICAL FIX: Force add expected paths to CURRENT SESSION's PATH !!
            $PathAddedToSession = $false
            $ActualInstallDir = $null
            # Check if the exact expected directory exists
            if (Test-Path $ExpectedInstallDir -PathType Container) {
                $ActualInstallDir = $ExpectedInstallDir
            } else {
                # Attempt to find the directory if the exact name differs slightly (e.g., different patch version installed previously)
                Write-Verbose "Expected directory '$ExpectedInstallDir' not found, searching for 'Python$PythonVersionNoDots*' in '$ExpectedInstallBase'..."
                $possibleDirs = Get-ChildItem -Path $ExpectedInstallBase -Directory -Filter "Python$PythonVersionNoDots*" -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending
                if ($possibleDirs.Count -ge 1) {
                    $ActualInstallDir = $possibleDirs[0].FullName # Pick the most recently written one
                    Write-Host "  Found potentially matching install directory: $ActualInstallDir"
                }
            }

            if ($ActualInstallDir) {
                $ActualScriptsDir = Join-Path $ActualInstallDir "Scripts"
                Write-Host "  Adding $ActualInstallDir to PATH for current session..."
                if (Add-DirectoryToUserPath -Directory $ActualInstallDir -ForceAddToProcessPath) {
                    $PathAddedToSession = $true
                }
                if (Test-Path $ActualScriptsDir -PathType Container) {
                    Write-Host "  Adding $ActualScriptsDir to PATH for current session..."
                    if (Add-DirectoryToUserPath -Directory $ActualScriptsDir -ForceAddToProcessPath) {
                        $PathAddedToSession = $true
                    }
                } else { Write-Warning "Expected Scripts directory $ActualScriptsDir not found." }
            } else {
                    Write-Warning "Expected install directory like '$ExpectedInstallDir' not found after installation. Cannot update session PATH."
            }


            # If paths were added to the session, give another tiny moment and refresh command cache *again*
            if ($PathAddedToSession) {
                Write-Host "  Refreshing command cache after PATH update..."
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                Start-Sleep -Seconds 3
                Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                Get-Command -Name py, python, python3 -ErrorAction SilentlyContinue | Out-Null

                if (Test-CommandExists "pip") {
                    Write-Host "  Verified pip is available in PATH" -ForegroundColor Green
                } else {
                    Write-Warning "  pip not found in PATH, using absolute path fallback"
                    $pipPath = Join-Path $ActualInstallDir "Scripts\pip.exe"
                    if (Test-Path $pipPath) {
                        $FoundPythonCmd = "python" # 重置为直接使用python命令
                        Set-Alias -Name pip -Value $pipPath -Scope Global
                    }
                }
            }

            # Now, perform the verification check
            Write-Host "  Re-running verification checks..."
            foreach ($pyCmd in $PythonCheckOrder) {
                    if (Test-CommandExists $pyCmd) {
                    $versionArg = if ($pyCmd -eq 'py') { '-V' } else { '--version' }
                    $version = Get-CommandVersion -Command $pyCmd -VersionArg $versionArg
                    if ($version -and (Compare-Versions $version $TargetPythonVersion)) {
                        Write-Host "Found compatible Python using '$pyCmd' after manual installation: Version $version" -ForegroundColor Green
                        $PythonInstalled = $true # Set the original flag
                        $FoundPythonCmd = $pyCmd
                        $FoundPythonVersion = $version
                        $PythonSuccessfullyInstalledOrFound = $true # Set the overall success flag
                        break # Exit foreach loop
                    }
                }
            } # End foreach verification loop

            if (-not $PythonSuccessfullyInstalledOrFound) {
                Write-Warning "Manual installation process finished, but a compatible Python was not detected afterwards via PATH."
                # Check if the executable exists where expected, even if not in PATH
                if ($ActualInstallDir) {
                    $ExpectedExe = Join-Path $ActualInstallDir "python.exe"
                        if (Test-Path $ExpectedExe) {
                        Write-Warning "Python executable found at $ExpectedExe, but it's not accessible via standard commands (py/python/python3) or doesn't meet version requirements."
                        Write-Warning "Check if the PATH update was successful or if manual intervention is needed."
                    } else {
                            Write-Warning "Python executable was NOT found in the expected installation directory '$ActualInstallDir'."
                    }
                }
            }

        } catch {
            Write-Error "Failed during manual Python download/install process. Error: $($_.Exception.Message)"
            # Ensure flag remains false
            $PythonSuccessfullyInstalledOrFound = $false
        } finally {
            if (Test-Path $TempInstallerPath) {
                Write-Verbose "Removing temporary installer: $TempInstallerPath"
                Remove-Item $TempInstallerPath -Force -ErrorAction SilentlyContinue
            }
        }
    } # End Manual Install attempt

    # --- Final Check for Python Installation ---
    if (-not $PythonSuccessfullyInstalledOrFound) {
        Write-Error "Could not find or install a compatible Python version (>= $TargetPythonVersion) using Winget or Manual methods."
        Write-Error "Please install Python manually (https://www.python.org/downloads/release/python-$($PythonManualVersion.Replace('.',''))/ recommended: $PythonManualVersion)."
        Write-Error "Ensure it matches your system architecture (AMD64/ARM64) and its installation directories (e.g., '$env:LOCALAPPDATA\Programs\Python\PythonXXX' and its 'Scripts' subdirectory) are added to your PATH."
        exit 1
    }

} # End initial if (-not $PythonInstalled)

Write-Host "Python check/installation complete."


#####################################################
### Check Node.js (Node.js >= $TargetNodeVersion) ###
#####################################################
function Get-LatestNodeLtsVersion {
    try {
        $releaseIndexUrl = "https://nodejs.org/dist/index.json"
        Write-Host "Fetching Node.js release list from $releaseIndexUrl..." -ForegroundColor Cyan
        $releases = Invoke-RestMethod -Uri $releaseIndexUrl -UseBasicParsing | ConvertFrom-Json

        # 筛选 LTS 版本并按版本号排序
        $ltsReleases = $releases |
            Where-Object { $_.lts -ne $false } |
            Sort-Object -Property @{Expression={[System.Version]$_.version.TrimStart('v')}; Descending=$true}

        if (-not $ltsReleases) {
            Write-Error "No LTS releases found in Node.js release list"
            exit 1
        }

        return $ltsReleases[0].version # 返回最新 LTS 版本 (如 v22.15.0)
    } catch {
        Write-Error "Failed to fetch Node.js releases. Error: $($_.Exception.Message)"
        exit 1
    }
}

function Get-NodeDownloadUrl {
    param(
        [string]$Version, # 如 v22.15.0
        [string]$OsArch  # 如 X64/ARM64/X86
    )

    $archMap = @{
        'X64'    = 'x64'
        'ARM64'  = 'arm64'
        'X86'    = 'x86'
    }

    if (-not $archMap.ContainsKey($OsArch)) {
        Write-Error "Unsupported architecture: $OsArch"
        exit 1
    }

    $nodeArch = $archMap[$OsArch]
    $cleanVersion = $Version.TrimStart('v') # 处理版本号格式

    return "https://nodejs.org/download/release/$Version/node-$Version-$nodeArch.msi"
}

Write-Host "`n--- Checking Node.js ---" -ForegroundColor Cyan
Write-Host "Required version: >= $TargetNodeVersion"

if (Test-CommandExists "node") {
    $version = Get-CommandVersion -Command "node" -VersionArg "--version"
    if ($version -and (Compare-Versions $version $TargetNodeVersion)) {
        Write-Host "Found compatible Node.js: Version $version" -ForegroundColor Green
        $NodeInstalled = $true
        $FoundNodeCmd = "node"
        $FoundNodeVersion = $version
    } elseif ($version) {
        Write-Host "Found Node.js (Version $version), but it's < $TargetNodeVersion." -ForegroundColor Yellow
    } else {
        Write-Host "Found 'node' command, but could not determine its version." -ForegroundColor Yellow
    }
}

# --- Install Node.js if needed ---
if (-not $NodeInstalled) {
    Write-Host "Compatible Node.js not found." -ForegroundColor Yellow
    $NodeInstallSuccess = $false
    $NodeInstallMethod = "None"

    # 1. Try Winget
    if ($WingetAvailable) {
        Write-Host "Attempting to install Node.js LTS using winget..."
        $NodeWingetId = "OpenJS.NodeJS.LTS"
        # Prefer Machine scope for Node, as it's common. Warn user about potential elevation needs.
        $NodeWingetScope = "--scope machine"
        Write-Warning "Attempting Node.js install with $NodeWingetScope. This might require Administrator privileges."
        try {
            Write-Host "Running: winget install --id $NodeWingetId -e --accept-package-agreements --accept-source-agreements $NodeWingetScope"
            winget install --id $NodeWingetId -e --accept-package-agreements --accept-source-agreements $NodeWingetScope
            Write-Host "Node.js installation via winget completed." -ForegroundColor Green

            # !! Add PATH to current session & Refresh Cache !!
            Write-Host "  Attempting to update session PATH and refresh cache after Winget install..."
            Start-Sleep -Seconds 5
            $nodeDir = "C:\Program Files\nodejs" # Default location for machine install
            if (Test-Path $nodeDir -PathType Container) {
                 Write-Host "  Adding $nodeDir to PATH for current session..."
                 Add-DirectoryToUserPath -Directory $nodeDir -ForceAddToProcessPath # Force adding to current session
                 Write-Host "  Refreshing command cache after PATH update..."
                 Start-Sleep -Seconds 2
                 Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                 Get-Command -Name node -ErrorAction SilentlyContinue | Out-Null
            } else {
                 Write-Warning "  Default Node.js install directory '$nodeDir' not found after Winget install. Cannot update session PATH automatically."
            }

            $NodeInstallSuccess = $true
            $NodeInstallMethod = "Winget"
        } catch {
            Write-Warning "Winget installation failed for Node.js (Maybe need admin?). Trying official installer next. Error: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Winget not available. Trying official Node.js installer..."
    }

    # 2. Try Official MSI Installer (if winget failed or unavailable)
    if (-not $NodeInstallSuccess) {
        $latestLtsVersion = Get-LatestNodeLtsVersion
        Write-Host "Latest Node.js LTS version detected: $latestLtsVersion" -ForegroundColor Cyan

        $NodeLtsUrl = Get-NodeDownloadUrl -Version $latestLtsVersion -OsArch $OsArch
        $TempMsiPath = Join-Path $env:TEMP "node-$latestLtsVersion-$OsArch.msi"

        Write-Host "Downloading Node.js $latestLtsVersion ($OsArch) from: $NodeLtsUrl"
        try {
            Invoke-WebRequest -Uri $NodeLtsUrl -OutFile $TempMsiPath -UseBasicParsing
            Write-Host "Download complete. Starting MSI installation (quiet mode)..."
            Write-Warning "MSI installation might require Administrator privileges if not already elevated."

            # Execute the MSI installer silently
            $msiProcess = Start-Process msiexec.exe -ArgumentList "/i `"$TempMsiPath`" /qn /norestart" -Wait -PassThru

            if ($msiProcess.ExitCode -eq 0) {
                Write-Host "Node.js installation via MSI seems successful." -ForegroundColor Green

                # !! Add PATH to current session & Refresh Cache !!
                Write-Host "  Attempting to update session PATH and refresh cache after MSI install..."
                Start-Sleep -Seconds 5 # Give MSI changes a moment to settle
                $nodeDir = "C:\Program Files\nodejs" # Default location for machine install
                if (Test-Path $nodeDir -PathType Container) {
                     Write-Host "  Adding $nodeDir to PATH for current session..."
                     Add-DirectoryToUserPath -Directory $nodeDir -ForceAddToProcessPath # Force adding to current session
                     Write-Host "  Refreshing command cache after PATH update..."
                     Start-Sleep -Seconds 2
                     Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                     Get-Command -Name node -ErrorAction SilentlyContinue | Out-Null
                } else {
                     Write-Warning "  Default Node.js install directory '$nodeDir' not found after MSI install. Cannot update session PATH automatically."
                }

                $NodeInstallSuccess = $true
                $NodeInstallMethod = "MSI"
            } else {
                Write-Warning "Node.js MSI installation failed with exit code $($msiProcess.ExitCode)."
            }
        } catch {
            Write-Error "Failed during Node.js MSI download/install process. Error: $($_.Exception.Message)"
        } finally {
            if (Test-Path $TempMsiPath) {
                Write-Verbose "Removing temporary installer: $TempMsiPath"
                Remove-Item $TempMsiPath -Force -ErrorAction SilentlyContinue
            }
        }
    } # End MSI Install attempt

    # --- Re-verify Node.js after installation attempt ---
    if ($NodeInstallSuccess) {
        Write-Host "Re-running Node.js verification checks after installation attempt ($NodeInstallMethod)..."
        # Give a little extra time for PATH changes or command cache to potentially update
        Start-Sleep -Seconds 3
        Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue # Clear cache again
        Get-Command -Name node -ErrorAction SilentlyContinue | Out-Null

        if (Test-CommandExists "node") {
            $version = Get-CommandVersion -Command "node" -VersionArg "--version"
            if ($version -and (Compare-Versions $version $TargetNodeVersion)) {
                Write-Host "Found compatible Node.js using 'node' after installation: Version $version" -ForegroundColor Green
                $NodeInstalled = $true # Set the original flag
                $FoundNodeCmd = "node"
                $FoundNodeVersion = $version
            } elseif ($version) {
                Write-Warning "Found Node.js (Version $version) after installation, but it's still < $TargetNodeVersion."
            } else {
                Write-Warning "Found 'node' command after installation, but could not determine its version."
            }
        } else {
             Write-Warning "Node.js installation ($NodeInstallMethod) reported success, but the 'node' command is still not found in PATH."
        }
    }

    # --- Final Check for Node.js Installation ---
    if (-not $NodeInstalled) {
        Write-Error "Could not find or install a compatible Node.js version (>= $TargetNodeVersion) using Winget or MSI methods."
        Write-Error "Please install Node.js LTS manually (https://nodejs.org/)."
        Write-Error "Ensure its installation directory (e.g., 'C:\Program Files\nodejs\') is added to your PATH."
        exit 1
    }

} # End initial if (-not $NodeInstalled)

Write-Host "Node.js check/installation complete."

#####################################################
### Check uv (using installed Python)             ###
#####################################################
Write-Host "`n--- Checking uv (Python Package) ---" -ForegroundColor Cyan
# No specific version check for uv needed for core functionality, just presence.
$UvInstalled = $false
$FoundUvCmd = $null
$FoundUvVersion = $null # Keep for consistency in summary

if (Test-CommandExists "uv") {
    # Basic check, version isn't critical here, just existence
    Write-Host "Found 'uv' command." -ForegroundColor Green
    $UvInstalled = $true
    $FoundUvCmd = "uv"
    # Get version for summary (optional but good)
     $FoundUvVersion = Get-CommandVersion -Command "uv" -VersionArg "--version"
} else {
    Write-Host "'uv' command not found. Will attempt installation." -ForegroundColor Yellow
}

# --- Install uv if needed ---
if (-not $UvInstalled) {
    # uv requires a working Python installation for the pip method.
    # We check if $PythonSuccessfullyInstalledOrFound is true from the previous section.
    if (-not $PythonSuccessfullyInstalledOrFound -or -not $FoundPythonCmd) {
        Write-Host "'uv' needs to be installed, but a working Python installation was not found or confirmed earlier. Cannot proceed with pip method." -ForegroundColor Yellow
        # Even though pip is not available, we can still try the official script.
        # So, don't exit here, just proceed to the official script attempt if needed.
        Write-Host "Proceeding to attempt official uv script installation as Python/pip are not reliably available." -ForegroundColor Yellow
    }

    $UvInstallSuccess = $false
    $InstallMethodUsed = "None"

    # --- Attempt 1: pip install uv (Requires Python and pip) ---
    # Only attempt pip if Python was successfully found/installed earlier
    if ($PythonSuccessfullyInstalledOrFound -and $FoundPythonCmd) {
        Write-Host "Attempting to install 'uv' using '$FoundPythonCmd -m pip install uv'..."
        try {
            Write-Host "  Ensuring pip is up-to-date..."
            # Use | Out-Null to suppress pip's progress bar and normal output unless there's an error
            Invoke-Expression "$FoundPythonCmd -m pip install --upgrade pip" | Out-Null
            if (-not $?) { Write-Warning "  Could not upgrade pip. Proceeding with uv install attempt anyway." }

            Write-Host "  Installing uv via pip..."
            # Add --user flag for user-scope installation if not admin or NoAdmin is set
            $pipInstallArgs = "install uv"
            if (-not $IsAdmin -or $NoAdmin) { $pipInstallArgs += " --user" }

            $pythonExe = (Get-Command $FoundPythonCmd).Source
            $pipPath = Join-Path (Split-Path $pythonExe -Parent) "Scripts\pip.exe"
            if (Test-Path $pipPath) {
                & $pipPath $pipInstallArgs.Split()
            } else {
                & $pythonExe -m pip $pipInstallArgs.Split()
            }

            if ($?) {
                Write-Host "'uv' installation via pip command appears successful." -ForegroundColor Green
                $InstallMethodUsed = "pip"
            } else {
                 Write-Warning "'$FoundPythonCmd -m pip $pipInstallArgs' command failed."
            }
        } catch {
            Write-Warning "Failed during pip installation command execution for 'uv'. Error: $($_.Exception.Message)"
        }

        # --- Verify after pip attempt ---
        Write-Host "  Verifying 'uv' command after pip attempt..."
        # Attempt to add Python Scripts dir to PATH (if not already there) & Refresh Cache
        # This is important because pip --user installs go there.
        try {
             # Ensure $FoundPythonCmd is still valid (it should be if $PythonSuccessfullyInstalledOrFound is true)
             if (Test-CommandExists $FoundPythonCmd) {
                $pythonExePath = (Get-Command $FoundPythonCmd -ErrorAction Stop).Source
                $pythonDir = Split-Path $pythonExePath -Parent
                $pythonScriptsDir = Join-Path $pythonDir "Scripts"

                if (Test-Path $pythonScriptsDir -PathType Container) {
                    Write-Host "  Checking/Adding Python Scripts directory '$pythonScriptsDir' to PATH..."
                    # Add to current session (ForceAddToProcessPath) and potentially persistently (if not NoAdmin)
                    # Add-DirectoryToUserPath returns true if something was added *in this run*
                    $pathAddedByPipAttempt = Add-DirectoryToUserPath -Directory $pythonScriptsDir -ForceAddToProcessPath
                } else { Write-Warning "  Could not find Python Scripts directory at '$pythonScriptsDir'." }
             } else { Write-Warning "  Could not get path for '$FoundPythonCmd' to add Scripts directory." }
        } catch { Write-Warning "  Failed to determine Python Scripts directory path: $($_.Exception.Message)" }

        # Always refresh command cache after attempting PATH changes
        Write-Host "  Refreshing command cache..."
        Start-Sleep -Seconds 2 # Give PATH a moment
        Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
        Get-Command -Name uv -ErrorAction SilentlyContinue | Out-Null # Populate cache for 'uv'

        # Re-check if uv is available after pip install and PATH update
        if (Test-CommandExists "uv") {
            Write-Host "'uv' command found after pip attempt." -ForegroundColor Green
            $UvInstallSuccess = $true
            $FoundUvCmd = "uv"
            $FoundUvVersion = Get-CommandVersion -Command "uv" -VersionArg "--version"
        } else {
             Write-Warning "'uv' command still not found after pip attempt."
        }
    } else {
        Write-Warning "Skipping pip installation attempt for 'uv' because Python/pip are not reliably available."
    } # End pip attempt section


    # --- Attempt 2: Official uv PowerShell script (if pip failed or skipped) ---
    if (-not $UvInstallSuccess) {
        Write-Host "Previous installation method failed or was skipped. Attempting installation using official uv PowerShell script..." -ForegroundColor Yellow
        $OfficialScriptUrl = "https://astral.sh/uv/install.ps1"
        try {
            Write-Host "Running: powershell -ExecutionPolicy ByPass -c ""irm $OfficialScriptUrl | iex"""
            # The official script handles download, extraction, and adding to user PATH
            # It often adds to ~/.cargo/bin or ~/.uv/bin
            # Use Invoke-Expression for simplicity to run the external PowerShell command
            Invoke-Expression "powershell -NoProfile -ExecutionPolicy ByPass -c ""irm $OfficialScriptUrl | iex"""
            # Check the exit code of the *external* powershell process if possible,
            # but Invoke-Expression doesn't easily capture it directly.
            # Relying on the check after the script finishes is often more robust.

            # The official script adds to User PATH. We need to wait a bit and
            # refresh our current session's PATH and command cache for the command to be available.
            Write-Host "  Official uv PowerShell script execution initiated. Waiting briefly for script to finish and PATH changes..."
            Start-Sleep -Seconds 7 # Give the external script and environment changes time

            # Attempt to add common uv script install locations to current session PATH
            # The official script often installs into ~/.cargo/bin
            $uvBinPathsToTry = @(
                (Join-Path $env:USERPROFILE ".cargo\bin"), # Common location for uv via official script
                (Join-Path $env:USERPROFILE ".uv\bin")     # Alternative/older location
            )
            $pathAddedByOfficialScriptAttempt = $false
            foreach ($uvBinPath in $uvBinPathsToTry) {
                if (Test-Path $uvBinPath -PathType Container) {
                    Write-Host "  Checking/Adding potential uv bin directory '$uvBinPath' to PATH..."
                     # Add to current session (ForceAddToProcessPath) and potentially persistently (if not NoAdmin)
                    if (Add-DirectoryToUserPath -Directory $uvBinPath -ForceAddToProcessPath) {
                        $pathAddedByOfficialScriptAttempt = $true # Mark if any path was added
                    }
                }
            }
             if (-not $pathAddedByOfficialScriptAttempt) {
                 Write-Warning "  Could not find common uv installation directories like '~/.cargo/bin'. Manual PATH update might be needed."
             }


            # Refresh command cache again after attempting PATH updates from official script
            Write-Host "  Refreshing command cache again..."
            Start-Sleep -Seconds 3
            Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
            Get-Command -Name uv -ErrorAction SilentlyContinue | Out-Null # Populate cache for 'uv'

        } catch {
             Write-Error "Failed during official uv PowerShell script execution. Error: $($_.Exception.Message)"
             Write-Warning "This might require manual installation or Administrator privileges."
        }

        # --- Verify after official script attempt ---
        Write-Host "  Verifying 'uv' command after official script attempt..."
         if (Test-CommandExists "uv") {
            Write-Host "'uv' command found after official script attempt." -ForegroundColor Green
            $UvInstallSuccess = $true
            $FoundUvCmd = "uv"
            $FoundUvVersion = Get-CommandVersion -Command "uv" -VersionArg "--version"
        } else {
            Write-Warning "'uv' command still not found after official script attempt."
        }
    } # End official script attempt


    # --- Final Check and Error if Still Not Installed ---
    if (-not $UvInstallSuccess) {
        Write-Error "Could not find or install 'uv' using either pip or the official script."
        Write-Error "Please ensure you have a working Python installation (if using pip) and try running one of the following commands manually:"
        Write-Error "  1. (Using your Python's pip): '$FoundPythonCmd -m pip install uv' (if Python is available)"
        Write-Error "  2. (Official Script): 'powershell -ExecutionPolicy ByPass -c ""irm https://astral.sh/uv/install.ps1 | iex""'"
        Write-Error "Also, ensure Python's 'Scripts' directory (e.g., '$pythonScriptsDir') and/or common script install locations (e.g., '$env:USERPROFILE\.cargo\bin') are correctly added to your PATH."
        exit 1
    }
} # End initial if (-not $UvInstalled)

Write-Host "uv check/installation complete."

# --- Final Summary ---
Write-Host "`n--- Setup Summary ---" -ForegroundColor Cyan
Write-Host "Python:"
Write-Host "  Command Used: $FoundPythonCmd"
Write-Host "  Version Found: $FoundPythonVersion (Required >= $TargetPythonVersion)"
Write-Host "Node.js:"
Write-Host "  Command Used: $FoundNodeCmd"
Write-Host "  Version Found: $FoundNodeVersion (Required >= $TargetNodeVersion)"
Write-Host "uv:"
Write-Host "  Command Used: $FoundUvCmd"
Write-Host "  Status: Found/Installed"

Write-Host "`nEnvironment setup check completed successfully." -ForegroundColor Green
exit 0 # Indicate success