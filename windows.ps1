#Requires -Version 5.1

<#
.SYNOPSIS
Checks for and optionally installs required development tools (Python, Node.js, uv) for the MCP environment on Windows.
Prioritizes using the winget package manager.

.DESCRIPTION
This script verifies that compatible versions of Python (>= 3.10) and Node.js (>= 16.0) are installed and accessible.
It also checks for and installs the 'uv' Python package manager/resolver.
If dependencies are missing or incompatible, it attempts to install them using winget.
It checks if winget is installed and provides guidance if it's missing.
It also checks if necessary installation directories are in the user's PATH.

.PARAMETER TargetPythonVersion
The minimum required Python version (default: "3.10").

.PARAMETER TargetNodeVersion
The minimum required Node.js version (default: "16.0").

.EXAMPLE
.\McpEnvInstall-Win.ps1

.EXAMPLE
.\McpEnvInstall-Win.ps1 -TargetPythonVersion "3.11" -TargetNodeVersion "18.0"

.NOTES
- Run this script from a PowerShell terminal.
- You might need to adjust PowerShell's execution policy. Run once:
  Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
- Or bypass it for a single run:
  powershell.exe -ExecutionPolicy Bypass -File .\McpEnvInstall-Win.ps1
- Administrator privileges might be required for some installations via winget, depending on the package and system configuration. The script itself doesn't force elevation but winget might prompt.
- PATH environment variable changes might require restarting the PowerShell session or logging out/in to take effect.
#>
param(
    [ValidatePattern("^\d+\.\d+(\.\d+)?$")]
    [string]$TargetPythonVersion = "3.10",

    [ValidatePattern("^\d+\.\d+(\.\d+)?$")]
    [string]$TargetNodeVersion = "16.0"
)

# --- Script Setup ---
# Stop on errors
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
    # Use PowerShell's [version] type accelerator for reliable comparison
    try {
        # Normalize version format (remove suffix letters)
        $stdVerA = ($VersionA -replace '[^\d.].*$').PadRight(3,'.0')
        $stdVerB = ($VersionB -replace '[^\d.].*$').PadRight(3,'.0')
        return [version]$stdVerA -ge [version]$stdVerB
    } catch {
        Write-Warning "Could not compare versions '$VersionA' and '$VersionB'. Assuming check failed."
        return $false
    }
}

# Function to check if a directory is in the PATH environment variable (User or System)
function Test-PathContains {
    param([string]$Directory)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ -ne '' }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ -ne '' }
    $currentProcessPath = $env:PATH -split ';' | Where-Object { $_ -ne '' }

    # Normalize paths for comparison (remove trailing slashes)
    $normalizedDir = $Directory.TrimEnd('\')
    $isInUser = $userPath | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir }
    $isInMachine = $machinePath | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir }
    $isInProcess = $currentProcessPath | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ -eq $normalizedDir }

    # Return true if found in any scope
    return ($isInUser -ne $null) -or ($isInMachine -ne $null) -or ($isInProcess -ne $null)
}

# Function to add a directory to the User PATH if it's not already there
# Returns $true if added, $false otherwise (already exists or error)
function Add-DirectoryToUserPath {
    param([string]$Directory)

    if (-not (Test-PathContains -Directory $Directory)) {
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

            # Also add to current process PATH for immediate use in this script session
            $env:PATH = "$($env:PATH);$Directory"
            Write-Host "  Added '$Directory' to PATH for current session." -ForegroundColor Green
            Write-Host "  NOTE: You may need to restart your PowerShell session for the PATH change to be fully effective." -ForegroundColor Cyan
            return $true
        } catch {
            Write-Error "Failed to add '$Directory' to User PATH. You might need to run PowerShell as Administrator or add it manually. Error: $($_.Exception.Message)"
            # Continue script execution if PATH update fails, but warn heavily.
            $ErrorActionPreference = 'Continue' # Temporarily allow script to continue
            Write-Warning "Continuing script despite PATH update failure for '$Directory'."
            $ErrorActionPreference = 'Stop'   # Restore error preference
            return $false
        }
    } else {
        Write-Verbose "Directory '$Directory' is already in the PATH."
        return $false # Not added because it was already there
    }
}


# --- Main Script Logic ---

Write-Host "Starting MCP environment setup/check (Windows)..." -ForegroundColor Cyan
Write-Host "Using effective requirements: Python >= $TargetPythonVersion, Node.js >= $TargetNodeVersion"
Write-Host "Script will exit immediately if any essential step fails (unless otherwise noted)."

$WingetCmd = Get-Command winget -ErrorAction SilentlyContinue
$WingetAvailable = $WingetCmd -ne $null
$PythonInstalled = $false
$NodeInstalled = $false
$UvInstalled = $false
$FoundPythonCmd = $null
$FoundPythonVersion = $null
$FoundNodeCmd = $null
$FoundNodeVersion = $null
$FoundUvCmd = $null
$FoundUvVersion = $null

# --- Check/Install Winget ---
Write-Host "`n--- Checking Winget ---" -ForegroundColor Cyan
if ($WingetAvailable) {
    Write-Host "Winget found at: $($WingetCmd.Source)" -ForegroundColor Green
    # Optional: Check winget version or update sources
    # try { winget source update --silent } catch { Write-Warning "Could not update winget sources." }
} else {
    Write-Warning "Winget package manager not found."
    Write-Warning "Winget is the preferred installation method for this script."
    Write-Warning "Please install 'App Installer' from the Microsoft Store to get winget:"
    Write-Warning "ms-windows-store://pdp/?productid=9NBLGGH4NNS1"
    Write-Warning "Alternatively, check Microsoft documentation for other installation methods."
    Write-Warning "Script will attempt to continue, but installations may fail."
    # Allow script to continue, subsequent steps will fail if winget was needed
}

# --- Check Python ---
Write-Host "`n--- Checking Python ---" -ForegroundColor Cyan
Write-Host "Required version: >= $TargetPythonVersion"

# Prefer 'py' launcher if available, then 'python', then 'python3'
$PythonCheckOrder = @('py', 'python', 'python3')
foreach ($pyCmd in $PythonCheckOrder) {
    if (Test-CommandExists $pyCmd) {
        # Special handling for 'py' launcher version reporting
        $versionArg = if ($pyCmd -eq 'py') { '-V' } else { '--version' } # py uses -V, others usually --version
        $version = Get-CommandVersion -Command $pyCmd -VersionArg $versionArg
        if ($version -and (Compare-Versions $version $TargetPythonVersion)) {
            Write-Host "Found compatible Python using '$pyCmd': Version $version" -ForegroundColor Green
            $PythonInstalled = $true
            $FoundPythonCmd = $pyCmd
            $FoundPythonVersion = $version
            break # Found a suitable version
        } elseif ($version) {
             Write-Host "Found Python using '$pyCmd' (Version $version), but it does not meet the requirement (>= $TargetPythonVersion)." -ForegroundColor Yellow
        } else {
             Write-Host "Found command '$pyCmd', but could not determine its version." -ForegroundColor Yellow
        }
    } else {
         Write-Verbose "Command '$pyCmd' not found."
    }
}

# --- Install Python if needed ---
if (-not $PythonInstalled) {
    Write-Host "Compatible Python not found." -ForegroundColor Yellow
    if ($WingetAvailable) {
        Write-Host "Attempting to install Python 3.11 (or latest compatible) using winget..."
        # Find a suitable Python 3.x package ID (e.g., Python.Python.3.11)
        # Winget search can be slow, so we'll just try installing a known recent ID.
        # Adjust the ID if needed based on current winget packages.
        $PythonWingetId = "Python.Python.3.11" # Or "Python.Python.3.10", "Python.Python.3" (less specific)
        try {
            Write-Host "Running: winget install --id $PythonWingetId -e --accept-package-agreements --accept-source-agreements"
            winget install --id $PythonWingetId -e --accept-package-agreements --accept-source-agreements # -e ensures exact ID match
            Write-Host "Python installation via winget initiated. Please follow any prompts." -ForegroundColor Green
            Write-Host "Re-checking for Python after installation attempt..."

            # Re-check after installation attempt
            foreach ($pyCmd in $PythonCheckOrder) {
                 if (Test-CommandExists $pyCmd) {
                    $versionArg = if ($pyCmd -eq 'py') { '-V' } else { '--version' }
                    $version = Get-CommandVersion -Command $pyCmd -VersionArg $versionArg
                    if ($version -and (Compare-Versions $version $TargetPythonVersion)) {
                        Write-Host "Found compatible Python using '$pyCmd' after installation: Version $version" -ForegroundColor Green
                        $PythonInstalled = $true
                        $FoundPythonCmd = $pyCmd
                        $FoundPythonVersion = $version

                        # Check if Python Scripts directory is in PATH (common issue)
                        try {
                            # Find the install location - winget doesn't easily report this post-install
                            # We have to *assume* the default location or where python.exe is now.
                            $pyExePath = (Get-Command $FoundPythonCmd).Source
                            $pyInstallDir = Split-Path $pyExePath -Parent
                            $scriptsDir = Join-Path $pyInstallDir "Scripts"
                            if (Test-Path $scriptsDir) {
                                Add-DirectoryToUserPath -Directory $scriptsDir
                            } else {
                                Write-Verbose "Could not find expected Scripts directory at $scriptsDir"
                            }
                            # Also check the main Python dir itself, just in case
                             Add-DirectoryToUserPath -Directory $pyInstallDir

                        } catch {
                             Write-Warning "Could not reliably determine Python installation path to check/update PATH."
                        }
                        break
                    }
                }
            }
             if (-not $PythonInstalled) {
                 Write-Error "Python installation via winget may have finished, but a compatible version ($TargetPythonVersion) was not detected afterwards."
                 # Script will exit due to ErrorActionPreference=Stop
             }

        } catch {
            Write-Error "Failed to install Python using winget. Error: $($_.Exception.Message)"
            Write-Error "Please install Python >= $TargetPythonVersion manually and ensure it's added to your PATH."
            exit 1 # Explicitly exit
        }
    } else {
        Write-Error "Winget is not available. Cannot automatically install Python."
        Write-Error "Please install Python >= $TargetPythonVersion manually and ensure it's added to your PATH."
        exit 1 # Explicitly exit
    }
}
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
        Write-Host "Found Node.js (Version $version), but it does not meet the requirement (>= $TargetNodeVersion)." -ForegroundColor Yellow
    } else {
        Write-Host "Found 'node' command, but could not determine its version." -ForegroundColor Yellow
    }
}

# --- Install Node.js if needed ---
if (-not $NodeInstalled) {
    Write-Host "Compatible Node.js not found." -ForegroundColor Yellow
    if ($WingetAvailable) {
        Write-Host "Attempting to install Node.js LTS using winget..."
        # Use the LTS ID for stability
        $NodeWingetId = "OpenJS.NodeJS.LTS"
        try {
            Write-Host "Running: winget install --id $NodeWingetId -e --accept-package-agreements --accept-source-agreements"
            winget install --id $NodeWingetId -e --accept-package-agreements --accept-source-agreements
            Write-Host "Node.js installation via winget initiated. Please follow any prompts." -ForegroundColor Green
            Write-Host "Re-checking for Node.js after installation attempt..."

            # Re-check after installation attempt
            Start-Sleep -Seconds 5 # Give install a moment
             if (Test-CommandExists "node") {
                $version = Get-CommandVersion -Command "node" -VersionArg "--version"
                 if ($version -and (Compare-Versions $version $TargetNodeVersion)) {
                    Write-Host "Found compatible Node.js after installation: Version $version" -ForegroundColor Green
                    $NodeInstalled = $true
                    $FoundNodeCmd = "node"
                    $FoundNodeVersion = $version

                    # Node installer usually handles PATH well, but we can double-check common locations if needed
                    # For winget installs, it often goes to C:\Program Files\nodejs
                     $nodeDir = "C:\Program Files\nodejs" # Common default
                     if (Test-Path $nodeDir) {
                         Add-DirectoryToUserPath -Directory $nodeDir
                     }

                 } else {
                     Write-Error "Node.js installation via winget may have finished, but a compatible version ($TargetNodeVersion) was not detected afterwards."
                     # Script will exit
                 }
            } else {
                 Write-Error "Node.js installation via winget may have finished, but the 'node' command was not found."
                 # Script will exit
            }

        } catch {
            Write-Error "Failed to install Node.js using winget. Error: $($_.Exception.Message)"
            Write-Error "Please install Node.js >= $TargetNodeVersion manually and ensure it's added to your PATH."
            exit 1 # Explicitly exit
        }
    } else {
        Write-Error "Winget is not available. Cannot automatically install Node.js."
        Write-Error "Please install Node.js >= $TargetNodeVersion manually and ensure it's added to your PATH."
        exit 1 # Explicitly exit
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
    $InstallMethod = $null

    # Prefer winget if available
    if ($WingetAvailable) {
         # Check if winget knows about uv
         # Winget search is slow, try install directly with known ID
         $UvWingetId = "astral-sh.uv"
         Write-Host "Attempting to install uv using winget (ID: $UvWingetId)..."
         try {
             Write-Host "Running: winget install --id $UvWingetId -e --accept-package-agreements --accept-source-agreements"
             winget install --id $UvWingetId -e --accept-package-agreements --accept-source-agreements
             Write-Host "uv installation via winget initiated." -ForegroundColor Green
             Write-Host "Re-checking for uv after installation attempt..."
             Start-Sleep -Seconds 3

             if (Test-CommandExists "uv") {
                 $version = Get-CommandVersion -Command "uv" -VersionArg "--version"
                 Write-Host "Found uv after installation: Version ${version:-Unknown}" -ForegroundColor Green
                 $UvInstalled = $true
                 $FoundUvCmd = "uv"
                 $FoundUvVersion = $version

                 # Winget install might place it somewhere needing PATH update,
                 # e.g., %LOCALAPPDATA%\Microsoft\WinGet\Packages\astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe\uv.exe
                 # Or it might add a shim. Let's assume winget handles the PATH or shim correctly.
                 # If issues arise, we might need to locate the .exe and call Add-DirectoryToUserPath.

             } else {
                 Write-Error "uv installation via winget may have finished, but the 'uv' command was not found."
                 # Allow continuing, maybe pip method works
             }
         } catch {
             Write-Warning "Failed to install uv using winget. Will try pip next. Error: $($_.Exception.Message)"
         }
    }

    # Fallback to pip if winget failed or wasn't available, and Python is installed
    if (-not $UvInstalled -and $PythonInstalled) {
        Write-Host "Attempting to install uv using Python's pip..."
        if (Test-CommandExists "pip") {
            try {
                Write-Host "Running: pip install uv"
                pip install uv
                Write-Host "uv installation via pip completed." -ForegroundColor Green
                 # Re-check
                 if (Test-CommandExists "uv") {
                     $version = Get-CommandVersion -Command "uv" -VersionArg "--version"
                     Write-Host "Found uv after pip installation: Version ${version:-Unknown}" -ForegroundColor Green
                     $UvInstalled = $true
                     $FoundUvCmd = "uv"
                     $FoundUvVersion = $version
                     # Ensure Python's Scripts directory is in PATH (might have been missed earlier)
                     try {
                         $pipPath = (Get-Command pip).Source
                         $scriptsDir = Split-Path $pipPath -Parent
                         Add-DirectoryToUserPath -Directory $scriptsDir
                     } catch { Write-Warning "Could not confirm pip's Scripts directory is in PATH."}

                 } else {
                     Write-Warning "pip install uv finished, but 'uv' command is still not found. Check if Python's Scripts directory is in your PATH."
                 }
            } catch {
                 Write-Error "Failed to install uv using pip. Error: $($_.Exception.Message)"
                 # Don't exit here, allow the final check below to report the failure.
            }
        } else {
            Write-Warning "pip command not found. Cannot attempt to install uv using pip."
        }
    } # End of fallback to pip

    # Final check if uv was installed by any method
    if (-not $UvInstalled) {
        Write-Error "'uv' could not be installed using winget or pip."
        Write-Error "Please install 'uv' manually. You can often use:"
        Write-Error "- winget install astral-sh.uv"
        Write-Error "- pip install uv"
        Write-Error "- Check https://github.com/astral-sh/uv for other installation methods."
        Write-Error "Ensure the installation location is added to your PATH."
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
} else {
    # This case should ideally not be reached due to earlier exit, but included for completeness
    Write-Host "[FAIL] uv:" -ForegroundColor Red -NoNewline
    Write-Host " uv command not found or installation failed."
    $AllChecksPassed = $false
}

Write-Host "`n--- Important Notes ---" -ForegroundColor Cyan
Write-Host "- If any tools were installed or PATH variables were updated, you might need to RESTART your PowerShell session (or potentially log out/in) for all changes to take effect."
Write-Host "- If winget was used, follow any instructions it provided during installation."
Write-Host "- If any checks failed, please install the required tools manually, ensuring they meet the version requirements and are accessible via your system's PATH."

if ($AllChecksPassed) {
    Write-Host "`nEnvironment check completed successfully. Required tools are likely present." -ForegroundColor Green
    Write-Host "You should be ready to proceed with MCP setup steps like 'uv pip install -r requirements.txt'."
} else {
    Write-Error "`nEnvironment check failed. Please address the issues listed above before proceeding."
    exit 1 # Exit with error code if checks failed
}

Write-Host "`nScript finished."