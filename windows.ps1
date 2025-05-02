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
It checks if necessary installation directories are in the user's PATH and attempts to add them.

.PARAMETER TargetPythonVersion
The minimum required Python version (default: "3.10").

.PARAMETER TargetNodeVersion
The minimum required Node.js version (default: "16.0").

.EXAMPLE
.\McpEnvInstall-Win.ps1

.EXAMPLE
.\McpEnvInstall-Win.ps1 -TargetPythonVersion "3.11" -TargetNodeVersion "18.0"

.NOTES
- Run this script from an administrative PowerShell terminal for potentially smoother installations (especially MSI/winget).
- You might need to adjust PowerShell's execution policy. Run once:
  Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
- Or bypass it for a single run:
  powershell.exe -ExecutionPolicy Bypass -File .\McpEnvInstall-Win.ps1
- PATH environment variable changes might require restarting the PowerShell session or logging out/in to take effect.
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

# --- Helper Functions ---

# Function to check if a command exists in PATH
function Test-CommandExists {
    param($CommandName)
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
        $vA = [System.Version]$VersionA # Use .NET Version class for robust comparison
        $vB = [System.Version]$VersionB
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

# Function to check if a directory is in the PATH environment variable (User or System)
function Test-PathContains {
    param([string]$Directory)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ -ne '' }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ -ne '' }
    $currentProcessPath = $env:PATH -split ';' | Where-Object { $_ -ne '' }

    # Normalize paths for comparison (remove trailing slashes, case-insensitive on Windows)
    $normalizedDir = $Directory.TrimEnd('\')
    $isInUser = $userPath | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir -or $_ -eq ($normalizedDir + '\') } # Check with/without trailing slash just in case
    $isInMachine = $machinePath | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir -or $_ -eq ($normalizedDir + '\') }
    $isInProcess = $currentProcessPath | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir -or $_ -eq ($normalizedDir + '\') }

    # Return true if found in any scope
    return ($isInUser.Count -gt 0) -or ($isInMachine.Count -gt 0) -or ($isInProcess.Count -gt 0)
}


# Function to add a directory to the User PATH if it's not already there
# Returns $true if added, $false otherwise (already exists or error)
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

    $pathAlreadyContains = Test-PathContains -Directory $Directory
    $addedToUserPath = $false

    if (-not $pathAlreadyContains) {
        try {
            $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            # Ensure no trailing semicolon and handle empty initial path
            $cleanUserPath = $currentUserPath.TrimEnd(';')
            if ($cleanUserPath) {
                $newUserPath = "$cleanUserPath;$Directory"
            } else {
                $newUserPath = $Directory
            }

            Write-Host "  Adding '$Directory' to the User PATH..." -ForegroundColor Yellow
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
            $addedToUserPath = $true
        } catch {
            Write-Error "Failed to add '$Directory' to User PATH. You might need to run PowerShell as Administrator or add it manually. Error: $($_.Exception.Message)"
            # Allow script to continue, but warn heavily.
            $ErrorActionPreference = 'Continue'
            Write-Warning "Continuing script despite User PATH update failure for '$Directory'."
            $ErrorActionPreference = 'Stop'
            return $false # Failed to add to User PATH
        }
    } else {
        Write-Verbose "Directory '$Directory' is already present in User or Machine PATH."
    }

    # Always try adding to current process PATH if requested or if newly added to User PATH
    # Check current process path *case-insensitively*
    $processPathContains = $env:PATH -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $Directory.TrimEnd('\') -or $_ -eq ($Directory.TrimEnd('\') + '\') }
    if (($addedToUserPath -or $ForceAddToProcessPath) -and ($processPathContains.Count -eq 0)) {
         Write-Host "  Adding '$Directory' to PATH for current session..." -ForegroundColor Green
         $env:PATH = "$Directory;$($env:PATH)" # Prepend for higher priority in session
         Write-Host "  NOTE: You may need to restart your PowerShell session for User PATH changes to be fully effective." -ForegroundColor Cyan
         return $true # Added to user path or process path
    } elseif ($processPathContains.Count -gt 0) {
        Write-Verbose "Directory '$Directory' is already in the current process PATH."
        return $false # Not added because it was already there
    } else {
        # Was already in User/Machine path, and didn't need forcing into process path
        return $false
    }
}


# --- Main Script Logic ---

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

 # Choose a reliable version >= TargetPythonVersion. Ex: Latest 3.11 or 3.12 if Target is 3.10
$PythonManualVersion = "3.13.3" # Example: A recent stable version known to work
# Global status flags
$WinGetVersionId = $PythonManualVersion -replace '(\d+\.\d+).*', '$1'
$PythonInstalled = $false
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

# --- Check Python ---
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
        Write-Host "Attempting to install Python using winget..."
        # Recommend USER scope for less privilege requirements, aligns with manual fallback
        # OR keep machine scope but add an explicit check/warning for admin rights.
        # Using USER scope here:
        $PythonWingetId = "Python.Python.$WinGetVersionId" # Or a specific version like Python.Python.3.11 / Python.Python.3.12
        $WingetScopeArg = "--scope user" # More likely to succeed without elevation
        # $WingetScopeArg = "--scope machine" # Use if admin is expected/enforced

        # Uncomment the following lines if using --scope machine to warn user
        # if ($WingetScopeArg -eq '--scope machine') {
        #     Write-Warning "Winget installation with '--scope machine' might require Administrator privileges."
        #     # Optional: Add a check here if not running as admin and exit or warn strongly
        # }

        try {
            Write-Host "Running: winget install --id $PythonWingetId -e --accept-package-agreements --accept-source-agreements $WingetScopeArg"
            winget install --id $PythonWingetId -e --accept-package-agreements --accept-source-agreements $WingetScopeArg
            Write-Host "Winget install command finished. Verifying..." -ForegroundColor Green
            Start-Sleep -Seconds 3 # Give winget/PATH a moment

            # --- Verification after Winget ---
            # Force command cache refresh
            Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
            Get-Command -Name py, python, python3 -ErrorAction SilentlyContinue | Out-Null

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

                        # Ensure PATH is updated (winget *should* do this, but double-check)
                        try {
                            $pyExePath = (Get-Command $FoundPythonCmd).Source
                            $pyInstallDir = Split-Path $pyExePath -Parent
                            $scriptsDir = Join-Path $pyInstallDir "Scripts"
                            # Use the modified Add-DirectoryToUserPath suggestion or ensure current session is updated
                            Add-DirectoryToUserPath -Directory $pyInstallDir # Add main dir
                            Add-DirectoryToUserPath -Directory $scriptsDir # Add Scripts dir
                        } catch { Write-Warning "Could not reliably determine Python path after winget install to verify/update PATH."}
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

        # --- Architecture Detection ---
        $SysInfo = Get-ComputerInfo # Requires PS 5.1+
        $Architecture = $SysInfo.OsArchitecture
        $PythonArchString = "amd64" # Default
        if ($Architecture -eq 'ARM64') {
            $PythonArchString = "arm64"
            Write-Host "  Detected ARM64 architecture."
        } elseif ($Architecture -eq 'X86') {
             Write-Warning "Detected 32-bit (X86) architecture. This script targets 64-bit installers. Manual installation required."
             # Exit or skip manual install for X86? For now, skip.
             Write-Error "Manual installation skipped for unsupported X86 architecture."
             # Set a flag to prevent further processing? Or just let the final check fail?
             # For simplicity, let the final check handle it.
        } else {
            # Assume AMD64 for 'X64' or other values for safety
             Write-Host "  Detected AMD64 (X64) architecture."
             $PythonArchString = "amd64"
        }

        # Proceed only if architecture is supported (amd64 or arm64)
        if ($Architecture -ne 'X86') {

            # --- Configuration for Manual Install ---
            if (-not (Compare-Versions $PythonManualVersion $TargetPythonVersion)) {
                Write-Warning "The hardcoded manual install version ($PythonManualVersion) does not meet the target ($TargetPythonVersion). Check script logic."
                # Decide how to handle: Exit? Try a different version? For now, we'll proceed.
            }
            $PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonManualVersion/python-$PythonManualVersion-$PythonArchString.exe"
            $TempInstallerPath = Join-Path $env:TEMP "python-$PythonManualVersion-$PythonArchString-installer.exe"
            # User install is safer: no admin needed, installs to %LOCALAPPDATA%\Programs\Python\PythonXYZ
            $InstallArgs = "/quiet InstallAllUsers=0 PrependPath=1 Include_test=0"
            # Determine expected path (Python installer default for user install)
            $ExpectedInstallBase = Join-Path $env:LOCALAPPDATA "Programs\Python"
            $ExpectedInstallDir = Join-Path $ExpectedInstallBase "Python$($PythonManualVersion -replace '\.')" # e.g., Python3119
            $ExpectedScriptsDir = Join-Path $ExpectedInstallDir "Scripts"
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
                    # Non-zero exit code *might* indicate failure, but isn't always reliable for silent GUI installers
                    Write-Warning "Python installer process exited with code $($process.ExitCode). Verification will determine success."
                } else {
                     Write-Host "  Python installer process completed."
                }

                Write-Host "  Verifying installation after manual attempt..."
                Start-Sleep -Seconds 5

                # --- Verification after Manual Install ---
                Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
                Get-Command -Name py, python, python3 -ErrorAction SilentlyContinue | Out-Null

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

                            # Add the expected directories to PATH for *current* session and persistently
                            # Check if they exist before adding
                            if (Test-Path $ExpectedInstallDir) {
                                Write-Host "  Ensuring $ExpectedInstallDir is in PATH..."
                                Add-DirectoryToUserPath -Directory $ExpectedInstallDir
                            } else { Write-Warning "Expected install directory $ExpectedInstallDir not found after installation."}
                            if (Test-Path $ExpectedScriptsDir) {
                                Write-Host "  Ensuring $ExpectedScriptsDir is in PATH..."
                                Add-DirectoryToUserPath -Directory $ExpectedScriptsDir
                            } else { Write-Warning "Expected Scripts directory $ExpectedScriptsDir not found after installation."}
                            break # Exit foreach loop
                        }
                    }
                } # End foreach verification loop

                if (-not $PythonSuccessfullyInstalledOrFound) {
                    Write-Warning "Manual installation process finished, but a compatible Python was not detected afterwards."
                    # Check if the executable exists where expected, even if not in PATH
                    $ExpectedExe = Join-Path $ExpectedInstallDir "python.exe"
                    if (Test-Path $ExpectedExe) {
                        Write-Warning "Python executable found at $ExpectedExe, but it's not accessible via PATH or doesn't meet version requirements."
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
        } # End if architecture supported
    } # End Manual Install attempt

    # --- Final Check ---
    if (-not $PythonSuccessfullyInstalledOrFound) {
        Write-Error "Could not find or install a compatible Python version (>= $TargetPythonVersion) using Winget or Manual methods."
        Write-Error "Please install Python manually (https://www.python.org/downloads/), ensuring it matches your system architecture (AMD64/ARM64) and is added to your PATH."
        exit 1
    }

} # End initial if (-not $PythonInstalled)

Write-Host "Python check/installation complete."

# --- Check Node.js ---
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
        try {
            Write-Host "Running: winget install --id $NodeWingetId -e --accept-package-agreements --accept-source-agreements --scope machine"
            winget install --id $NodeWingetId -e --accept-package-agreements --accept-source-agreements --scope machine
            Write-Host "Node.js installation via winget completed." -ForegroundColor Green
            $NodeInstallSuccess = $true
            $NodeInstallMethod = "Winget"
        } catch {
            Write-Warning "Winget installation failed for Node.js. Trying official installer next. Error: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Winget not available. Trying official Node.js installer..."
    }

    # 2. Try Official MSI Installer (if winget failed or unavailable)
    if (-not $NodeInstallSuccess) {
        Write-Host "Attempting to install Node.js LTS using official MSI installer..."
        $NodeLtsUrl = "https://nodejs.org/dist/lts/node-lts-x64.msi" # Stable URL for latest LTS x64 MSI
        $TempMsiPath = Join-Path $env:TEMP "node-lts-x64.msi"
        try {
            Write-Host "Downloading Node.js MSI from $NodeLtsUrl..."
            # Use -UseBasicParsing for wider compatibility, especially in older PS versions or restricted environments
            Invoke-WebRequest -Uri $NodeLtsUrl -OutFile $TempMsiPath -UseBasicParsing
            Write-Host "Download complete. Running MSI installer silently..."
            # Use /passive for progress visibility or /quiet for fully silent
            $msiArgs = "/i `"$TempMsiPath`" /passive /norestart"
            Write-Host "Running: msiexec.exe $msiArgs"
            $process = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) { # 0 = success, 3010 = success, reboot required
                Write-Host "Node.js MSI installation completed (Exit code: $($process.ExitCode))." -ForegroundColor Green
                 if ($process.ExitCode -eq 3010) {
                     Write-Warning "A reboot may be required to finalize Node.js installation."
                 }
                 $NodeInstallSuccess = $true
                 $NodeInstallMethod = "MSI"
            } else {
                Write-Warning "Node.js MSI installer failed with exit code: $($process.ExitCode)."
            }
        } catch {
             Write-Warning "Failed to download or run Node.js MSI installer. Error: $($_.Exception.Message)"
        } finally {
            # Clean up downloaded MSI
            if (Test-Path $TempMsiPath) {
                Write-Verbose "Removing temporary file: $TempMsiPath"
                Remove-Item $TempMsiPath -ErrorAction SilentlyContinue
            }
        }
    }

    # Re-check Node.js after installation attempt
    if ($NodeInstallSuccess) {
         Write-Host "Re-checking for Node.js after $NodeInstallMethod installation..."
         Start-Sleep -Seconds 5 # Give PATH changes a moment
         # Force refresh command cache
         Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
         Get-Command -Name node -ErrorAction SilentlyContinue | Out-Null
         if (Test-CommandExists "node") {
            $version = Get-CommandVersion -Command "node" -VersionArg "--version"
            if ($version -and (Compare-Versions $version $TargetNodeVersion)) {
                Write-Host "Found compatible Node.js after installation: Version $version" -ForegroundColor Green
                $NodeInstalled = $true
                $FoundNodeCmd = "node"
                $FoundNodeVersion = $version
                # MSI installer usually handles PATH, but double-check common location
                $nodeDir = "C:\Program Files\nodejs"
                Add-DirectoryToUserPath -Directory $nodeDir -ForceAddToProcessPath
            } else {
                 Write-Error "Node.js installation (via $NodeInstallMethod) finished, but a compatible version ($TargetNodeVersion) was not detected afterwards. Check PATH."
                 exit 1
            }
        } else {
             Write-Error "Node.js installation (via $NodeInstallMethod) finished, but the 'node' command was not found. Check PATH."
             exit 1
        }
    } else {
         # If both winget and MSI failed
         Write-Error "Failed to install Node.js using Winget or the official MSI installer."
         Write-Error "Please install Node.js >= $TargetNodeVersion manually (https://nodejs.org/) and ensure it's added to your PATH."
         exit 1
    }
}
Write-Host "Node.js check/installation complete."


# --- Check/Install uv ---
Write-Host "`n--- Checking/Installing uv ---" -ForegroundColor Cyan

# Check if uv command exists
if (Test-CommandExists "uv") {
    $version = Get-CommandVersion -Command "uv" -VersionArg "--version" # Assuming uv supports --version
     if ($version) {
         # No minimum version specified, just check if it runs
         Write-Host "uv is already installed." -ForegroundColor Green
         Write-Host "Found at: $((Get-Command uv).Source)"
         Write-Host "uv version: $version"
         $UvInstalled = $true
         $FoundUvCmd = "uv"
         $FoundUvVersion = $version
     } else {
         Write-Warning "Found 'uv' command, but could not determine its version. Assuming it's installed but might be broken."
         $UvInstalled = $true # Assume installed if command exists
         $FoundUvCmd = "uv"
         $FoundUvVersion = "Unknown (could not parse)"
     }
}

# Install uv if not found
if (-not $UvInstalled) {
    Write-Host "'uv' command not found." -ForegroundColor Yellow
    $UvInstallSuccess = $false
    $UvInstallMethod = "None"

    # 1. Try Winget
    if ($WingetAvailable) {
         $UvWingetId = "astral-sh.uv"
         Write-Host "Attempting to install uv using winget (ID: $UvWingetId)..."
         try {
             Write-Host "Running: winget install --id $UvWingetId -e --accept-package-agreements --accept-source-agreements"
             # Winget installs often go to user scope by default, which is fine
             winget install --id $UvWingetId -e --accept-package-agreements --accept-source-agreements
             Write-Host "uv installation via winget completed." -ForegroundColor Green
             $UvInstallSuccess = $true
             $UvInstallMethod = "Winget"
         } catch {
             Write-Warning "Winget installation failed for uv. Trying official PowerShell script next. Error: $($_.Exception.Message)"
         }
    } else {
         Write-Host "Winget not available. Trying official uv PowerShell script..."
    }

    # 2. Try Official PowerShell Script (if winget failed or unavailable)
    if (-not $UvInstallSuccess) {
        Write-Host "Attempting to install uv using official PowerShell script..."
        $UvInstallScriptUrl = "https://astral.sh/uv/install.ps1"
        try {
            Write-Host "Running: irm $UvInstallScriptUrl | iex"
            # Ensure TLS 1.2 is enforced for the download
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-Expression (Invoke-RestMethod -Uri $UvInstallScriptUrl)
            Write-Host "uv installation via PowerShell script completed." -ForegroundColor Green
            $UvInstallSuccess = $true
            $UvInstallMethod = "PowerShell Script"

            # The official script installs to $HOME\.local\bin, need to add to PATH
            $uvLocalBinPath = Join-Path $HOME ".local\bin"
            if (Test-Path $uvLocalBinPath -PathType Container) {
                Write-Host "  Adding detected uv install path '$uvLocalBinPath' to PATH..."
                # Suppress the boolean output by assigning to $null or using Out-Null
                $null = Add-DirectoryToUserPath -Directory $uvLocalBinPath -ForceAddToProcessPath
            } else {
                Write-Warning "  Expected uv installation directory '$uvLocalBinPath' not found after script execution."
            }

        } catch {
             Write-Warning "Failed to install uv using official PowerShell script. Trying pip next. Error: $($_.Exception.Message)"
        }
    }

    # 3. Try pip (if winget and script failed, and Python is installed)
    if (-not $UvInstallSuccess -and $PythonInstalled) {
        Write-Host "Attempting to install uv using Python's pip..."
        if (Test-CommandExists "pip") {
            try {
                Write-Host "Running: pip install uv"
                # Use the found python command to ensure using the correct pip if multiple pythons exist
                & $FoundPythonCmd -m pip install uv --upgrade # Ensure latest pip and install uv
                Write-Host "uv installation via pip completed." -ForegroundColor Green
                $UvInstallSuccess = $true
                $UvInstallMethod = "pip"
                 # Ensure Python's Scripts directory is in PATH again
                try {
                     $pipPath = (Get-Command pip).Source # Re-check pip path
                     $scriptsDir = Split-Path $pipPath -Parent
                     Add-DirectoryToUserPath -Directory $scriptsDir -ForceAddToProcessPath
                 } catch { Write-Warning "Could not confirm pip's Scripts directory is in PATH."}

            } catch {
                 Write-Warning "Failed to install uv using pip. Error: $($_.Exception.Message)"
                 # Don't exit here, let the final check report failure.
            }
        } else {
            Write-Warning "pip command not found. Cannot attempt to install uv using pip."
        }
    } # End of fallback to pip

    # Re-check uv after installation attempt
    if ($UvInstallSuccess) {
        Write-Host "Re-checking for uv after $UvInstallMethod installation..."
        Start-Sleep -Seconds 3
        # Force refresh command cache
        Remove-Variable CommandMetadata -Scope Global -Force -ErrorAction SilentlyContinue
        Get-Command -Name uv -ErrorAction SilentlyContinue | Out-Null
        if (Test-CommandExists "uv") {
            $version = Get-CommandVersion -Command "uv" -VersionArg "--version"
            Write-Host "Found uv after installation: Version ${version:-Unknown}" -ForegroundColor Green
            $UvInstalled = $true
            $FoundUvCmd = "uv"
            $FoundUvVersion = $version
            # Ensure the uv location is in the path for the current session
            try {
                $uvPath = (Get-Command uv).Source
                $uvDir = Split-Path $uvPath -Parent
                Add-DirectoryToUserPath -Directory $uvDir -ForceAddToProcessPath
            } catch {Write-Warning "Could not reliably get uv path to ensure it's in session PATH."}
        } else {
            Write-Error "uv installation via $UvInstallMethod finished, but the 'uv' command was not found. Check PATH."
            # Fall through to final check which will report error
        }
    }

    # Final check if uv was installed by any method in this run
    if (-not $UvInstalled) {
        Write-Error "'uv' could not be installed using Winget, PowerShell script, or pip."
        Write-Error "Please install 'uv' manually. Check https://github.com/astral-sh/uv for instructions."
        Write-Error "Ensure the installation location (e.g., '$HOME\.cargo\bin', Python's 'Scripts' folder) is added to your PATH."
        exit 1 # uv is essential, exit if not installed
    }

} # End of if (-not $UvInstalled) block

Write-Host "uv check/installation complete."


# --- Final Summary ---
Write-Host "`n--- Environment Check Summary ---" -ForegroundColor Cyan

$AllChecksPassed = $true

if ($PythonInstalled) {
    Write-Host "[OK] Python:" -ForegroundColor Green -NoNewline
    Write-Host " Found compatible version $FoundPythonVersion using command '$FoundPythonCmd'."
} else {
    Write-Host "[FAIL] Python:" -ForegroundColor Red -NoNewline
    Write-Host " Compatible version (>= $TargetPythonVersion) not found or installation failed."
    $AllChecksPassed = $false
}

if ($NodeInstalled) {
    Write-Host "[OK] Node.js:" -ForegroundColor Green -NoNewline
    Write-Host " Found compatible version $FoundNodeVersion using command '$FoundNodeCmd'."
} else {
    Write-Host "[FAIL] Node.js:" -ForegroundColor Red -NoNewline
    Write-Host " Compatible version (>= $TargetNodeVersion) not found or installation failed."
    $AllChecksPassed = $false
}

if ($UvInstalled) {
    Write-Host "[OK] uv:" -ForegroundColor Green -NoNewline
    Write-Host " Found version ${FoundUvVersion:-Unknown} using command '$FoundUvCmd'."
    # Check if the location is actually in the current PATH
    if (-not (Test-PathContains -Directory (Split-Path (Get-Command $FoundUvCmd).Source -Parent))) {
         Write-Host " [WARNING] uv command found, but its directory might not be permanently in PATH. Restart session." -ForegroundColor Yellow
    }
} else {
    # This case should ideally not be reached due to earlier exit, but included for completeness
    Write-Host "[FAIL] uv:" -ForegroundColor Red -NoNewline
    Write-Host " uv command not found or installation failed."
    $AllChecksPassed = $false
}

Write-Host "`n--- Important Notes ---" -ForegroundColor Cyan
Write-Host "- If any tools were installed or PATH variables were updated, you MUST RESTART your PowerShell session (or potentially log out/in) for all changes to take full effect outside this script run."
Write-Host "- If winget or MSI installers were used, follow any specific instructions or reboot prompts they provided."
Write-Host "- Common install locations added to User PATH:"
if ($PythonInstalled) {
    try {
        $pyExePath = (Get-Command $FoundPythonCmd).Source
        $pyInstallDir = Split-Path $pyExePath -Parent
        $scriptsDir = Join-Path $pyInstallDir "Scripts"
        Write-Host "  - Python: $pyInstallDir"
        Write-Host "  - Python Scripts: $scriptsDir"
    } catch {}
}
if ($NodeInstalled) { Write-Host "  - Node.js: C:\Program Files\nodejs (Default)" }
if ($UvInstalled) {
    try {
        $uvDir = Split-Path (Get-Command $FoundUvCmd).Source -Parent
         Write-Host "  - uv: $uvDir (Location may vary based on install method: Winget, $HOME\.cargo\bin, Python Scripts)"
    } catch {}
}
Write-Host "- If any checks failed, please install the required tools manually, ensuring they meet the version requirements and their installation directories are added to your system's PATH."

if ($AllChecksPassed) {
    Write-Host "`nEnvironment check completed successfully. Required tools are likely present and installed/updated." -ForegroundColor Green
    Write-Host "Remember to RESTART your shell before proceeding with MCP setup steps like 'uv pip install -r requirements.txt'."
} else {
    Write-Error "`nEnvironment check failed. Please address the issues listed above before proceeding."
    exit 1 # Exit with error code if checks failed
}

Write-Host "`nScript finished."