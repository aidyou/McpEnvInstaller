#!/bin/bash

# McpEnvInstall-Linux.sh
# Script to check and install development environment dependencies (Python, Node.js, uv)
# Supports Debian/Ubuntu (apt), Fedora/RHEL/CentOS (dnf/yum), Arch (pacman), OpenSUSE (zypper), Alpine (apk)

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
NODE_INSTALL_TARGET="nodejs" # Generic package name, version check is key

# --- Package Manager Variables (will be detected) ---
PKG_MANAGER=""
PKG_INSTALL_CMD=""
PKG_UPDATE_CMD=""
PKG_CHECK_INSTALLED_CMD="" # Command template to check if a package *is installed*
PYTHON_PIP_PKG=""
PYTHON_VENV_PKG="" # Base name, may be versioned or represent base python pkg
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
    if command -v sudo &> /dev/null; then
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

# Function to compare semantic versions (major.minor[.patch] >= major.minor[.patch])
# Handles versions like 3.10, 16.0, 18.14.1
compare_versions() {
    local ver1=$1
    local req=$2
    local IFS='.'

    # Pad versions like "16" to "16.0.0" for comparison consistency
    [[ $ver1 =~ \. ]] || ver1="${ver1}.0.0"
    [[ $req =~ \. ]] || req="${req}.0.0"
    # Ensure three parts for comparison
    local ver1_parts=($ver1)
    local req_parts=($req)
    ver1_parts[1]=${ver1_parts[1]:-0}
    ver1_parts[2]=${ver1_parts[2]:-0}
    req_parts[1]=${req_parts[1]:-0}
    req_parts[2]=${req_parts[2]:-0}

    # Compare Major
    if [[ ${ver1_parts[0]} -lt ${req_parts[0]} ]]; then return 1; fi
    if [[ ${ver1_parts[0]} -gt ${req_parts[0]} ]]; then return 0; fi

    # Compare Minor (if major is equal)
    if [[ ${ver1_parts[1]} -lt ${req_parts[1]} ]]; then return 1; fi
    if [[ ${ver1_parts[1]} -gt ${req_parts[1]} ]]; then return 0; fi

    # Compare Patch (if major and minor are equal)
    if [[ ${ver1_parts[2]} -lt ${req_parts[2]} ]]; then return 1; fi

    return 0 # Versions are equal or ver1 is greater
}


# Detect Linux package manager and set commands
detect_package_manager() {
    echo "--- Detecting Linux Package Manager ---"
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL_CMD="${SUDO_CMD} apt-get install -y"
        PKG_UPDATE_CMD="${SUDO_CMD} apt-get update"
        PKG_CHECK_INSTALLED_CMD='dpkg-query -W --showformat='\''${Status}'\'' ${pkg} 2>/dev/null | grep -q "install ok installed"'
        PYTHON_PIP_PKG="python3-pip"
        PYTHON_VENV_PKG="python3-venv" # Generic venv package for apt
        NODE_NPM_PKG="npm" # Often comes with nodejs, but good to list
        echo "Detected: Debian/Ubuntu (apt)"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL_CMD="${SUDO_CMD} dnf install -y"
        # Use '|| true' because check-update exits 100 if updates are available, which trips 'set -e'
        PKG_UPDATE_CMD="${SUDO_CMD} dnf check-update --assumeno || true"
        PKG_CHECK_INSTALLED_CMD='dnf list installed ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="python3-pip"
        PYTHON_VENV_PKG="python3-devel" # Often needed for headers/venv on RHEL-likes
        NODE_NPM_PKG="npm" # Usually nodejs-npm or part of nodejs package
        echo "Detected: Fedora/RHEL (dnf)"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL_CMD="${SUDO_CMD} yum install -y"
        # Use '|| true' because check-update exits 100 if updates are available
        PKG_UPDATE_CMD="${SUDO_CMD} yum check-update --assumeno || true"
        PKG_CHECK_INSTALLED_CMD='yum list installed ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="python3-pip"
        PYTHON_VENV_PKG="python3-devel" # Often needed for headers/venv on RHEL-likes
        NODE_NPM_PKG="npm" # Usually nodejs-npm or part of nodejs package
        echo "Detected: CentOS/RHEL (yum)"
    elif command -v pacman &> /dev/null; then # Arch Linux
        PKG_MANAGER="pacman"
        PKG_INSTALL_CMD="${SUDO_CMD} pacman -S --noconfirm"
        PKG_UPDATE_CMD="${SUDO_CMD} pacman -Sy"
        PKG_CHECK_INSTALLED_CMD='pacman -Q ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="python-pip"
        PYTHON_VENV_PKG="python" # venv is part of standard python package on Arch
        NODE_NPM_PKG="npm" # Comes with nodejs package
        echo "Detected: Arch Linux (pacman)"
    elif command -v zypper &> /dev/null; then # OpenSUSE
        PKG_MANAGER="zypper"
        # Added --no-recommends for potentially smaller installs
        PKG_INSTALL_CMD="${SUDO_CMD} zypper install -y --no-recommends"
        PKG_UPDATE_CMD="${SUDO_CMD} zypper refresh"
        # Check only installed packages
        PKG_CHECK_INSTALLED_CMD='zypper se --installed-only ${pkg} &>/dev/null'
        # Note: OpenSUSE Leap/Tumbleweed might have versioned python packages like python310-pip
        PYTHON_PIP_PKG="python3-pip" # Generic fallback
        PYTHON_VENV_PKG="python3-devel" # Often needed for venv/headers
        NODE_NPM_PKG="npm" # Usually nodejsXX-npm or part of nodejsXX package
        echo "Detected: OpenSUSE (zypper)"
    elif command -v apk &> /dev/null; then # Alpine Linux
        PKG_MANAGER="apk"
        # 'apk add' is often non-interactive enough, -y equivalent is implicit
        PKG_INSTALL_CMD="${SUDO_CMD} apk add"
        PKG_UPDATE_CMD="${SUDO_CMD} apk update"
        # Check if package exists and is installed
        PKG_CHECK_INSTALLED_CMD='apk info -e ${pkg} &>/dev/null'
        PYTHON_PIP_PKG="py3-pip" # Alpine uses py3- prefix often
        PYTHON_VENV_PKG="python3" # venv is part of standard python3 package on Alpine
        NODE_NPM_PKG="nodejs-npm" # Installs nodejs and npm
        echo "Detected: Alpine Linux (apk)"
    else
        # Updated error message to include apk
        echo "ERROR: Unsupported package manager. Supported managers: apt, dnf/yum, pacman, zypper, apk" >&2
        exit 1
    fi

    echo "Package manager setup complete. Using '$PKG_MANAGER'."
}

# Check if Python meets the required version, install via package manager if not.
check_install_python() {
    local required_version_str=$1
    local python_found=false
    local installed_python_pkg_ver="" # Track which python X.Y was installed

    echo "--- Checking Python ---"
    echo "Required version: >= ${required_version_str}"
    echo "Checking specific Python commands first (python3.14, python3.13...)"

    # Check common specific python executable names (adjust list as needed)
    local potential_pythons=("python3.14" "python3.13" "python3.12" "python3.11" "python3.10")

    for cmd in "${potential_pythons[@]}"; do
        local cmd_path
        if cmd_path=$(command -v "$cmd" 2>/dev/null); then
            echo "Found specific command: $cmd at $cmd_path"
            local version_output
            # Use [:3] to get major.minor.patch for better comparison potential
            if version_output=$("$cmd_path" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null); then
                echo "  Version reported by $cmd: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Version $version_output meets the requirement (>= $required_version_str)."
                        python_found=true
                        FOUND_PYTHON_VERSION=$version_output
                        FOUND_PYTHON_CMD=$cmd_path
                        break
                    else
                        echo "  Version $version_output does not meet the requirement."
                    fi
                else echo "  Warning: Could not parse version output '$version_output' from '$cmd'."; fi
            else echo "  Warning: Failed to execute '$cmd_path -c ...' to get version."; fi
        else echo "Specific command '$cmd' not found in PATH."; fi
    done

    # If no specific version was suitable, check the generic 'python3'
    if ! $python_found; then
        echo "No suitable specific Python command found. Checking generic 'python3'..."
        local python3_executable
        if ! python3_executable=$(command -v python3 2>/dev/null); then
            echo "Generic 'python3' command not found in PATH."
        else
            echo "Found generic python3 executable at: ${python3_executable}"
            local version_output
            if version_output=$(python3 -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null); then
                echo "  Version reported by python3: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Generic python3 version $version_output meets the requirement (>= $required_version_str)."
                        python_found=true
                        FOUND_PYTHON_VERSION=$version_output
                        FOUND_PYTHON_CMD=$python3_executable
                    else echo "  Generic python3 version ($version_output) is < $required_version_str."; fi
                else echo "  Warning: Could not parse version output '$version_output' from generic 'python3'."; fi
            else echo "  Warning: Failed to execute 'python3 -c ...' to get version."; fi
        fi
    fi

    # --- Decision Point: Check/Install Tools if Python Found ---
    if $python_found; then
        echo "Suitable Python found: $FOUND_PYTHON_CMD (Version: $FOUND_PYTHON_VERSION)"
        echo "Ensuring pip and venv tools are available for $FOUND_PYTHON_CMD..."
        local needs_install=()
        local venv_pkg_to_check_or_install="" # Determine the correct venv package name

        # Check pip module accessibility
        if ! "$FOUND_PYTHON_CMD" -m pip --version &>/dev/null; then
             echo "pip module not accessible via '$FOUND_PYTHON_CMD -m pip'."
             # Check if the package manager thinks the main pip package is installed
             local check_cmd_pip="${PKG_CHECK_INSTALLED_CMD/\$\{pkg\}/$PYTHON_PIP_PKG}"
             if ! eval "$check_cmd_pip"; then
                echo "'$PYTHON_PIP_PKG' package seems not installed."
                needs_install+=("$PYTHON_PIP_PKG")
             else
                 echo "'$PYTHON_PIP_PKG' package is installed, but module is not accessible. This might indicate a broken installation or PATH issue."
                 # Optionally add it to needs_install anyway to try reinstalling/fixing
                 # needs_install+=("$PYTHON_PIP_PKG")
             fi
        else
            echo "pip module is accessible."
        fi

        # Check venv module accessibility
        if ! "$FOUND_PYTHON_CMD" -c "import venv" &>/dev/null; then
             echo "venv module not importable via '$FOUND_PYTHON_CMD'."
             local py_ver_major_minor=$($FOUND_PYTHON_CMD -c "import sys; print('%s.%s' % sys.version_info[:2])")

             # Determine the likely venv package name based on package manager
             if [[ "$PKG_MANAGER" == "apt" ]]; then
                 local specific_venv_pkg="python${py_ver_major_minor}-venv"
                 local generic_venv_pkg="$PYTHON_VENV_PKG" # python3-venv
                 # Prefer specific if python command is versioned, otherwise generic
                 if [[ "$FOUND_PYTHON_CMD" =~ python3\.[0-9]+$ ]]; then
                    venv_pkg_to_check_or_install="$specific_venv_pkg"
                 else
                    venv_pkg_to_check_or_install="$generic_venv_pkg"
                 fi
                 # Check if the determined package is installed
                 local check_cmd_venv="${PKG_CHECK_INSTALLED_CMD/\$\{pkg\}/$venv_pkg_to_check_or_install}"
                 if ! eval "$check_cmd_venv"; then
                     echo "'$venv_pkg_to_check_or_install' package seems not installed."
                     needs_install+=("$venv_pkg_to_check_or_install")
                     # Also add the generic one for apt as a fallback? Sometimes needed.
                     if [[ "$venv_pkg_to_check_or_install" != "$generic_venv_pkg" ]]; then
                        local check_cmd_generic_venv="${PKG_CHECK_INSTALLED_CMD/\$\{pkg\}/$generic_venv_pkg}"
                        if ! eval "$check_cmd_generic_venv"; then needs_install+=("$generic_venv_pkg"); fi
                     fi
                 else
                    echo "'$venv_pkg_to_check_or_install' package is installed, but module not importable. Possible installation issue."
                 fi

             elif [[ "$PKG_MANAGER" == "pacman" || "$PKG_MANAGER" == "apk" ]]; then
                 # Venv is usually included with the base python package, check if base python is installed
                 venv_pkg_to_check_or_install="$PYTHON_VENV_PKG" # e.g., "python" or "python3"
                 local check_cmd_base="${PKG_CHECK_INSTALLED_CMD/\$\{pkg\}/$venv_pkg_to_check_or_install}"
                  if ! eval "$check_cmd_base"; then
                     echo "Base package '$venv_pkg_to_check_or_install' providing venv seems not installed."
                     needs_install+=("$venv_pkg_to_check_or_install") # Should be installed if python works, but check anyway
                  else
                     echo "Base package '$venv_pkg_to_check_or_install' is installed, but venv module not importable. Possible installation issue."
                  fi
             else # dnf/yum/zypper: python3-devel usually covers venv
                 venv_pkg_to_check_or_install="$PYTHON_VENV_PKG" # e.g. python3-devel
                 local check_cmd_devel="${PKG_CHECK_INSTALLED_CMD/\$\{pkg\}/$venv_pkg_to_check_or_install}"
                 if ! eval "$check_cmd_devel"; then
                     echo "'$venv_pkg_to_check_or_install' package providing venv seems not installed."
                     needs_install+=("$venv_pkg_to_check_or_install")
                 else
                     echo "'$venv_pkg_to_check_or_install' package is installed, but venv module not importable. Possible installation issue."
                 fi
             fi
        else
            echo "venv module is accessible."
        fi

        # Remove duplicates if any
        local unique_needs_install=($(echo "${needs_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        if [[ ${#unique_needs_install[@]} -gt 0 ]]; then
            echo "Attempting to install missing/required Python tools: ${unique_needs_install[*]}"
            # Package list update was done globally before this function
            if ! $PKG_INSTALL_CMD "${unique_needs_install[@]}"; then
                echo "ERROR: Failed to install required Python tools (${unique_needs_install[*]}). Cannot proceed reliably."
                return 1 # Exit if essential tools cannot be installed
            else
                 echo "Successfully installed Python tools."
                 # Re-verify essential tools after install attempt
                 if ! "$FOUND_PYTHON_CMD" -m pip --version &>/dev/null; then
                    echo "ERROR: pip module still not working after install attempt."
                    return 1
                 fi
                 if ! "$FOUND_PYTHON_CMD" -c "import venv" &>/dev/null; then
                    echo "ERROR: venv module still not working after install attempt."
                     # Give a hint for manual installation
                     echo "       You might need to manually install a package like '$venv_pkg_to_check_or_install' or consult your distribution's documentation."
                    return 1
                 fi
                 echo "Verified essential tools are now accessible."
            fi
        else
             echo "Required Python tools (pip, venv) seem to be installed and accessible."
        fi
        echo "Python check complete."
        return 0 # Success, existing Python is fine and tools are present/installed
    fi


    # --- Installation Block ---
    echo "No compatible Python version (>= $required_version_str) found or installed check failed."
    echo "Attempting to install Python using $PKG_MANAGER..."
    # Package list update is done globally before this function is called

    local installed_successfully=false
    # Try installing preferred versions first
    for py_ver in "${PYTHON_INSTALL_VERSIONS[@]}"; do
        # Check if this version is high enough
        if ! compare_versions "$py_ver.0" "$required_version_str"; then
            echo "Skipping attempt to install Python $py_ver (lower than required $required_version_str)."
            continue
        fi

        local python_pkg="python${py_ver}"
        # Determine required packages for this version
        local versioned_venv_pkg=""
        local versioned_pip_pkg="" # Usually not needed, generic is fine
        local base_python_for_venv=""

        if [[ "$PKG_MANAGER" == "apt" ]]; then
             versioned_venv_pkg="python${py_ver}-venv"
        elif [[ "$PKG_MANAGER" == "pacman" || "$PKG_MANAGER" == "apk" ]]; then
             base_python_for_venv="$PYTHON_VENV_PKG" # Base python provides venv
        else # dnf/yum/zypper
             # Try versioned devel first, e.g., python3.11-devel
             versioned_venv_pkg="python${py_ver}-devel"
             # Note: python3-devel (generic) might be the only one available
        fi

        # Always try installing generic pip and potentially generic venv/devel as well for safety/completeness
        local common_pkgs=("$PYTHON_PIP_PKG")
        # Add the *generic* venv/devel package if defined and different from base python pkg
        if [[ -n "$PYTHON_VENV_PKG" ]] && [[ "$PYTHON_VENV_PKG" != "$python_pkg" ]] && [[ "$PYTHON_VENV_PKG" != "$base_python_for_venv" ]]; then
             common_pkgs+=("$PYTHON_VENV_PKG")
        fi

        local packages_to_try=("$python_pkg")
        if [[ -n "$versioned_venv_pkg" ]]; then packages_to_try+=("$versioned_venv_pkg"); fi
        if [[ -n "$base_python_for_venv" ]]; then packages_to_try+=("$base_python_for_venv"); fi # Ensure base python for apk/pacman if targeting specific version
        packages_to_try+=("${common_pkgs[@]}")

        # Remove potential duplicates
        packages_to_try=($(echo "${packages_to_try[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        echo "Attempting to install Python $py_ver using packages: ${packages_to_try[*]}"
        # Use eval to handle potential spaces in $PKG_INSTALL_CMD if SUDO_CMD was empty
        if eval "$PKG_INSTALL_CMD ${packages_to_try[*]}"; then
            echo "Package installation command for Python $py_ver finished."
            # Verify the command and version
            local installed_cmd="python${py_ver}"
            local verified_cmd_path=""
            if verified_cmd_path=$(command -v "$installed_cmd" 2>/dev/null); then
                local version_output=$("$verified_cmd_path" -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null)
                if compare_versions "$version_output" "$required_version_str"; then
                    echo "Installed command '$installed_cmd' found (version $version_output) and meets requirement >= $required_version_str."
                    installed_successfully=true
                    FOUND_PYTHON_CMD=$verified_cmd_path
                    FOUND_PYTHON_VERSION=$version_output
                    # Ensure pip/venv work for this newly installed version NOW
                    if ! "$FOUND_PYTHON_CMD" -m pip --version &>/dev/null; then
                        echo "ERROR: pip module not working for newly installed $FOUND_PYTHON_CMD. Installation failed."
                        installed_successfully=false # Mark as failed
                    elif ! "$FOUND_PYTHON_CMD" -c "import venv" &>/dev/null; then
                        echo "ERROR: venv module not working for newly installed $FOUND_PYTHON_CMD. Installation failed."
                        installed_successfully=false # Mark as failed
                    else
                        echo "Verified pip and venv modules accessible for $FOUND_PYTHON_CMD."
                        break # SUCCESS: Stop trying versions
                    fi
                else
                    echo "Warning: Installed $python_pkg but command '$installed_cmd' version ($version_output) doesn't meet requirement >= $required_version_str."
                    # Do not mark as success, continue loop
                fi
            else
                echo "Warning: Installed package for $python_pkg, but command '$installed_cmd' not found in PATH. Checking generic python3..."
                 # Check if generic 'python3' now works AND meets criteria AND has tools
                 local generic_py3_path
                 if generic_py3_path=$(command -v python3 2>/dev/null); then
                      local py3_version_output=$($generic_py3_path -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null)
                      if compare_versions "$py3_version_output" "$required_version_str"; then
                          echo "Generic 'python3' (version $py3_version_output) is now available and meets requirement."
                          # Check tools for generic python3
                          if ! "$generic_py3_path" -m pip --version &>/dev/null; then
                              echo "Warning: pip module not working for generic python3 ($generic_py3_path)."
                          elif ! "$generic_py3_path" -c "import venv" &>/dev/null; then
                              echo "Warning: venv module not working for generic python3 ($generic_py3_path)."
                          else
                              echo "Verified pip and venv modules accessible for generic python3."
                              installed_successfully=true
                              FOUND_PYTHON_CMD=$generic_py3_path
                              FOUND_PYTHON_VERSION=$py3_version_output
                              break # SUCCESS: Stop trying versions
                          fi
                          # If tools didn't work for generic python3, don't mark as success, continue loop
                      else
                         echo "Generic 'python3' available but version ($py3_version_output) is < $required_version_str."
                      fi
                 else
                     echo "Generic 'python3' command still not found after installing $python_pkg."
                 fi
            fi
        else
            echo "Failed to install packages for Python $py_ver. Trying next available version."
            # Optionally add a small sleep here if hammering repositories
            # sleep 1
        fi
    done # End loop trying specific python versions

    # If specific versions failed, try the generic python3 as a last resort installation target
    if ! $installed_successfully; then
        echo "Could not install a specific Python version (${PYTHON_INSTALL_VERSIONS[*]})."
        echo "Attempting to install generic 'python3', '$PYTHON_PIP_PKG', and appropriate venv package..."

        local venv_pkg_generic=""
        if [[ "$PKG_MANAGER" == "apt" ]]; then venv_pkg_generic="$PYTHON_VENV_PKG"; # python3-venv
        elif [[ "$PKG_MANAGER" == "pacman" || "$PKG_MANAGER" == "apk" ]]; then venv_pkg_generic="$PYTHON_VENV_PKG"; # Base python package name
        else venv_pkg_generic="$PYTHON_VENV_PKG"; fi # python3-devel for RH/SUSE

        local generic_packages=("python3" "$PYTHON_PIP_PKG")
        # Only add venv package if it's not python3 itself (like in apk/pacman)
        if [[ "$venv_pkg_generic" != "python3" ]]; then
            generic_packages+=("$venv_pkg_generic")
        fi
        generic_packages=($(echo "${generic_packages[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        echo "Attempting to install generic packages: ${generic_packages[*]}"
        # Use eval for command execution
        if eval "$PKG_INSTALL_CMD ${generic_packages[*]}"; then
             echo "Successfully installed generic python3 and tool packages."
             # Verify generic python3 command and version
             local generic_py3_path
             if ! generic_py3_path=$(command -v python3 2>/dev/null); then
                 echo "ERROR: Installed python3 package, but 'python3' command not found in PATH."
                 # Keep installed_successfully=false
             else
                 local version_output=$($generic_py3_path -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null)
                 if compare_versions "$version_output" "$required_version_str"; then
                      echo "Installed generic python3 version ($version_output) meets requirement >= $required_version_str."
                      # Final check for pip and venv on this generic install
                      if ! "$generic_py3_path" -m pip --version &>/dev/null; then
                          echo "ERROR: pip module not working for installed generic python3."
                          # Keep installed_successfully=false
                      elif ! "$generic_py3_path" -c "import venv" &>/dev/null; then
                          echo "ERROR: venv module not working for installed generic python3."
                          # Keep installed_successfully=false
                      else
                          echo "Verified pip and venv accessible for installed generic python3."
                          installed_successfully=true
                          FOUND_PYTHON_CMD=$generic_py3_path
                          FOUND_PYTHON_VERSION=$version_output
                      fi
                 else
                      echo "ERROR: Installed generic python3 version ($version_output) is < $required_version_str."
                      # Keep installed_successfully=false
                 fi
             fi
        else
             echo "Error: Failed to install generic python3 and required tools."
             # Keep installed_successfully=false
        fi
    fi

    # Final check after all installation attempts
    if ! $installed_successfully; then
        echo "--------------------------------------------------"
        echo "ERROR: Failed to find or install a compatible Python version (>= $required_version_str) using $PKG_MANAGER."
        echo "Please install Python $required_version_str or newer manually."
        echo "Ensure 'python3' (or a versioned command like 'python3.11'), 'pip', and the 'venv' module are installed and accessible."
        echo "You might need to consult your distribution's documentation or use alternative installation methods (like pyenv or compiling from source)."
        echo "--------------------------------------------------"
        return 1 # Explicitly return failure status
    fi

    echo "Python check/installation complete."
    return 0
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
        if version_output=$( "$node_executable" --version 2>/dev/null ); then
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
        if ! command -v npm &> /dev/null; then
             echo "Warning: 'node' is compatible, but 'npm' command is missing."
             echo "Attempting to install npm package ('$NODE_NPM_PKG')..."
             # Use eval for command execution
             if ! eval "$PKG_INSTALL_CMD $NODE_NPM_PKG"; then
                  echo "ERROR: Failed to install '$NODE_NPM_PKG'. Node.js environment might be incomplete."
                  return 1 # Fail if npm install fails
             else
                  if ! command -v npm &> /dev/null; then
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
        # Verify installation
        if ! node_executable=$(command -v node 2>/dev/null); then
             echo "ERROR: Installed package(s) but 'node' command is still not found in PATH."
             return 1
        fi
        if ! command -v npm &> /dev/null; then
            echo "ERROR: Installed package(s) but 'npm' command is still not found in PATH."
             # Some systems might need a separate npm package even after installing nodejs
             if [[ "$NODE_NPM_PKG" != "npm" ]] && [[ "$PKG_MANAGER" != "apk" ]]; then # Avoid redundant install if npm was the target
                 echo "Attempting to install 'npm' package explicitly..."
                 if ! eval "$PKG_INSTALL_CMD npm"; then
                    echo "ERROR: Failed to install 'npm' explicitly."
                    return 1
                 elif ! command -v npm &> /dev/null; then
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
        if ! command -v uv &> /dev/null && [[ ":$PATH:" != *":$(dirname "$FOUND_UV_CMD"):"* ]]; then
             echo "Warning: The directory containing uv ('$(dirname "$FOUND_UV_CMD")') might not be in your active PATH."
             echo "         You may need to add it to your shell profile (e.g., ~/.bashrc, ~/.zshrc)."
        fi
        echo "uv check complete (already installed)."
        return 0
    fi

    echo "uv not found. Attempting to install uv using recommended curl | sh method..."
    # Ensure curl is available
    if ! command -v curl &> /dev/null; then
        echo "Attempting to install 'curl' using $PKG_MANAGER..."
        # Use eval for command execution
        if ! eval "$PKG_INSTALL_CMD curl"; then
            echo "ERROR: Failed to install 'curl'. Cannot download uv installer."
            echo "Please install curl manually (e.g., '$SUDO_CMD $PKG_MANAGER install curl') and re-run."
            return 1
        else
            echo "'curl' installed successfully."
            if ! command -v curl &> /dev/null; then
                 echo "ERROR: 'curl' installed but command not found? Cannot proceed."
                 return 1
            fi
        fi
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
                  if ! command -v uv &> /dev/null && [[ ":$PATH:" != *":$(dirname "$FOUND_UV_CMD"):"* ]]; then
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
        -h|--help)
        usage
        ;;
        *)    # unknown option
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