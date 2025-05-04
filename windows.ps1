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

# Check for Administrator privileges
# Get the current Windows identity
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
# Create a Windows principal object from the identity
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal $currentIdentity

# Check if the current principal is in the Administrator role
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Display an error message if not running as administrator
    Write-Error "This script requires Administrator privileges to run. Please right-click the script file and select 'Run as administrator'."
    # Exit the script with a non-zero exit code to indicate failure
    exit 1
}


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

$OsArch = $env:PROCESSOR_ARCHITECTURE.ToLower()

#####################################################
### Main Script Logic                             ###
#####################################################

Write-Host "Starting MCP environment setup/check (Windows)..." -ForegroundColor Cyan
Write-Host "Using effective requirements: Python >= $TargetPythonVersion, Node.js >= $TargetNodeVersion"
Write-Host "Script will attempt fallbacks but exit if essential steps fail."

# --- Check Windows Version ---
$WindowsVersion = [System.Environment]::OSVersion.Version
# Win 10 1809 (Build 17763) or later is generally recommended for winget
$IsSupportedWindows = ($WindowsVersion.Major -ge 10 -and $WindowsVersion.Build -ge 17763)
Write-Host "Windows Version: $WindowsVersion (Supported for Winget: $IsSupportedWindows)"

# --- Check Winget Availability ---
$WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
$WingetAvailable = $WingetCmd -ne $null
$wingetCheckedPath = $false # Flag to indicate if we performed the path check

if (-not $WingetAvailable -and $IsSupportedWindows) {
    Write-Host "Initial 'winget' command check failed." -ForegroundColor Yellow
    $wingetPotentialDir = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    $wingetPotentialExePath = Join-Path $wingetPotentialDir "winget.exe"
    $wingetCheckedPath = $true # Mark that we are attempting the path check

    Write-Host "Checking for winget.exe existence at '$wingetPotentialExePath'..."
    if (Test-Path $wingetPotentialExePath) {
        Write-Host "Found winget.exe at the expected location." -ForegroundColor Green

        # Check if the directory is in the current session's PATH
        $pathArray = $env:PATH -split ';'
        if ($pathArray -notcontains $wingetPotentialDir) {
            Write-Host "The directory '$wingetPotentialDir' is not found in the current session's PATH." -ForegroundColor Yellow
            Write-Host "Adding '$wingetPotentialDir' to the current session's PATH temporarily..."
            try {
                $env:Path += ";$wingetPotentialDir"
                # Verify if winget command is now available after adding path
                $WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
                $WingetAvailable = $WingetCmd -ne $null

                if ($WingetAvailable) {
                    Write-Host "Winget command is now available in this session after PATH update." -ForegroundColor Green
                } else {
                    # This case is unlikely if the file exists and path was added, but handle it.
                    Write-Warning "Added path '$wingetPotentialDir', but 'winget' command still not found. There might be other issues (permissions, file corruption, alias problem)."
                    # Let it fall through to the App Installer check/update logic
                }
            } catch {
                Write-Warning "Failed to add path '$wingetPotentialDir' to environment: $($_.Exception.Message)"
                # Let it fall through to the App Installer check/update logic
            }
        } else {
            Write-Host "The directory '$wingetPotentialDir' is already in the PATH."
            Write-Warning "winget.exe exists and its directory is in PATH, but the command failed initially. This might indicate an App Execution Alias issue or file corruption."
            # Let it fall through to the App Installer check/update logic
        }
    } else {
        Write-Host "winget.exe not found at '$wingetPotentialExePath'."
        # Proceed to App Installer check/install logic
    }
}

# --- Attempt App Installer Update/Install if Winget Still Not Available ---
# This block runs if:
# 1. Initial check failed AND Windows is supported
# 2. AND (winget.exe wasn't found OR adding the path didn't make the command work)
if (-not $WingetAvailable -and $IsSupportedWindows) {
    # Decide message based on whether we already checked the path
    if ($wingetCheckedPath) {
        Write-Host "Winget still not available after checks. Attempting to ensure winget via App Installer (requires Microsoft Store access)..." -ForegroundColor Yellow
    } else {
         # This path would be taken if Windows is supported but the initial check failed,
         # and for some reason the path check logic didn't run (shouldn't happen with current flow, but safe).
         Write-Host "Winget not found. Attempting to install/update via App Installer (requires Microsoft Store access)..." -ForegroundColor Yellow
    }

    try {
        # Check if App Installer is installed first
        $appInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
        if ($appInstaller) {
            Write-Host "App Installer found. Trying to update it to potentially install/enable winget..."
            # This command updates the package, which often includes winget or fixes its registration
            # Using RegisterByFamilyName can sometimes fix registration issues
            Add-AppxPackage -RegisterByFamilyName -MainPackage $appInstaller.PackageFamilyName -DisableDevelopmentMode
            # Alternative/Stronger approach: Re-register the manifest file directly
            # Get-AppxPackage Microsoft.DesktopAppInstaller -AllUsers | Foreach { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" }

            Write-Host "Waiting a few seconds for changes to apply..."
            Start-Sleep -Seconds 5 # Give it a moment for system to recognize changes
            # Re-check winget availability *after* attempting update/re-register
            $WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
            $WingetAvailable = $WingetCmd -ne $null
        } else {
             Write-Host "App Installer package not found. Opening Microsoft Store page..."
             Write-Host "Please install 'App Installer' from the Microsoft Store."
             try {
                 Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1"
             } catch {
                 Write-Warning "Failed to open Microsoft Store automatically. Please search for 'App Installer' manually in the Store."
             }
             Write-Warning "After installing 'App Installer' from the Store, please re-run this script."
             Write-Warning "If Store access is blocked or installation fails, search for offline winget installation methods (e.g., from GitHub releases)."
             # Cannot proceed reliably without winget or manual intervention here
             # Consider exiting if winget is absolutely critical:
             # Write-Error "Winget is required and could not be installed automatically. Exiting."
             # exit 1
        }

        # Final check result after App Installer actions
        if ($WingetAvailable) {
            Write-Host "Winget is now available after App Installer update/re-register!" -ForegroundColor Green
        } else {
             # Check again if App Installer is installed now (maybe user just installed it)
             $appInstaller = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
             if ($appInstaller -and -not $WingetAvailable) {
                 Write-Warning "App Installer is present, but winget command is still not available. Manual troubleshooting might be needed (Check 'App execution aliases' in Windows Settings, try restarting)."
             } elseif (-not $appInstaller) {
                 # User was prompted to install but it's still not found
                 Write-Warning "App Installer not found. Winget cannot be used."
             }
        }
    } catch {
        Write-Warning "Winget installation/update attempt via App Installer failed: $($_.Exception.Message)"
    }
} elseif (-not $IsSupportedWindows) {
    Write-Warning "Winget requires Windows 10 build 17763 or later. Your version ($WindowsVersion) is not supported."
    Write-Warning "Will attempt fallbacks, but winget is preferred for managing tools."
}

# --- Final Winget Confirmation ---
Write-Host "`n--- Checking Winget (Final Confirmation) ---" -ForegroundColor Cyan
if ($WingetAvailable) {
    # Get the source path again in case it was found via the PATH update
    $WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    Write-Host "Winget is available." -ForegroundColor Green
    if ($WingetCmd) {
        Write-Host "Winget location: $($WingetCmd.Source)"
        # Optionally, run a quick version check
        Write-Host "Checking winget version..."
        try {
            winget --version
        } catch {
            Write-Warning "Could not execute 'winget --version': $($_.Exception.Message)"
        }
    }
} else {
    Write-Warning "Winget package manager is not available or could not be configured."
    Write-Warning "Continuing setup using fallback methods where possible."
}

Write-Host "`nEnvironment check script finished." -ForegroundColor Green

#####################################################
### Check Python (Python >= $TargetPythonVersion) ###
#####################################################
# Function to get the latest, still supported (not EOL) Python version string (e.g., "3.12.4")
# by fetching data from the endoflife.date API.
function Get-LatestPythonVersion {
    # API endpoint for Python end-of-life data
    $pythonEolApi = "https://endoflife.date/api/python.json"
    # Define a fallback version in case of API failure or no active versions found
    $fallbackVersion = "3.13.3" # Or choose a suitable default, maybe the latest known good one

    try {
        Write-Host "Fetching Python release list from $pythonEolApi..." -ForegroundColor Cyan
        # Fetch and parse the JSON data. -UseBasicParsing avoids potential IE engine issues.
        # -ErrorAction Stop ensures that errors are caught by the 'catch' block.
        $allVersions = Invoke-RestMethod -Uri $pythonEolApi -UseBasicParsing -ErrorAction Stop

        # Filter for versions that are not yet End-of-Life (EOL)
        # and have a 'latest' version string matching the X.Y.Z format.
        $activeVersions = $allVersions | Where-Object {
            # Ensure the 'eol' property exists and can be parsed as a date
            $eolDate = $null
            try { $eolDate = [datetime]::ParseExact($_.eol, 'yyyy-MM-dd', $null) } catch {}

            ($eolDate -ne $null -and $eolDate -gt (Get-Date)) -and # EOL date is in the future
            ($_.PSObject.Properties.Name -contains 'latest') -and  # 'latest' property exists
            ($_.latest -match '^\d+\.\d+\.\d+$')                  # 'latest' matches X.Y.Z format
        }

        # Check if any active versions were found after filtering
        if (-not $activeVersions) {
            Write-Warning "No active Python versions found matching criteria (not EOL) from API. Using fallback: $fallbackVersion"
            return $fallbackVersion
        }

        # Extract the 'latest' version string from each active cycle,
        # convert it to a [System.Version] object for proper sorting,
        # sort descending (latest first), and select the very first one.
        $latestVersionObject = $activeVersions |
            ForEach-Object {
                [System.Version]$_.latest
            } |
            Sort-Object -Descending |
            Select-Object -First 1

        # Check if we successfully got a version object (should always work if $activeVersions was not empty)
        if ($latestVersionObject) {
             $latestVersionString = $latestVersionObject.ToString()
             Write-Host "Latest active Python version found: $latestVersionString" -ForegroundColor Green
             return $latestVersionString # Return the version as a string (e.g., "3.12.4")
        } else {
            # This case should theoretically not be reached if $activeVersions was populated, but handle defensively.
             Write-Warning "Could not determine the latest version from active cycles. Using fallback: $fallbackVersion"
             return $fallbackVersion
        }

    }
    catch {
        # Catch errors during API fetch or processing (like parsing dates)
        Write-Error "Failed to fetch or process Python versions from $pythonEolApi. Error: $($_.Exception.Message). Using fallback version: $fallbackVersion"
        # Return the fallback version string
        return $fallbackVersion
    }
}

$FoundPythonCmd = $null
$FoundPythonVersion = $null
# Choose a reliable version >= TargetPythonVersion. Ex: Latest 3.11 or 3.12 if Target is 3.10
$PythonManualVersion = Get-LatestPythonVersion # Use a recent PATCH version of a stable minor release
# Global status flags
$PythonWingetIdVersion = ($PythonManualVersion -split '\.')[0..1] -join '.' # e.g., 3.13
$PythonInstalled = $false

Write-Host "`n--- Checking Python ---" -ForegroundColor Cyan
Write-Host "Required version: >= $TargetPythonVersion"

# Prefer 'py' launcher if available, then 'python', then 'python3'
$PythonCheckOrder = @('python', 'py', 'python3')
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
            'amd64'  = '-amd64'
            # Windows ARM device (Surface Pro X etc.)
            'arm64'  = '-arm64'
            # 32 system (Windows 10 32-bit)
            'x86'    = ''
        }
        if (-not $archMap.ContainsKey($OsArch)) {
            $supported = $archMap.Keys -join ', '
            Write-Error "The OS architecture [$OsArch] is not supported."
            Write-Error "This script supports the following architectures: $supported."
            Write-Error "Please manually download the Python installer package:"
            Write-Error "https://www.python.org/downloads/"
            exit 1
        }
        $PythonArchString = $($archMap[$OsArch])

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
            Write-Host "  Downloading Python installer $PythonInstallerUrl ..."
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
$NodeInstalled = $false
$FoundNodeCmd = $null
$FoundNodeVersion = $null

function Get-LatestNodeLtsVersion {
    # URL for the official Node.js release index JSON
    $releaseIndexUrl = "https://nodejs.org/dist/index.json"

    try {
        Write-Host "Fetching Node.js release list from $releaseIndexUrl..." -ForegroundColor Cyan

        # Invoke-RestMethod fetches the URL and automatically parses the JSON response
        # into PowerShell objects. -ErrorAction Stop ensures errors are caught.
        $releases = Invoke-RestMethod -Uri $releaseIndexUrl -ErrorAction Stop

        # Check if the fetch or parsing was successful and returned data
        if (-not $releases) {
            Write-Error "Failed to retrieve or parse data from $releaseIndexUrl. Response was empty or null."
            return $null # Return null to indicate failure
        }

        # Filter the releases:
        # 1. Ensure the 'lts' property exists ($_.PSObject.Properties.Name -contains 'lts').
        # 2. Keep only releases where the 'lts' property is NOT strictly boolean $false.
        #    (LTS releases have a string codename, e.g., "Iron"; non-LTS have `false`).
        # Then, sort the filtered releases:
        # 1. Get the 'version' property.
        # 2. Remove the leading 'v' using TrimStart('v').
        # 3. Cast the remaining string (e.g., "20.15.0") to a [System.Version] object for proper numeric comparison.
        # 4. Sort in Descending order to get the latest version first.
        $ltsReleases = $releases |
            Where-Object { $_.PSObject.Properties.Name -contains 'lts' -and $_.lts -ne $false } |
            Sort-Object -Property @{Expression={[System.Version]$_.version.TrimStart('v')}; Descending=$true}

        # Check if any LTS releases were found after filtering
        if (-not $ltsReleases) {
            Write-Warning "No active LTS releases found in the Node.js release list (URL: $releaseIndexUrl)."
            return $null # Return null to indicate no LTS found
        }

        # Get the 'version' string (e.g., "v20.15.0") from the first object in the sorted list (which is the latest)
        $latestVersionString = $ltsReleases[0].version
        Write-Host "Latest LTS version found: $latestVersionString" -ForegroundColor Green
        return $latestVersionString # Return the version string

    } catch {
        # Catch any errors during the web request or processing
        Write-Error "Failed during Node.js version check. URI: $releaseIndexUrl. Error: $($_.Exception.Message)"
        # Return null to indicate an error occurred
        return $null
    }
}

function Get-NodeDownloadUrl {
    param(
        [string]$Version, # 如 v22.15.0
        [string]$OsArch  # 如 X64/ARM64/X86
    )

    $archMap = @{
        'amd64'    = 'x64'
        'arm64'  = 'arm64'
        'x86'    = 'x86'
    }

    if (-not $archMap.ContainsKey($OsArch)) {
        Write-Error "Unsupported architecture: $OsArch"
        exit 1
    }

    $nodeArch = $archMap[$OsArch]
    $cleanVersion = $Version.TrimStart('v') # 处理版本号格式

    return "https://nodejs.org/download/release/$Version/node-$Version-$nodeArch.msi"
}

Write-Host "--- Checking Node.js ---" -ForegroundColor Cyan
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
### Check uv                                      ###
#####################################################
$UvInstalled = $false
$FoundUvCmd = $null
$FoundUvVersion = $null

Write-Host "--- Checking uv (Python Package) ---" -ForegroundColor Cyan

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

    # Condition for attempting pip install
    $CanAttemptPip = $false
    if ($PythonInstalled -and $FoundPythonCmd -and (Test-CommandExists $FoundPythonCmd)) {
         $CanAttemptPip = $true
         Write-Host "Python found ($FoundPythonCmd), pip installation method is available."
    } else {
        Write-Host "Python command ('$FoundPythonCmd') not found or Python was not detected earlier. Cannot use pip installation method." -ForegroundColor Yellow
        Write-Host "Proceeding to attempt official uv script installation." -ForegroundColor Yellow
    }

    $UvInstallSuccess = $false
    $InstallMethodUsed = "None"

    # --- Attempt 1: pip install uv (Requires Python and pip) ---
    if ($CanAttemptPip) {
        Write-Host "Attempting to install 'uv' using '$FoundPythonCmd -m pip install uv'..."
        try {
            $pythonExePath = (Get-Command $FoundPythonCmd -ErrorAction Stop).Source

            Write-Host "  Ensuring pip is up-to-date..."
            # Use & for direct execution and capture of exit code ($LASTEXITCODE)
            # Use | Out-Null to suppress pip's progress bar and normal output unless there's an error
            & $pythonExePath -m pip install --upgrade pip | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "  Could not upgrade pip (Exit Code $LASTEXITCODE). Proceeding with uv install attempt anyway." }

            Write-Host "  Installing uv via pip..."
            $pipInstallArgs = "install", "uv", "--user" # Force user install

            # Determine the best command to run (pip.exe directly if possible)
            $pythonDir = Split-Path $pythonExePath -Parent
            $pipPath = Join-Path $pythonDir "Scripts\pip.exe"
            $installCommand = $null
            $installArgsArray = @()

            if (Test-Path $pipPath -PathType Leaf) {
                $installCommand = $pipPath
                $installArgsArray = $pipInstallArgs
                 Write-Host "  Using direct pip path: $pipPath"
            } else {
                $installCommand = $pythonExePath
                $installArgsArray = @("-m", "pip") + $pipInstallArgs
                 Write-Host "  Using '$FoundPythonCmd -m pip'"
            }

            Write-Host "  Running: & '$installCommand' $($installArgsArray -join ' ')"
            # Use & for direct execution and capture of exit code ($LASTEXITCODE)
            & $installCommand $installArgsArray # Let output go to host for visibility
            $pipExitCode = $LASTEXITCODE

            if ($pipExitCode -eq 0) {
                Write-Host "'uv' installation via pip command appears successful." -ForegroundColor Green
                $InstallMethodUsed = "pip"
                # Verification follows, don't set $UvInstallSuccess yet
            } else {
                 Write-Warning "'$installCommand $($installArgsArray -join ' ')' command failed with exit code $pipExitCode."
                 # Continue to verification anyway, maybe it was already installed or partially succeeded
            }
        } catch {
            Write-Warning "Failed during pip installation command execution for 'uv'. Error: $($_.Exception.Message)"
        }

        # --- Verify after pip attempt ---
        # Always verify, even if pip reported an error (e.g., Requirement already satisfied)
        Write-Host "  Verifying 'uv' command location after pip attempt..."
        $UvInstallSuccess = $false # Reset success flag before verification
        $uvExeFoundInPath = $null

        try {
            # Need the Python path again for finding scripts
            if (Test-CommandExists $FoundPythonCmd) {
                $pythonExePath = (Get-Command $FoundPythonCmd -ErrorAction Stop).Source
                $pythonDir = Split-Path $pythonExePath -Parent

                # py.exe is in the Python directory with Launcher, like: C:\Users\xxx\AppData\Local\Programs\Python\Launcher\py.exe
                $basename = Split-Path $pythonDir -Leaf
                if ($basename -eq "Launcher") {
                    $pythonDir = Split-Path $pythonDir -Parent
                }

                # --- Potential Script Directories ---
                $potentialScriptDirs = [System.Collections.Generic.List[string]]::new()

                # 1. Standard Python Scripts directory (Global/System install)
                $pythonScriptsDir = Join-Path $pythonDir "Scripts"
                if ($pythonScriptsDir -and (Test-Path $pythonScriptsDir -PathType Container)) {
                    Write-Host "  Checking standard Python scripts directory: $pythonScriptsDir"
                    $potentialScriptDirs.Add($pythonScriptsDir)
                } else {
                    Write-Host "  Standard Python scripts directory not found or not a directory: $pythonScriptsDir"
                }

                # 2. User Scripts directory (Constructed using site --user-site and sysconfig var)
                #    This is crucial for handling --user installs correctly, especially on Windows with arch suffixes.
                $constructedUserScriptsDir = $null
                try {
                    Write-Host "  Querying Python for user base and version/platform info to construct user scripts path..."

                    # Get user base path
                    $userBaseCmdArgs = @("-m", "site", "--user-site")
                    Write-Host "    Executing: & '$pythonExePath' $userBaseCmdArgs"
                    $userBaseOutput = & $pythonExePath $userBaseCmdArgs *>&1 | Out-String # Capture all output
                    $userBaseExitCode = $LASTEXITCODE
                    $userBasePath = $null

                    if ($userBaseExitCode -eq 0) {
                        $userBasePath = ($userBaseOutput -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1).Trim()
                        if (-not $userBasePath) {
                             Write-Warning "    'site --user-site' succeeded but returned empty output."
                        } else {
                             Write-Host "    User base path found: $userBasePath"
                        }
                    } else {
                        Write-Warning "    'site --user-site' failed (Exit Code: $userBaseExitCode). Output/Error: $($userBaseOutput.Trim())"
                    }

                    # If user base path was found, try getting the version/platform suffix
                    if ($userBasePath) {
                        $userBasePath = Join-Path (Split-Path $userBasePath -Parent) "Scripts"
                        if (Test-Path $userBasePath -PathType Container) {
                            $potentialScriptDirs.Add($userBasePath)
                            Write-Host "    Path $userBasePath exists and is a directory. Added to search list." -ForegroundColor Green
                        } else {
                            Write-Warning "    Constructed user script path '$userBasePath' not found or not a directory."
                        }
                    } # End if ($userBasePath)
                } catch {
                    Write-Warning "  Failed during query/construction of user scripts path: $($_.Exception.Message)"
                    $constructedUserScriptsDir = $null
                } # End Try-Catch for user script path construction

                # --- Search for uv.exe in potential directories ---
                $uniquePotentialDirs = $potentialScriptDirs | Select-Object -Unique
                Write-Host "  Searching for 'uv.exe' in potential script directories: $($uniquePotentialDirs -join '; ')"
                foreach ($dir in $uniquePotentialDirs) {
                    $potentialExePath = Join-Path $dir "uv.exe"
                    Write-Host "    Checking: $potentialExePath"
                    if (Test-Path $potentialExePath -PathType Leaf) {
                        Write-Host "    Found 'uv.exe' at: $potentialExePath" -ForegroundColor Cyan
                        $uvExeFoundInPath = $potentialExePath # Store the full path
                        $uvExeDir = Split-Path $uvExeFoundInPath -Parent

                        # Add the found directory to PATH for the current session
                        Write-Host "  Adding directory '$uvExeDir' to PATH for this session..."
                        # Assuming Add-DirectoryToUserPath handles adding to process PATH correctly
                        if (Add-DirectoryToUserPath -Directory $uvExeDir -ForceAddToProcessPath $true) { # Explicitly force process path update
                            # Refresh command cache ONLY if path added AND uv.exe was found
                            Write-Host "  Refreshing command cache after PATH update..."
                            # Using multiple methods to try and force cache refresh
                            $env:PATH = $env:PATH # Force PowerShell to re-read PATH
                            Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                            Get-Command -Name uv -ErrorAction SilentlyContinue | Out-Null # Try to prime cache
                            Start-Sleep -Seconds 3 # Give it a moment

                            # Final check if the command is now available
                            if (Test-CommandExists "uv") {
                                Write-Host "'uv' command successfully verified after pip install and PATH update." -ForegroundColor Green
                                $UvInstallSuccess = $true # Set success flag
                                $FoundUvCmd = "uv"
                                $FoundUvVersion = Get-CommandVersion -Command $FoundUvCmd -VersionArg "--version"
                            } else {
                                Write-Warning "'uv' command still not found after finding uv.exe and updating PATH/cache. This is unexpected. Manual PATH check might be needed."
                            }
                        } else {
                            Write-Warning "  Failed to add '$uvExeDir' to the process PATH (Add-DirectoryToUserPath returned false)."
                        }
                        break # Stop searching once found and processed
                    }
                } # End foreach directory search

                if (-not $uvExeFoundInPath) {
                    Write-Warning "  'uv.exe' was NOT found in any of the determined Python script directories after pip install attempt."
                    # $UvInstallSuccess remains false
                }

            } else {
                Write-Warning "  Could not get path for '$FoundPythonCmd' to determine script directories for verification."
            }
        } catch {
            Write-Warning "  An error occurred during the 'uv' verification process after pip install: $($_.Exception.Message)"
        }

        # If verification failed, make sure the success flag reflects that
        if (-not $UvInstallSuccess) {
            Write-Warning "'uv' command could not be verified after pip attempt (install might have failed, uv.exe not found, or PATH update ineffective)."
        }

    } else {
        # This block is reached if $CanAttemptPip was $false initially
        # Message already printed earlier
    } # End pip attempt section


    # --- Attempt 2: Official uv PowerShell script (if pip failed, was skipped, or verification failed) ---
    if (-not $UvInstallSuccess) {
        Write-Host "" # Add a line break for clarity
        Write-Host "Pip installation method did not succeed or was skipped. Attempting installation using official uv PowerShell script..." -ForegroundColor Yellow
        $OfficialScriptUrl = "https://astral.sh/uv/install.ps1"
        $actualUvInstallDir = $null # Variable to store the path reported by the script

        try {
            Write-Host "Running official uv PowerShell script: powershell -NoProfile -ExecutionPolicy Bypass -Command ""irm '$OfficialScriptUrl' | iex"""
            # Use Invoke-Expression directly within the current process for better control/output capture if possible,
            # but calling external powershell avoids profile/module conflicts. Sticking with external call for now.
            # Capture all streams (*>&1) to ensure we get the 'Installing to' line even if it's on stderr.
            # Add -ErrorAction Stop to make sure exceptions are caught by the catch block
            $uvInstallOutput = & powershell -NoProfile -ExecutionPolicy Bypass -Command "irm '$OfficialScriptUrl' | iex" *>&1 -ErrorAction Stop

            Write-Host "--- Official Script Output ---"
            $uvInstallOutput | Out-Host
            Write-Host "-----------------------------"


            # --- Parse the output to find the installation directory ---
            $uvInstallDirLine = $uvInstallOutput | Select-String -Pattern "Installing to " | Select-Object -First 1
            if ($uvInstallDirLine) {
                $match = $uvInstallDirLine.Line -match "Installing to (.+)$"
                if ($match) {
                    $actualUvInstallDir = $matches[1].Trim()
                    # Normalize path separators and resolve potential relative paths (though unlikely here)
                    try { $actualUvInstallDir = (Resolve-Path -Path $actualUvInstallDir -ErrorAction Stop).Path } catch {}
                    Write-Host "  Official script reported installation directory: $actualUvInstallDir" -ForegroundColor Green
                } else {
                     Write-Warning "  Could not parse installation directory from script output line: '$($uvInstallDirLine.Line)'"
                }
            } else {
                Write-Warning "  Could not find 'Installing to' line in official script output. Assuming common locations."
            }

            # --- Add the determined uv bin directory to the current session's PATH ---
            $pathAddedByOfficialScriptAttempt = $false
            $dirsToAddToPath = [System.Collections.Generic.List[string]]::new()

            if ($actualUvInstallDir -and (Test-Path $actualUvInstallDir -PathType Container)) {
                $dirsToAddToPath.Add($actualUvInstallDir)
            } else {
                 # If the reported path wasn't found or couldn't be parsed, check the common locations as a fallback
                 Write-Warning "  Actual uv installation directory '$actualUvInstallDir' not found or determined. Checking common locations as fallback."
                 # Common locations where the script *might* install uv if default logic changes or fails
                 $uvBinPathsToTry = @(
                    (Join-Path $env:USERPROFILE ".local\bin"), # Often used by such scripts on Windows
                    (Join-Path $env:USERPROFILE ".cargo\bin"), # If installed via cargo/rust toolchain previously
                    (Join-Path $env:USERPROFILE ".uv\bin")     # Potential future default?
                 )
                 foreach ($uvBinPath in $uvBinPathsToTry) {
                    if (Test-Path $uvBinPath -PathType Container) {
                        Write-Host "  Found potential uv bin directory (fallback): '$uvBinPath'"
                        $dirsToAddToPath.Add($uvBinPath)
                    }
                 }
            }

            # Add unique directories found to the PATH
            $uniqueDirsToAdd = $dirsToAddToPath | Select-Object -Unique
            if ($uniqueDirsToAdd.Count -gt 0) {
                Write-Host "  Adding the following directories to PATH for this session: $($uniqueDirsToAdd -join '; ')"
                foreach ($dirToAdd in $uniqueDirsToAdd) {
                     if (Add-DirectoryToUserPath -Directory $dirToAdd -ForceAddToProcessPath $true) { # Explicitly force process path update
                         $pathAddedByOfficialScriptAttempt = $true # Mark if any path was added
                     } else {
                         Write-Warning "    Failed to add '$dirToAdd' to process PATH."
                     }
                }
            } else {
                 Write-Warning "  Could not find any uv installation directories (reported or common). Manual PATH update might be needed."
            }

            # Refresh PATH and command cache if directories were added
            if ($pathAddedByOfficialScriptAttempt) {
                Write-Host "  Refreshing command cache after PATH update from official script attempt..."
                $env:PATH = $env:PATH # Force PowerShell to re-read PATH
                Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                Get-Command -Name uv -ErrorAction SilentlyContinue | Out-Null # Try to prime cache
                Start-Sleep -Seconds 5 # Allow more time for environment changes to propagate
            } else {
                 Write-Host "  No new paths were added by the official script attempt; skipping extra cache refresh."
                 Start-Sleep -Seconds 2 # Still wait a bit just in case
            }

        } catch {
             # Catch errors from the 'powershell -Command ...' execution itself
             Write-Error "Failed during official uv PowerShell script execution. Error: $($_.Exception.Message)"
             Write-Warning "Installation may have failed. Check the output above."
        }

        # --- Verify after official script attempt ---
        Write-Host "  Verifying 'uv' command after official script attempt..."
         if (Test-CommandExists "uv") {
            Write-Host "'uv' command found after official script attempt." -ForegroundColor Green
            $UvInstallSuccess = $true # Set success here after verification
            $FoundUvCmd = "uv"
            $FoundUvVersion = Get-CommandVersion -Command "uv" -VersionArg "--version"
            $InstallMethodUsed = "Official Script"
        } else {
            Write-Warning "'uv' command still not found after official script attempt and PATH updates."
        }
    } # End official script attempt


    # --- Final Check and Error if Still Not Installed ---
    if (-not $UvInstallSuccess) {
        Write-Error "--------------------------------------------------------------------"
        Write-Error "INSTALLATION FAILED: Could not find or install 'uv'."
        $attemptedMethodsMessage = if ($InstallMethodUsed -ne 'None') { $InstallMethodUsed } else { 'pip (if possible), Official Script' }
        Write-Error "Attempted methods: $attemptedMethodsMessage"
        Write-Error "Please ensure you have a working Python installation (if using pip) and try running one of the following commands manually:"
        # Use $FoundPythonCmd in the manual instruction only if it was actually found and exists
        if ($FoundPythonCmd -and (Test-CommandExists $FoundPythonCmd)) {
             Write-Error "  1. (Using pip): '$FoundPythonCmd -m pip install --user uv'"
        } else {
             Write-Error "  1. (Using pip): 'python -m pip install --user uv' (replace 'python' if needed, ensure Python/pip are installed)"
        }
        Write-Error "  2. (Official Script): powershell -ExecutionPolicy Bypass -Command ""irm https://astral.sh/uv/install.ps1 | iex"""
        Write-Error "Also, ensure the relevant scripts directory (e.g., Python's user scripts path, '$($env:USERPROFILE)\.local\bin', '$($env:USERPROFILE)\.cargo\bin') is correctly added to your system's PATH environment variable and restart your terminal/session."
        Write-Error "--------------------------------------------------------------------"
        # Consider whether to exit here or allow the main script to continue
        # exit 1 # Uncomment this line if failure to install uv should stop the entire script
    } else {
         Write-Host "'uv' command is now available ($FoundUvCmd)." -ForegroundColor Green
         Write-Host "  Version: $FoundUvVersion"
         Write-Host "  Installation method used/verified: $InstallMethodUsed"
    }
} else {
     Write-Host "'uv' was already installed ($FoundUvCmd)." -ForegroundColor Green
     Write-Host "  Version: $FoundUvVersion"
}# End initial if (-not $UvInstalled)

Write-Host "--- uv Check Complete ---" -ForegroundColor Cyan

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