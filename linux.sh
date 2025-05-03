#!/bin/bash

# NOTE: This script assumes certain environment variables are pre-set:
# PKG_MANAGER: "apt", "dnf", "yum", "zypper", "pacman", "apk"
# PKG_INSTALL_CMD: The command to install packages (e.g., "sudo apt-get install -y")
# PKG_CHECK_INSTALLED_CMD: Command to check if a package is installed (e.g., "dpkg -s \${pkg} &>/dev/null")
# PYTHON_PKG: Generic base Python package name (e.g., "python3")
# PYTHON_PIP_PKG: Generic pip package name (e.g., "python3-pip", "python-pip")
# PYTHON_INSTALL_VERSIONS: Array of preferred versions to try installing (e.g., ("3.12" "3.11" "3.10"))

# Strict mode
set -eo pipefail # Exit on error, treat unset variables as error, pipe failure is error

# --- Default Minimum Versions ---
DEFAULT_PYTHON_REQ="3.10"
DEFAULT_NODE_REQ="16.0" # Specify minor as 0 for comparison

# --- Target Versions (will be set by defaults or args) ---
TARGET_PYTHON_REQ=""
TARGET_NODE_REQ=""

# --- Installation Targets (Package names may vary) ---
PYTHON_INSTALL_VERSIONS=("3.14" "3.13" "3.12" "3.11" "3.10") # Preferred versions to try installing
NODE_INSTALL_TARGET="nodejs"                                 # Generic package name, version check is key

# --- Package Manager Variables (will be detected) ---
PKG_MANAGER=""
PKG_INSTALL_CMD=""
PKG_UPDATE_CMD=""
PKG_CHECK_INSTALLED_CMD="" # Command template to check if a package *is installed*
PYTHON_PIP_PKG=""
NODE_NPM_PKG=""

# --- Found Tool Info (for summary) ---
FOUND_PYTHON_CMD=""
FOUND_PYTHON_VERSION=""
FOUND_NODE_CMD=""
FOUND_NODE_VERSION=""
FOUND_UV_CMD=""
FOUND_UV_VERSION=""

# --- Helper Functions ---
# Function to determine the command prefix needed for privileged operations.
# Outputs "sudo" to stdout if needed and available.
# Outputs an empty string to stdout if running as root.
# Prints errors to stderr and exits the script if run as non-root and sudo is missing.
get_sudo_prefix() {
    # Check if running as root (EUID 0)
    if [[ "$EUID" -eq 0 ]]; then
        # Running as root, no prefix needed. Output empty string.
        # echo "Info: Running as root. 'sudo' prefix not needed." >&2
        echo ""
        return 0
    fi

    # Not running as root, check if sudo command exists
    if command -v sudo &>/dev/null; then
        # Sudo exists. Output "sudo".
        # echo "Info: 'sudo' command found and will be used for privileged operations." >&2
        echo "sudo"
        return 0
    else
        # Non-root user AND sudo command is missing. This is an error.
        echo "ERROR: Running as non-root and required 'sudo' command not found." >&2
        echo "       Installation requires root privileges or a configured 'sudo' command." >&2
        exit 1
    fi
}

# Capture the sudo prefix immediately after defining the function
SUDO_CMD=$(get_sudo_prefix)

# Function to normalize version string (remove suffixes and pad to X.Y format)
# Example: "3.12.0a1" -> "3.12", "18" -> "18.0"
normalize_version() {
    local version=$1
    # Validate version format first
    if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,3}([a-zA-Z][0-9]*)?$ ]]; then
        echo "Error: Invalid version format: $version. Expected format: X.Y.Z or X.Y.Z.A" >&2
        return 1
    fi
    # Remove any non-digit characters after version numbers
    version=$(echo "$version" | sed -E 's/([0-9]+\.[0-9]+\.[0-9]+).*/\1/; s/^([0-9]+\.[0-9]+)$/\1.0/; s/^([0-9]+)$/\1.0.0/')
    # Ensure we have at least major.minor.patch format
    [[ $version =~ \..\.. ]] || version="${version}.0"
    echo "$version"
}

# Function to compare semantic versions (handles non-standard versions)
# Returns 0 if version1 >= version2, 1 otherwise
compare_versions() {
    # Validate input versions first
    if ! normalize_version "$1" &>/dev/null || ! normalize_version "$2" &>/dev/null; then
        echo "Error: Invalid version format in compare_versions" >&2
        return 2
    fi

    local ver1=$(normalize_version "$1")
    local ver2=$(normalize_version "$2")
    local IFS='.'

    read -ra ver1_parts <<<"$ver1"
    read -ra ver2_parts <<<"$ver2"

    # Compare Major version
    if [[ ${ver1_parts[0]} -gt ${ver2_parts[0]} ]]; then
        return 0
    elif [[ ${ver1_parts[0]} -lt ${ver2_parts[0]} ]]; then
        return 1
    fi

    # Compare Minor version (if major versions are equal)
    if [[ ${ver1_parts[1]:-0} -gt ${ver2_parts[1]:-0} ]]; then
        return 0
    elif [[ ${ver1_parts[1]:-0} -lt ${ver2_parts[1]:-0} ]]; then
        return 1
    fi

    # Compare Patch version (if major and minor versions are equal)
    if [[ ${ver1_parts[2]:-0} -ge ${ver2_parts[2]:-0} ]]; then
        return 0
    else
        return 1
    fi
}

# Detect Linux package manager and set commands
detect_package_manager() {
    echo "--- Detecting Linux Package Manager ---"
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL_CMD="${SUDO_CMD} apt-get install -y"
        PKG_UPDATE_CMD="${SUDO_CMD} apt-get update"
        PKG_CHECK_INSTALLED_CMD='dpkg-query -W --showformat='\''${Status}'\'' ${pkg} 2>/dev/null | grep -q "install ok installed"'
        PYTHON_PIP_PKG="python3-pip"
        NODE_NPM_PKG="npm" # Often comes with nodejs, but good to list
        echo "Detected: Debian/Ubuntu (apt)"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL_CMD="${SUDO_CMD} dnf install -y"
        # Use '|| true' because check-update exits 100 if updates are available, which trips 'set -e'
        PKG_UPDATE_CMD="${SUDO_CMD} dnf check-update --assumeno || true"
        PKG_CHECK_INSTALLED_CMD='dnf list installed ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="python3-pip"
        NODE_NPM_PKG="npm" # Usually nodejs-npm or part of nodejs package
        echo "Detected: Fedora/RHEL (dnf)"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL_CMD="${SUDO_CMD} yum install -y"
        # Use '|| true' because check-update exits 100 if updates are available
        PKG_UPDATE_CMD="${SUDO_CMD} yum check-update --assumeno || true"
        PKG_CHECK_INSTALLED_CMD='yum list installed ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="python3-pip"
        NODE_NPM_PKG="npm" # Usually nodejs-npm or part of nodejs package
        echo "Detected: CentOS/RHEL (yum)"
    elif command -v pacman &>/dev/null; then # Arch Linux
        PKG_MANAGER="pacman"
        PKG_INSTALL_CMD="${SUDO_CMD} pacman -S --noconfirm"
        PKG_UPDATE_CMD="${SUDO_CMD} pacman -Sy"
        PKG_CHECK_INSTALLED_CMD='pacman -Q ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="python-pip"
        NODE_NPM_PKG="npm" # Comes with nodejs package
        echo "Detected: Arch Linux (pacman)"
    elif command -v zypper &>/dev/null; then # OpenSUSE
        PKG_MANAGER="zypper"
        # Added --no-recommends for potentially smaller installs
        PKG_INSTALL_CMD="${SUDO_CMD} zypper install -y --no-recommends"
        PKG_UPDATE_CMD="${SUDO_CMD} zypper refresh"
        # Check only installed packages
        PKG_CHECK_INSTALLED_CMD='zypper se --installed-only ${pkg} &>/dev/null'
        # Note: OpenSUSE Leap/Tumbleweed might have versioned python packages like python310-pip
        PYTHON_PIP_PKG="python3-pip" # Generic fallback
        NODE_NPM_PKG="npm"           # Usually nodejsXX-npm or part of nodejsXX package
        echo "Detected: OpenSUSE (zypper)"
    elif command -v apk &>/dev/null; then # Alpine Linux
        PKG_MANAGER="apk"
        # 'apk add' is often non-interactive enough, -y equivalent is implicit
        PKG_INSTALL_CMD="${SUDO_CMD} apk add"
        PKG_UPDATE_CMD="${SUDO_CMD} apk update"
        # Check if package exists and is installed
        PKG_CHECK_INSTALLED_CMD='apk info -e ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="py3-pip" # Alpine uses py3- prefix often
        NODE_NPM_PKG="npm"       # Installs nodejs and npm
        echo "Detected: Alpine Linux (apk)"
    else
        # Updated error message to include apk
        echo "ERROR: Unsupported package manager. Supported managers: apt, dnf/yum, pacman, zypper, apk" >&2
        exit 1
    fi

    echo "Package manager setup complete. Using '$PKG_MANAGER'."
}

# Check if Python meets the required version, install via package manager if not.
# Arg 1: Required minimum Python version string (e.g., "3.10")
# Sets FOUND_PYTHON_CMD and FOUND_PYTHON_VERSION upon success.
# Returns 0 on success, 1 on failure.
check_install_python() {
    local required_version_str=$1
    local python_found=false
    export FOUND_PYTHON_CMD="" # Export so calling script can use them
    export FOUND_PYTHON_VERSION=""

    # --- Helper function to check pip ---
    _check_pip_functional() {
        local python_cmd="$1"
        if "$python_cmd" -m pip --version &>/dev/null; then
            echo "  OK: 'pip' module accessible via '$python_cmd -m pip'."
            return 0
        else
            echo "  WARN: 'pip' module not accessible via '$python_cmd -m pip'."
            return 1
        fi
    }

    echo "--- Checking Python ---"
    echo "Required version: >= ${required_version_str}"
    echo "Package Manager: $PKG_MANAGER"
    echo "Generic Python Pkg: $PYTHON_PKG"
    echo "Generic Pip Pkg: $PYTHON_PIP_PKG"
    echo "Will try installing: ${PYTHON_INSTALL_VERSIONS[*]}"

    echo "Checking specific Python commands first (python3.14, python3.13...)"
    # Check common specific python executables
    local potential_pythons=("python3.14" "python3.13" "python3.12" "python3.11" "python3.10")
    for cmd in "${potential_pythons[@]}"; do
        local cmd_path
        if cmd_path=$(command -v "$cmd" 2>/dev/null); then
            echo "Found specific command: $cmd at $cmd_path"
            local version_output
            if version_output=$("$cmd_path" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null); then
                echo "  Version reported by $cmd: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Version $version_output meets requirement (>= $required_version_str)."
                        # Check if pip works for this found Python
                        if _check_pip_functional "$cmd_path"; then
                            echo "  Found suitable existing Python with working pip: $cmd_path"
                            python_found=true
                            FOUND_PYTHON_VERSION=$version_output
                            FOUND_PYTHON_CMD=$cmd_path
                            break # Found a suitable specific version with pip
                        else
                            echo "  Existing $cmd meets version but pip check failed. Will attempt install/repair later if needed."
                            # Don't break yet, maybe another version has pip working
                        fi
                    else
                        echo "  Version $version_output does not meet requirement."
                    fi
                else echo "  Warning: Could not parse version output '$version_output' from '$cmd'."; fi
            else echo "  Warning: Failed to execute '$cmd_path -c ...' to get version."; fi
        else echo "Specific command '$cmd' not found in PATH."; fi
    done

    # If no suitable specific version found, check generic 'python3'
    if ! $python_found; then
        echo "No suitable specific Python command found (or pip missing). Checking generic 'python3'..."
        local python3_executable
        if ! python3_executable=$(command -v python3 2>/dev/null); then
            echo "Generic 'python3' command not found in PATH."
        else
            echo "Found generic python3 executable at: ${python3_executable}"
            local version_output
            if version_output=$("$python3_executable" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null); then
                echo "  Version reported by python3: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Generic python3 version $version_output meets requirement (>= $required_version_str)."
                        # Check if pip works for this generic Python
                        if _check_pip_functional "$python3_executable"; then
                            echo "  Found suitable generic Python with working pip: $python3_executable"
                            python_found=true
                            FOUND_PYTHON_VERSION=$version_output
                            FOUND_PYTHON_CMD=$python3_executable
                        else
                            echo "  Generic python3 meets version but pip check failed. Will proceed to installation attempts."
                        fi
                    else echo "  Generic python3 version ($version_output) is lower than required $required_version_str."; fi
                else echo "  Warning: Could not parse version output '$version_output' from generic 'python3'."; fi
            else echo "  Warning: Failed to execute 'python3 -c ...' to get version."; fi
        fi
    fi

    # --- Decision Point: If suitable Python with pip found, we are done ---
    if $python_found; then
        echo "--------------------------------------------------"
        echo "Python check completed successfully."
        echo "Using existing Python: $FOUND_PYTHON_CMD (Version: $FOUND_PYTHON_VERSION)"
        echo "--------------------------------------------------"
        return 0 # Success: Existing Python is suitable and has working pip
    fi

    # --- Installation Block ---
    echo "No suitable existing Python with working pip found."
    echo "Attempting to install Python >= $required_version_str using $PKG_MANAGER..."
    # Package list update should have happened before calling this function

    local installed_successfully=false
    # PYTHON_INSTALL_VERSIONS should be set in the calling script (e.g., ("3.12" "3.11" "3.10"))

    # Try installing preferred versions first
    for py_ver in "${PYTHON_INSTALL_VERSIONS[@]}"; do
        # Check if this version is high enough
        if ! compare_versions "$py_ver.0" "$required_version_str"; then
            echo "Skipping attempt to install Python $py_ver (lower than required $required_version_str)."
            continue
        fi

        local python_pkg=""                  # Primary python package (versioned if possible)
        local versioned_pip_pkg=""           # Version-specific pip package
        local py_ver_no_dots="${py_ver//./}" # For yum/zypper (e.g., 311)

        # Determine package names based on package manager conventions
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            python_pkg="python${py_ver}"
            # Often relies on generic python3-pip, but check specific just in case
            versioned_pip_pkg="python${py_ver}-pip"
        elif [[ "$PKG_MANAGER" == "pacman" ]]; then
            # Pacman typically uses generic 'python' for the latest and 'python-pip'
            # Installing older specific versions is harder, focus on generic
            python_pkg="python" # Might fetch latest, not specific py_ver
            # pip is separate: python-pip (handled by generic below)
        elif [[ "$PKG_MANAGER" == "apk" ]]; then
            # Similar to pacman, often uses generic names
            python_pkg="python3" # Might fetch latest, not specific py_ver
            # pip is separate: py3-pip (handled by generic below)
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
            # DNF often uses dotted versions for specific releases
            python_pkg="python${py_ver}"
            versioned_pip_pkg="python${py_ver}-pip"
        elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "zypper" ]]; then
            # Yum and Zypper typically use non-dotted versions
            python_pkg="python${py_ver_no_dots}"
            versioned_pip_pkg="python${py_ver_no_dots}-pip"
        else # Fallback default - may need adjustment for specific pkg managers
            echo "Warning: Unknown package manager '$PKG_MANAGER'. Guessing package names (python${py_ver}, python${py_ver}-pip)."
            python_pkg="python${py_ver}"
            versioned_pip_pkg="python${py_ver}-pip" # Guess
        fi

        # Always include the generic pip package name as a fallback/requirement
        local effective_generic_pip_pkg="$PYTHON_PIP_PKG"

        local packages_to_try=()
        # Add determined primary versioned package (if defined)
        if [[ -n "$python_pkg" ]]; then packages_to_try+=("$python_pkg"); fi
        # Add determined versioned pip (if defined)
        if [[ -n "$versioned_pip_pkg" ]]; then packages_to_try+=("$versioned_pip_pkg"); fi
        # Add generic pip package (ensure it's added, might be the only pip option)
        if [[ -n "$effective_generic_pip_pkg" ]]; then packages_to_try+=("$effective_generic_pip_pkg"); fi

        # Remove potential duplicates and empty strings
        if [[ ${#packages_to_try[@]} -gt 0 ]]; then
            packages_to_try=($(echo "${packages_to_try[@]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '))
        fi

        # Skip if list is empty (shouldn't happen with generic pip added)
        if [[ ${#packages_to_try[@]} -eq 0 ]]; then
            echo "No packages determined to try for Python $py_ver, skipping."
            continue
        fi

        echo "Attempting to install Python $py_ver and pip using packages: ${packages_to_try[*]}"

        # Prepare install command with conditional flags
        local install_cmd_base="$PKG_INSTALL_CMD"
        local install_opts=""
        # Add --skip-broken for dnf/yum to handle cases where a *specific* pip package might
        # be missing, but the base python and generic pip might still install.
        if [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]]; then
            # Check if PKG_INSTALL_CMD already contains skip-broken
            if [[ ! "$install_cmd_base" =~ --skip-broken ]]; then
                install_opts=" --skip-broken"
            fi
        fi

        # Use eval to handle potential spaces if SUDO_CMD is empty and execute
        if eval "$install_cmd_base $install_opts ${packages_to_try[*]}"; then
            local exit_code=$?
            echo "Package installation command for Python $py_ver finished (Exit code: $exit_code)."
            # NOTE: Exit code 0 with --skip-broken doesn't guarantee everything installed. MUST re-verify.

            # --- IMPORTANT: Refresh environment after install ---
            echo "Refreshing shell command cache..."
            hash -r
            sleep 1 # Optional small delay
            # ----------------------------------------------------

            # Verify command, version, AND pip after install attempt
            local verified_cmd_path=""
            local cmd_to_verify=""
            # Determine the command name to check based on conventions
            if [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "zypper" ]]; then
                cmd_to_verify="python${py_ver_no_dots}" # e.g. python311
                # Also check dotted as a fallback
                local cmd_dotted="python${py_ver}"
                if verified_cmd_path=$(command -v "$cmd_to_verify" 2>/dev/null); then
                    echo "Found expected command '$cmd_to_verify' at '$verified_cmd_path'."
                elif verified_cmd_path=$(command -v "$cmd_dotted" 2>/dev/null); then
                    echo "Found alternative command '$cmd_dotted' at '$verified_cmd_path'."
                    cmd_to_verify=$cmd_dotted # Use the one we found
                fi
            else                                # apt, dnf, others usually prefer dotted
                cmd_to_verify="python${py_ver}" # e.g. python3.11
                if verified_cmd_path=$(command -v "$cmd_to_verify" 2>/dev/null); then
                    echo "Found expected command '$cmd_to_verify' at '$verified_cmd_path'."
                fi
            fi

            # If specific command not found, fall back to checking generic python3
            if [[ -z "$verified_cmd_path" ]]; then
                echo "Expected command '$cmd_to_verify' not found after install. Checking generic 'python3'..."
                if verified_cmd_path=$(command -v python3 2>/dev/null); then
                    echo "Found generic 'python3' at '$verified_cmd_path'. Will verify its version."
                    cmd_to_verify="python3"
                else
                    echo "Warning: Neither specific command nor generic 'python3' found in PATH after installation attempt for $py_ver."
                    # Continue to next iteration
                    continue
                fi
            fi

            # Now verify the found command
            local version_output
            if version_output=$("$verified_cmd_path" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null); then
                echo "  Version reported by '$verified_cmd_path': $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    # Check if version meets requirement (could be generic python3 version)
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Version $version_output meets requirement (>= $required_version_str)."
                        # *** CRUCIAL: Check pip AGAIN for this newly installed/verified python ***
                        if _check_pip_functional "$verified_cmd_path"; then
                            echo "Python $py_ver installation/verification successful with working pip."
                            FOUND_PYTHON_CMD=$verified_cmd_path
                            FOUND_PYTHON_VERSION=$version_output
                            installed_successfully=true
                            break # Exit the loop, we found and installed/verified a suitable version
                        else
                            echo "  ERROR: Installed/found Python '$verified_cmd_path' ($version_output) but 'pip' module is not functional after install attempt."
                            echo "         Tried to install: ${packages_to_try[*]}"
                            echo "         Possible missing package or incomplete installation."
                            # Continue loop to try next version
                        fi
                    else
                        echo "  Warning: Verified command '$verified_cmd_path' version ($version_output) doesn't meet requirement >= $required_version_str."
                    fi
                else echo "  Warning: Could not parse version output '$version_output' from '$verified_cmd_path'."; fi
            else echo "  Warning: Failed to execute '$verified_cmd_path -c ...' to get version after installation."; fi
        else # Installation command failed
            local exit_code=$?
            echo "Failed to install packages for Python $py_ver (Exit code: $exit_code). Packages tried: ${packages_to_try[*]}"
            # Add hints based on package manager and exit code if known
            if [[ "$PKG_MANAGER" == "apt" ]] && [[ $exit_code -eq 100 ]]; then echo "  Hint: Exit code 100 on apt often means 'package not found'. Check repository configuration and package names."; fi
            if [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]] && [[ $exit_code -ne 0 ]]; then echo "  Hint: Non-zero exit code on dnf/yum often means 'package not found', conflicts, or other errors. Check logs."; fi
            if [[ "$PKG_MANAGER" == "zypper" ]] && [[ $exit_code -eq 104 ]]; then echo "  Hint: Exit code 104 on zypper often means 'package not found'. Check repository configuration and package names."; fi
            echo "  Common reasons include package not found in repositories or conflicts."
        fi
        # End of install attempt block for this version
    done # End of loop trying specific versions

    # --- Fallback: Try installing generic packages if specific versions failed ---
    if ! $installed_successfully; then
        echo "Could not install a specific desired Python version (${PYTHON_INSTALL_VERSIONS[*]}) with working pip."
        echo "Attempting to install generic '$PYTHON_PKG' and '$PYTHON_PIP_PKG' as a fallback..."

        local generic_packages_to_install=()
        if [[ -n "$PYTHON_PKG" ]]; then generic_packages_to_install+=("$PYTHON_PKG"); fi
        if [[ -n "$PYTHON_PIP_PKG" ]] && [[ "$PYTHON_PIP_PKG" != "$PYTHON_PKG" ]]; then # Avoid duplicates if PYTHON_PKG provides pip
            generic_packages_to_install+=("$PYTHON_PIP_PKG")
        fi

        # Remove potential duplicates and empty strings
        if [[ ${#generic_packages_to_install[@]} -gt 0 ]]; then
            generic_packages_to_install=($(echo "${generic_packages_to_install[@]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '))
        fi

        if [[ ${#generic_packages_to_install[@]} -gt 0 ]]; then
            echo "Attempting to install generic packages: ${generic_packages_to_install[*]}"
            # Prepare install command with conditional flags
            local install_cmd_base="$PKG_INSTALL_CMD"
            local install_opts=""
            if [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]]; then
                if [[ ! "$install_cmd_base" =~ --skip-broken ]]; then
                    install_opts=" --skip-broken"
                fi
            fi

            # Use eval to handle potential spaces if SUDO_CMD is empty
            if eval "$install_cmd_base $install_opts ${generic_packages_to_install[*]}"; then
                echo "Generic package installation command finished."
                # --- IMPORTANT: Refresh environment after install ---
                echo "Refreshing shell command cache..."
                hash -r
                sleep 1 # Optional small delay
                # ----------------------------------------------------

                # Re-check generic python3 after installation attempt
                local python3_executable
                if ! python3_executable=$(command -v python3 2>/dev/null); then
                    echo "ERROR: Generic 'python3' command still not found after attempting generic installation."
                else
                    echo "Found generic python3 executable at: ${python3_executable}"
                    local version_output
                    if version_output=$("$python3_executable" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null); then
                        echo "  Version reported by python3: $version_output"
                        if [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            if compare_versions "$version_output" "$required_version_str"; then
                                echo "  Generic python3 version $version_output meets requirement (>= $required_version_str)."
                                # Final check for pip
                                if _check_pip_functional "$python3_executable"; then
                                    echo "Generic Python installation successful and verified with working pip."
                                    FOUND_PYTHON_CMD=$python3_executable
                                    FOUND_PYTHON_VERSION=$version_output
                                    installed_successfully=true # Mark success
                                else
                                    echo "ERROR: Installed generic python3 ($version_output) but the required 'pip' module is missing/not working."
                                    echo "       Tried installing: ${generic_packages_to_install[*]}"
                                    echo "       You might need to manually install the package '$PYTHON_PIP_PKG'."
                                fi
                            else
                                echo "ERROR: Installed generic python3 version ($version_output) is < $required_version_str."
                            fi
                        else echo "  Warning: Could not parse version output '$version_output' from generic 'python3'."; fi
                    else echo "  Warning: Failed to execute 'python3 -c ...' to get version."; fi
                fi # End check for python3 command existence
            else   # Generic install command failed
                local exit_code=$?
                echo "ERROR: Failed to install generic Python packages (${generic_packages_to_install[*]}). Exit code: $exit_code."
            fi # End generic package install command
        else
            echo "No generic Python packages defined to attempt installation."
        fi # End check if generic packages list is non-empty
    fi     # End fallback generic install block

    # --- Final Result ---
    if $installed_successfully; then
        echo "--------------------------------------------------"
        echo "Python setup completed successfully."
        echo "Using Python: $FOUND_PYTHON_CMD (Version: $FOUND_PYTHON_VERSION)"
        echo "--------------------------------------------------"
        return 0 # SUCCESS
    else
        echo "--------------------------------------------------" >&2
        echo "ERROR: Failed to find or install a compatible Python version (>= $required_version_str) with working pip using $PKG_MANAGER." >&2
        echo "Please install Python $required_version_str or newer manually." >&2
        echo "Ensure 'python3' (or a versioned command like 'python3.11'/'python311') and 'pip' are installed and accessible." >&2
        echo "Common packages needed:" >&2
        echo "  - Debian/Ubuntu: python3.X python3-pip (or python3.X-pip)" >&2
        echo "  - Fedora/RHEL(dnf): python3.X python3-pip (or python3.X-pip)" >&2
        echo "  - CentOS/RHEL(yum)/openSUSE: python3X python3-pip (or python3X-pip)" >&2
        echo "  - Arch Linux: python python-pip" >&2
        echo "  - Alpine Linux: python3 py3-pip" >&2
        echo "Note: Some systems bundle pip, others require a separate package (e.g., python3-pip, python3.11-pip, python311-pip, python-pip)." >&2
        echo "You might need to consult your distribution's documentation or use alternative installation methods (like pyenv or compiling from source)." >&2
        echo "--------------------------------------------------" >&2
        # Clean up exported variables on failure? Optional.
        # export FOUND_PYTHON_CMD=""
        # export FOUND_PYTHON_VERSION=""
        return 1 # FAILURE
    fi
}

# Check if Node.js meets the required version, install via package manager if not.
check_install_nodejs() {
    local required_version_str=$1
    local node_executable

    echo "--- Checking Node.js ---"
    echo "Required version: >= ${required_version_str}"

    local node_found_compatible=false
    if node_executable=$(command -v node 2>/dev/null); then
        echo "Found node executable at: ${node_executable}"
        local version_output
        # Handle potential errors during version check
        if version_output=$("$node_executable" --version 2>/dev/null); then
            echo "Detected Node.js version string: $version_output"
            local version_numeric=${version_output#v} # Remove leading 'v'
            # Handle potential variations like 'v16.20.2\n' or extra output
            version_numeric=$(echo "$version_numeric" | head -n1 | tr -d '\n')

            # Relax regex slightly to allow major-only or major.minor versions if needed, though compare_versions pads them
            if [[ "$version_numeric" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
                if compare_versions "$version_numeric" "$required_version_str"; then
                    echo "Found compatible Node.js version ($version_numeric) >= $required_version_str."
                    node_found_compatible=true
                    FOUND_NODE_CMD=$node_executable
                    FOUND_NODE_VERSION=$version_output # Store full string like v16.20.2
                else
                    echo "Found Node.js version ($version_numeric) but it's < $required_version_str."
                fi
            else echo "Warning: Could not parse version numeric part '$version_numeric' from '$node_executable --version' output '$version_output'."; fi
        else echo "Warning: Failed to execute '$node_executable --version' to get version (Command failed or produced no output)."; fi
    else
        echo "'node' command not found in PATH."
    fi

    # Check for npm as well if node was found and compatible
    if $node_found_compatible; then
        if ! command -v npm &>/dev/null; then
            echo "Warning: 'node' is compatible, but 'npm' command is missing."
            echo "Attempting to install npm package ('$NODE_NPM_PKG')..."
            # Use eval for command execution
            if ! eval "$PKG_INSTALL_CMD $NODE_NPM_PKG"; then
                echo "ERROR: Failed to install '$NODE_NPM_PKG'. Node.js environment might be incomplete."
                return 1 # Fail if npm install fails
            else
                if ! command -v npm &>/dev/null; then
                    echo "ERROR: Still cannot find 'npm' after attempting installation of '$NODE_NPM_PKG'."
                    return 1
                fi
                echo "'npm' installed successfully."
            fi
        else
            echo "'npm' command found."
        fi
        echo "Node.js and npm check complete."
        return 0 # Success
    fi

    # --- Installation Block ---
    echo "Compatible Node.js not found or check failed."
    echo "Attempting to install '$NODE_INSTALL_TARGET' and '$NODE_NPM_PKG' using $PKG_MANAGER..."
    echo "Note: Default Linux repositories might contain older Node.js versions."
    # Package list update is done globally before this function

    local packages_to_install=()
    # Add NODE_INSTALL_TARGET if it's not empty or same as NODE_NPM_PKG
    if [[ -n "$NODE_INSTALL_TARGET" ]] && [[ "$NODE_INSTALL_TARGET" != "$NODE_NPM_PKG" ]]; then
        packages_to_install+=("$NODE_INSTALL_TARGET")
    fi
    # Add NODE_NPM_PKG if it's not empty
    if [[ -n "$NODE_NPM_PKG" ]]; then
        packages_to_install+=("$NODE_NPM_PKG")
    fi

    # Ensure nodejs is included if target is just npm (e.g. apk)
    if [[ "$PKG_MANAGER" == "apk" ]] && ! printf '%s\n' "${packages_to_install[@]}" | grep -q -w "nodejs"; then
        packages_to_install+=("nodejs")
    fi

    # Remove duplicates
    packages_to_install=($(echo "${packages_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        echo "Warning: No specific Node.js or npm packages identified for installation with $PKG_MANAGER. Skipping install attempt."
        echo "Please ensure Node.js >= $required_version_str and npm are installed manually."
        return 1
    fi

    echo "Attempting to install packages: ${packages_to_install[*]}"
    # Use eval for command execution
    if eval "$PKG_INSTALL_CMD ${packages_to_install[*]}"; then
        echo "Node.js/npm package installation command finished."

        echo "Refreshing shell command cache..."
        hash -r
        sleep 1 # Optional small delay

        # Verify installation
        if ! node_executable=$(command -v node 2>/dev/null); then
            echo "ERROR: Installed package(s) but 'node' command is still not found in PATH."
            return 1
        fi
        if ! command -v npm &>/dev/null; then
            echo "ERROR: Installed package(s) but 'npm' command is still not found in PATH."
            # Some systems might need a separate npm package even after installing nodejs
            if [[ "$NODE_NPM_PKG" != "npm" ]] && [[ "$PKG_MANAGER" != "apk" ]]; then # Avoid redundant install if npm was the target
                echo "Attempting to install 'npm' package explicitly..."
                if ! eval "$PKG_INSTALL_CMD npm"; then
                    echo "ERROR: Failed to install 'npm' explicitly."
                    return 1
                elif ! command -v npm &>/dev/null; then
                    echo "ERROR: Still cannot find 'npm' after explicit install."
                    return 1
                fi
            else
                return 1 # If initial install included npm pkg and it's still not found
            fi
        fi

        echo "Verifying installed Node.js version..."
        local installed_version_output
        if installed_version_output=$(node --version 2>/dev/null); then
            local installed_numeric=${installed_version_output#v}
            installed_numeric=$(echo "$installed_numeric" | head -n1 | tr -d '\n')
            echo "Verified Node.js version: $installed_version_output"
            if compare_versions "$installed_numeric" "$required_version_str"; then
                echo "Installed Node.js version meets requirement >= $required_version_str."
                FOUND_NODE_CMD=$node_executable
                FOUND_NODE_VERSION=$installed_version_output
                echo "Node.js check/installation complete."
                return 0 # Success
            else
                # --- NodeSource Guidance ---
                echo "--------------------------------------------------"
                echo "ERROR: Installed Node.js version ($installed_numeric) from default repository is too old (< $required_version_str)."
                echo "To install a newer version, you often need to use NodeSource or NVM (Node Version Manager)."
                echo ""
                echo "Option 1: NodeSource (Recommended for system-wide install)"
                echo "  1. Visit: https://github.com/nodesource/distributions#installation-instructions"
                echo "  2. Find instructions for your Linux distribution and desired Node.js major version (e.g., 18.x, 20.x)."
                echo "  3. Follow the steps to add the repository and install Node.js."
                echo ""
                echo "Option 2: NVM (Recommended for user-level, multiple versions)"
                echo "  1. Visit: https://github.com/nvm-sh/nvm#installing-and-updating"
                echo "  2. Follow the instructions to install NVM."
                echo "  3. Run 'nvm install node' (for latest LTS) or 'nvm install <version>' (e.g., 'nvm install 18')."
                echo "  4. Ensure NVM is loaded in your current shell: 'nvm use <version>'"
                echo ""
                echo "Re-run this script after installing a compatible Node.js version."
                echo "--------------------------------------------------"
                return 1 # Fail because version is too old
            fi
        else
            echo "Error: Failed to verify Node.js version using 'node --version' after installation."
            return 1
        fi
    else
        echo "Error: Failed to install Node.js/npm packages (${packages_to_install[*]}) using $PKG_MANAGER."
        # Provide NodeSource/NVM info here too, as failure might be due to non-existence in old repos
        echo "--------------------------------------------------"
        echo "Installation failed. This might be because the packages are unavailable or broken in your current repositories."
        echo "Consider using NodeSource or NVM for a reliable installation:"
        echo "NodeSource: https://github.com/nodesource/distributions#installation-instructions"
        echo "NVM: https://github.com/nvm-sh/nvm#installing-and-updating"
        echo "--------------------------------------------------"
        return 1
    fi
}

# Check if uv is installed, install if not. (Uses curl method)
install_uv() {
    echo "--- Checking/Installing uv ---"
    # Check both default PATH and common user install location first
    if FOUND_UV_CMD=$(command -v uv 2>/dev/null); then
        echo "uv found in PATH."
    elif [[ -x "$HOME/.cargo/bin/uv" ]]; then
        echo "uv found in $HOME/.cargo/bin (not necessarily in PATH)."
        FOUND_UV_CMD="$HOME/.cargo/bin/uv"
    elif [[ -x "$HOME/.local/bin/uv" ]]; then
        echo "uv found in $HOME/.local/bin (not necessarily in PATH)."
        FOUND_UV_CMD="$HOME/.local/bin/uv"
    fi

    if [[ -n "$FOUND_UV_CMD" ]]; then
        echo "Using uv found at: $FOUND_UV_CMD"
        # Attempt to get version, allow failure
        FOUND_UV_VERSION=$("$FOUND_UV_CMD" --version 2>/dev/null || echo "(version check failed)")
        echo "uv version: $FOUND_UV_VERSION"
        # Check if the found location is actually in PATH for user convenience info
        if ! command -v uv &>/dev/null && [[ ":$PATH:" != *":$(dirname "$FOUND_UV_CMD"):"* ]]; then
            echo "Warning: The directory containing uv ('$(dirname "$FOUND_UV_CMD")') might not be in your active PATH."
            echo "         You may need to add it to your shell profile (e.g., ~/.bashrc, ~/.zshrc)."

            echo "Temporarily adding $(dirname "$FOUND_UV_CMD") to PATH for this session."
            export PATH="$(dirname "$FOUND_UV_CMD"):$PATH"
            hash -r
        fi
        echo "uv check complete (already installed)."
        return 0
    fi

    echo "uv not found. Attempting to install uv using recommended curl | sh method..."
    echo "--- Installing essential tools (if missing) ---"
    local essential_tools_missing=()
    # Check for tools needed by the uv installer script
    if ! command -v tar &>/dev/null; then
        echo "'tar' command not found."
        essential_tools_missing+=("tar")
    fi
    if ! command -v gzip &>/dev/null; then
        echo "'gzip' command not found (needed by tar for .gz files)."
        essential_tools_missing+=("gzip")
    fi
    # Also ensure curl is present for the download step itself
    if ! command -v curl &>/dev/null; then
        echo "'curl' command not found."
        essential_tools_missing+=("curl")
    fi

    if [[ ${#essential_tools_missing[@]} -gt 0 ]]; then
        echo "Attempting to install missing essential tools: ${essential_tools_missing[*]}"
        # Use eval for SUDO_CMD if defined, otherwise run directly
        local install_cmd="$PKG_INSTALL_CMD ${essential_tools_missing[*]}"
        if [[ -n "$SUDO_CMD" ]]; then
            install_cmd="$SUDO_CMD $install_cmd"
        fi

        if eval "$install_cmd"; then
            echo "Essential tools (${essential_tools_missing[*]}) installed successfully."
            # Verify again just to be sure
            local failed_verify=false
            hash -r # Refresh command cache after install
            for tool in "${essential_tools_missing[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    echo "ERROR: Verification failed. '$tool' still not found after installation attempt." >&2
                    failed_verify=true
                fi
            done
            if $failed_verify; then
                exit 1 # Exit if essential tools couldn't be installed
            fi
        else
            local exit_code=$?
            echo "ERROR: Failed to install essential tools (${essential_tools_missing[*]}). Exit code: $exit_code. Cannot proceed." >&2
            exit 1
        fi
    else
        echo "Essential tools (tar, gzip, curl) are available."
    fi

    # Execute the installer script
    # Make sure the environment for the script has PATH set correctly, especially for non-interactive shells
    # The astral installer usually handles putting uv in ~/.cargo/bin or suggests ~/.local/bin
    echo "Running: curl -LsSf https://astral.sh/uv/install.sh | sh"
    # Use a temporary file for the script to avoid potential piping issues with `sh` needing stdin
    local install_script_path="/tmp/uv_install_script.sh"
    if curl -LsSf https://astral.sh/uv/install.sh -o "$install_script_path"; then
        if sh "$install_script_path"; then
            echo "uv installation script finished."
            # Clean up installer script
            rm -f "$install_script_path"

            echo "Refreshing shell command cache..."
            hash -r
            sleep 1

            # Try to find uv again, checking common locations explicitly
            local installed_uv_path=""
            if installed_uv_path=$(command -v uv 2>/dev/null); then
                echo "uv command is now available in PATH."
            elif [[ -x "$HOME/.cargo/bin/uv" ]]; then
                installed_uv_path="$HOME/.cargo/bin/uv"
                echo "uv installed to $installed_uv_path."
            elif [[ -x "$HOME/.local/bin/uv" ]]; then
                installed_uv_path="$HOME/.local/bin/uv"
                echo "uv installed to $installed_uv_path."
            else
                echo "ERROR: uv installation script ran, but cannot find the 'uv' executable in PATH, ~/.cargo/bin, or ~/.local/bin."
                echo "Please check the output of the installation script for errors or alternative locations."
                return 1
            fi

            FOUND_UV_CMD="$installed_uv_path"
            # Verify command and get version again
            if "$FOUND_UV_CMD" --version &>/dev/null; then
                FOUND_UV_VERSION=$("$FOUND_UV_CMD" --version)
                echo "Successfully installed uv. Version: $FOUND_UV_VERSION"
                # Check if PATH needs updating
                if ! command -v uv &>/dev/null && [[ ":$PATH:" != *":$(dirname "$FOUND_UV_CMD"):"* ]]; then
                    echo "--------------------------------------------------"
                    echo "ACTION REQUIRED: '$(dirname "$FOUND_UV_CMD")' is not in your current PATH."
                    echo "You need to add it to your PATH to use 'uv' directly in new shells."
                    echo "Add the following line to your shell profile (e.g., ~/.bashrc, ~/.zshrc):"
                    echo ""
                    echo "  export PATH=\"$(dirname "$FOUND_UV_CMD"):\$PATH\""
                    echo ""
                    echo "Then, restart your shell or run 'source ~/.your_profile_file'."
                    echo "The script will use the full path '$FOUND_UV_CMD' for this run."
                    echo "--------------------------------------------------"
                fi
                echo "uv check/installation complete."
                return 0
            else
                echo "ERROR: uv installation script ran, found executable at '$FOUND_UV_CMD', but cannot execute it or get version."
                return 1
            fi
        else
            echo "ERROR: Failed to execute the downloaded uv installation script ($install_script_path)."
            rm -f "$install_script_path" # Clean up failed script
            return 1
        fi
    else
        echo "ERROR: Failed to download the uv installation script using curl."
        return 1
    fi
}

# --- Argument Parsing ---
usage() {
    echo "Usage: $0 [--python-version <min_version>] [--node-version <min_version>]"
    echo "  Checks for and optionally installs Python, Node.js, and uv."
    echo "  Defaults: Python >= $DEFAULT_PYTHON_REQ, Node.js >= $DEFAULT_NODE_REQ"
    echo "Examples:"
    echo "  $0                             # Use default versions"
    echo "  $0 --python-version 3.11       # Require Python >= 3.11"
    echo "  $0 --node-version 18.0         # Require Node.js >= 18.0"
    echo "  $0 --python-version 3.12 --node-version 20.0"
    exit 1
}

# Initialize with defaults
TARGET_PYTHON_REQ=$DEFAULT_PYTHON_REQ
TARGET_NODE_REQ=$DEFAULT_NODE_REQ

# Simple loop for argument parsing
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --python-version)
        if [[ -z "$2" ]] || [[ "$2" == -* ]]; then # Check if value is missing or looks like another option
            echo "Error: Missing value for --python-version argument." >&2
            usage
        fi
        TARGET_PYTHON_REQ="$2"
        shift # past argument
        shift # past value
        ;;
    --node-version)
        if [[ -z "$2" ]] || [[ "$2" == -* ]]; then
            echo "Error: Missing value for --node-version argument." >&2
            usage
        fi
        TARGET_NODE_REQ="$2"
        shift # past argument
        shift # past value
        ;;
    -h | --help)
        usage
        ;;
    *) # unknown option
        echo "Unknown option: $1"
        usage
        ;;
    esac
done

# Validate provided versions (simple check for number.number or number.number.number format)
if ! [[ "$TARGET_PYTHON_REQ" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: Invalid Python version format specified: '$TARGET_PYTHON_REQ'. Use format like '3.10' or '3.11.2'." >&2
    usage
fi
if ! [[ "$TARGET_NODE_REQ" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: Invalid Node.js version format specified: '$TARGET_NODE_REQ'. Use format like '16.0' or '18.14.1'." >&2
    usage
fi

# --- Main Script Logic ---

echo "Starting MCP environment setup/check (Linux)..."
echo "Using effective requirements: Python >= $TARGET_PYTHON_REQ, Node.js >= $TARGET_NODE_REQ"
echo "Script will exit immediately if any essential step fails (due to 'set -e')."

# 1. Detect Package Manager
detect_package_manager # Exits if unsupported

# 2. Update Package Lists (Crucial before installing anything)
echo "--- Updating Package Lists ($PKG_MANAGER) ---"
echo "Running: $PKG_UPDATE_CMD"
# Use eval to handle potential spaces in $PKG_UPDATE_CMD if SUDO_CMD was empty
if ! eval "$PKG_UPDATE_CMD"; then
    # Allow dnf/yum check-update non-zero exit code (100) if updates available
    if [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]] && [[ $? -eq 100 ]]; then
        echo "Info: Package manager indicates updates are available."
    else
        echo "Warning: Package list update command failed with exit code $?. Proceeding, but installations might fail..." >&2
        # Depending on strictness, you might want to exit here:
        # echo "ERROR: Package list update failed. Cannot proceed reliably." >&2
        # exit 1
    fi
else
    echo "Package lists updated successfully."
fi

# 3. Check/Install Python
# Uses TARGET_PYTHON_REQ defined earlier
check_install_python "$TARGET_PYTHON_REQ"
# check_install_python handles errors and exits or returns non-zero
# set -e will catch the exit/non-zero return

# 4. Check/Install Node.js
# Uses TARGET_NODE_REQ defined earlier
check_install_nodejs "$TARGET_NODE_REQ"
# check_install_nodejs also handles errors and exits or returns non-zero

# 5. Check/Install uv
install_uv
# install_uv also handles errors and exits or returns non-zero

# --- Final Summary ---
echo ""
echo "--------------------------------------------------"
echo "MCP environment setup/check completed successfully!"
echo "Required tools are available based on specified requirements:"
echo "  - Python (Required >= $TARGET_PYTHON_REQ)"
echo "  - Node.js (Required >= $TARGET_NODE_REQ)"
echo "  - uv"
echo "--------------------------------------------------"
echo "--- Verified Tool Information ---"
echo "Python:    ${FOUND_PYTHON_VERSION:-Not verified} (using command: ${FOUND_PYTHON_CMD:-N/A})"
echo "Node.js:   ${FOUND_NODE_VERSION:-Not verified} (using command: ${FOUND_NODE_CMD:-N/A})"
echo "uv:        ${FOUND_UV_VERSION:-Not verified} (using command: ${FOUND_UV_CMD:-N/A})"
echo "-----------------------------"

exit 0
