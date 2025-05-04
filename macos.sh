#!/bin/bash

# Strict mode
set -eo pipefail

# --- Default Minimum Versions ---
DEFAULT_PYTHON_REQ="3.10"
DEFAULT_NODE_REQ="16.0" # Specify minor as 0 for comparison

# 3. Try Official Installer (Fallback, using a RECENT STABLE version)
#    This is attempted if package managers fail.
#    We use a hardcoded recent stable version known to have .pkg installers,
#    as older versions (like 3.10.12+) no longer provide them.
#    !! IMPORTANT: Update this version string periodically !!
#    Check https://www.python.org/downloads/macos/ for the latest stable .pkg
LATEST_STABLE_WITH_PKG_VERSION="3.13.3" # <-- UPDATE THIS periodically (e.g., "3.13.3")

# --- Target Versions (will be set by defaults or args) ---
TARGET_PYTHON_REQ=""
TARGET_NODE_REQ=""

# --- Installation Targets (what brew will install if needed) ---
PYTHON_INSTALL_TARGET="python@3.13" # Preferred modern version to install
NODE_INSTALL_TARGET="node"          # Brew default (LTS)

# --- Helper Functions ---

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

# --- Tool Check/Installation Functions ---

# Check if Python meets the required version, install via Homebrew if not.
# Arguments:
#   $1: Required version string (e.g., "3.10", "3.11")
check_install_python() {
    local required_version_str=$1
    local python_found=false
    local found_cmd=""
    local found_version=""

    # Helper function to find a compatible python executable
    _find_compatible_python() {
        local _req_ver=$1
        python_found=false # Reset global-like state for this function
        found_cmd=""
        found_version=""

        echo "Searching for existing compatible Python (>= $_req_ver)..."
        # Check specific versions first, descending order is often better
        local python_versions=("3.14" "3.13" "3.12" "3.11" "3.10")

        for version in "${python_versions[@]}"; do
            local cmd="python$version"
            local cmd_path
            if cmd_path=$(command -v "$cmd" 2>/dev/null); then
                echo "Checking found command: $cmd_path"
                local version_output
                echo "  Executing $cmd_path --version"
                if version_output=$($cmd_path --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); then
                    echo "  Raw version output: $version_output"
                    local major_minor=$(echo "$version_output" | cut -d. -f1-2)
                    if compare_versions "$version_output" "$_req_ver"; then
                        echo "  Version $version_output meets requirement (>= $_req_ver)"
                        python_found=true
                        found_version=$version_output # Store Major.Minor
                        found_cmd=$cmd_path
                        return 0 # Found a suitable specific version
                    fi
                else
                    echo "  Warning: Failed to get version from $cmd_path or timed out."
                fi
            fi
        done

        # Check generic 'python3' if no specific version was suitable
        echo "Checking generic 'python3'..."
        local python3_executable
        if python3_executable=$(command -v python3 2>/dev/null); then
            echo "Found generic python3 at: ${python3_executable}"
            local version_output
            # Extract Major.Minor only for comparison
            if version_output=$(timeout 5s "$python3_executable" -c "import sys; print('%s.%s' % sys.version_info[:2])" 2>/dev/null); then
                echo "  Reported version: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$_req_ver"; then
                        echo "  Generic python3 version $version_output meets requirement (>= $_req_ver)."
                        python_found=true
                        found_version=$version_output # Store Major.Minor
                        found_cmd=$python3_executable
                        return 0 # Found suitable generic python3
                    else
                        echo "  Generic python3 version ($version_output) is < $_req_ver."
                    fi
                fi
            else
                echo "  Warning: Failed to get version from generic python3 or timed out."
            fi
        else
            echo "Generic 'python3' command not found in PATH."
        fi

        # If we reached here, no suitable Python was found
        return 1
    }

    echo "=== Python Environment Validation ==="
    echo "Required version: >= ${required_version_str}"

    # --- Initial Check ---
    if _find_compatible_python "$required_version_str"; then
        echo "Requirement already met by: $found_cmd (Version: $found_version)"
        return 0 # Success, Python already installed and compatible
    fi

    # --- Installation Block ---
    echo "No compatible Python version found. Attempting installation..."
    local installed_successfully=false

    # Determine target versions for package managers based on required version
    local major_minor=$(echo "$required_version_str" | cut -d. -f1-2) # e.g., 3.10
    local major_minor_compact=$(echo "$major_minor" | tr -d '.')      # e.g., 310
    local python_target_brew="python@$major_minor"                    # e.g., python@3.10
    local python_target_macports="python$major_minor_compact"         # e.g., python310

    # --- Attempt Installation Methods ---

    # 1. Try Homebrew (Preferred)
    echo "--- Attempting via Package Manager ---"
    if command -v brew &>/dev/null; then
        echo "Homebrew found. Attempting to install/upgrade ${python_target_brew}..."
        # Note: Homebrew might install the latest patch for that minor (e.g., 3.10.14)
        # even if python.org doesn't provide a .pkg for it.
        # Update brew first? Optional, can take time. `brew update`
        if brew install "$python_target_brew"; then
            echo "Successfully installed/upgraded ${python_target_brew} via Homebrew."
            # Ensure brew links it if needed (install usually does this)
            # brew link --overwrite "$python_target_brew" # Usually not needed after install
            installed_successfully=true
        else
            echo "Homebrew installation/upgrade failed for ${python_target_brew}."
            echo "Trying latest Homebrew python..."
            if brew install python3; then # Try installing the latest python managed by brew
                echo "Successfully installed latest Homebrew Python (python3)."
                installed_successfully=true
            else
                echo "Failed to install latest Homebrew python (python3) as well."
            fi
        fi
    else
        echo "Homebrew (brew) command not found."
    fi

    # 2. Try MacPorts (if Homebrew failed or wasn't found)
    if ! $installed_successfully; then
        echo "--- Attempting via MacPorts ---"
        if command -v port &>/dev/null; then
            echo "MacPorts found. Attempting to install ${python_target_macports}..."
            echo "MacPorts requires sudo privileges for installation."
            if sudo port selfupdate && sudo port install "$python_target_macports"; then
                echo "Successfully installed ${python_target_macports} via MacPorts."
                # MacPorts usually puts things in /opt/local/bin, ensure this is in PATH?
                # The verification step should find it if PATH is correct.
                installed_successfully=true
            else
                echo "MacPorts installation failed for ${python_target_macports}."
                echo "Trying latest MacPorts python (python312 or python313 etc)..."
                # Try installing a recent major version known to MacPorts (e.g., python312)
                # This might need adjustment based on current MacPorts naming
                local latest_port_target="python313" # Adjust as needed
                echo "Attempting MacPorts install for ${latest_port_target}..."
                if sudo port install "${latest_port_target}"; then
                    echo "Successfully installed ${latest_port_target} via MacPorts."
                    installed_successfully=true
                else
                    echo "Failed to install ${latest_port_target} via MacPorts."
                fi
            fi
        else
            echo "MacPorts (port) command not found."
        fi
    fi

    if ! $installed_successfully; then
        echo "--- Attempting via Python.org Installer (using latest stable: ${LATEST_STABLE_WITH_PKG_VERSION}) ---"
        echo "Note: Versions like 3.10.12+ no longer have official .pkg installers."
        echo "We will try to install version ${LATEST_STABLE_WITH_PKG_VERSION} which should satisfy the >= ${required_version_str} requirement."

        # Check if the target version actually satisfies the requirement (sanity check)
        if ! compare_versions "$LATEST_STABLE_WITH_PKG_VERSION" "$required_version_str"; then
            echo "Error: The fallback official installer version (${LATEST_STABLE_WITH_PKG_VERSION}) is older than the required version (${required_version_str}). Cannot proceed with this method."
        elif ! command -v curl &>/dev/null; then
            echo "curl command not found. Cannot download the official installer."
        else
            # Construct URL for the known stable version
            local python_pkg_filename="python-${LATEST_STABLE_WITH_PKG_VERSION}-macos11.pkg" # Assumes macos11 universal2 pkg name convention
            local python_download_url="https://www.python.org/ftp/python/${LATEST_STABLE_WITH_PKG_VERSION}/${python_pkg_filename}"
            local download_path="/tmp/${python_pkg_filename}"

            echo "Downloading ${python_pkg_filename} from Python.org..."
            echo "URL: ${python_download_url}"
            # Follow redirects (-L), show progress (-#), fail on error (-f), output to file (-o)
            if curl -L -f -o "$download_path" "$python_download_url"; then
                echo "Download complete. Installing package (requires sudo)..."
                if sudo installer -pkg "$download_path" -target /; then
                    echo "Successfully installed Python ${LATEST_STABLE_WITH_PKG_VERSION} via official package."
                    # Official installer usually updates PATH or installs to standard locations.
                    installed_successfully=true
                else
                    echo "Error: Failed to install downloaded package using 'sudo installer'."
                fi
                echo "Cleaning up downloaded package..."
                rm -f "$download_path" # Use -f to avoid error if file doesn't exist
            else
                echo "Error: Failed to download Python package from $python_download_url."
                echo "Please check the URL (maybe the LATEST_STABLE_WITH_PKG_VERSION needs updating in the script?)"
                echo "and your internet connection."
            fi
        fi
    fi

    # --- Post-Installation Verification ---
    if ! $installed_successfully; then
        # Clean up temporary files
        if [[ -f "$download_path" ]]; then
            echo "Cleaning up temporary files..."
            rm -f "$download_path"
        fi

        # Reset environment variables
        unset HOMEBREW_PREFIX

        echo "-----------------------------------------------------"
        echo "Error: Failed to install Python using any available method (Homebrew, MacPorts, Official Installer)."
        echo "Please install Python ${required_version_str} or later manually and ensure it's available in your PATH."
        echo "You might need Xcode Command Line Tools ('xcode-select --install') for some methods."
        echo "For versions like 3.10.12+, manual installation might involve compiling from source if package managers don't provide it."
        echo "-----------------------------------------------------"
        return 1
    fi

    echo "Installation attempt finished. Re-verifying Python environment..."
    # Add a small delay in case PATH changes need a moment to propagate
    sleep 3
    # Re-run the check function; it uses the original required_version_str
    if _find_compatible_python "$required_version_str"; then
        echo "Successfully installed/found and verified a compatible Python environment: $found_cmd (Version: $found_version)"
        return 0 # Success
    else
        echo "-----------------------------------------------------"
        echo "Error: Python installation was attempted/reported successful, but still cannot find a compatible version (>= $required_version_str) in PATH after installation."
        echo "This might indicate a PATH configuration issue or the installed version wasn't linked correctly."
        echo "Please check your shell configuration (~/.zshrc, ~/.bash_profile, etc.) and ensure the directory containing the newly installed Python"
        echo "(e.g., /usr/local/bin, /opt/local/bin, /Library/Frameworks/Python.framework/Versions/Current/bin) is included in your PATH environment variable."
        echo "You may need to open a new terminal window or run 'source ~/.zshrc' (or equivalent) for PATH changes to take effect."
        echo "-----------------------------------------------------"
        return 1
    fi
}

# Check if Node.js meets the required version, install LTS via Homebrew if not.
# Arguments:
#   $1: Required version string (e.g., "16.0", "18")
check_install_nodejs() {
    local required_version_str=$1
    local node_executable
    local node_found=false
    local found_version=""

    echo "=== Node.js Runtime Validation ==="
    echo "Required version: >= ${required_version_str}"

    # --- Initial Check ---
    # Helper function to find and validate existing node
    _find_compatible_node() {
        node_found=false # Reset state
        found_version=""
        echo "Searching for existing compatible Node.js (>= $required_version_str)..."
        if node_executable=$(command -v node 2>/dev/null); then
            echo "Found node executable at: ${node_executable}"
            local version_output
            # Use timeout to prevent hangs
            if version_output=$($node_executable --version 2>/dev/null); then
                echo "  Detected Node.js version string: $version_output"
                local version_numeric=${version_output#v} # Remove leading 'v'
                # Basic validation of format
                if [[ "$version_numeric" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$version_numeric" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_numeric" "$required_version_str"; then
                        echo "  Version $version_numeric meets requirement (>= $required_version_str)."
                        node_found=true
                        found_version=$version_numeric
                        return 0 # Found compatible version
                    else
                        echo "  Found Node.js version ($version_numeric) but it's < $required_version_str."
                        return 1 # Found but incompatible
                    fi
                else
                    echo "  Warning: Could not parse version output '$version_output' into X.Y.Z format."
                    return 1 # Cannot determine compatibility
                fi
            else
                local exit_status=$?
                echo "  Warning: Failed to execute '$node_executable --version' (Exit status: $exit_status or timed out)."
                return 1 # Cannot determine compatibility
            fi
        else
            echo "node command not found in PATH."
            return 1 # Not found
        fi
    }

    if _find_compatible_node; then
        echo "Requirement already met by: $node_executable (Version: $found_version)"
        return 0 # Success, Node.js already installed and compatible
    fi

    # --- Installation Block ---
    echo "Compatible Node.js version not found or check failed. Attempting installation..."
    local installed_successfully=false
    # Let's target LTS by default for package managers
    local NODE_BREW_TARGET="node"   # Brew 'node' usually points to latest or LTS
    local NODE_PORT_TARGET="nodejs" # MacPorts often uses 'nodejs' or 'nodejsXY' (e.g. nodejs20)

    # 1. Try Homebrew
    echo "--- Attempting via Package Manager ---"
    if command -v brew &>/dev/null; then
        echo "Homebrew found. Attempting to install/update ${NODE_BREW_TARGET}..."
        # Update brew first? Optional: brew update
        if brew install "$NODE_BREW_TARGET"; then
            echo "Successfully installed/updated ${NODE_BREW_TARGET} via Homebrew."
            # Ensure brew links it if needed (install usually does)
            # brew link --overwrite "$NODE_BREW_TARGET" # Usually not needed
            installed_successfully=true
        else
            echo "Homebrew installation/update failed for ${NODE_BREW_TARGET}."
        fi
    else
        echo "Homebrew (brew) command not found."
    fi

    # 2. Try MacPorts (if Homebrew failed or wasn't found)
    if ! $installed_successfully; then
        echo "--- Attempting via MacPorts ---"
        if command -v port &>/dev/null; then
            echo "MacPorts found. Attempting to install ${NODE_PORT_TARGET}..."
            echo "MacPorts requires sudo privileges for installation."
            # Update ports first? Optional: sudo port selfupdate
            if sudo port install "$NODE_PORT_TARGET"; then
                echo "Successfully installed ${NODE_PORT_TARGET} via MacPorts."
                # MacPorts usually puts things in /opt/local/bin
                installed_successfully=true
            else
                echo "MacPorts installation failed for ${NODE_PORT_TARGET}."
                # Optional: Could try installing a specific LTS version like 'nodejs20' if 'nodejs' fails
            fi
        else
            echo "MacPorts (port) command not found."
        fi
    fi

    # 3. Try FNM (Fast Node Manager) as a last resort
    if ! $installed_successfully; then
        echo "--- Attempting via FNM (Fast Node Manager) ---"
        if ! command -v curl &>/dev/null; then
            echo "Error: curl command not found. Cannot download fnm installer."
        else
            echo "Downloading and running fnm installer..."
            # Execute the installer. It modifies shell config files but doesn't affect the current session directly.
            if curl -fsSL https://fnm.vercel.app/install | bash; then
                echo "FNM installer script executed."

                # FNM needs its environment sourced to be usable in the *current* script session.
                # Common install location is $HOME/.fnm
                # We need to add fnm to PATH and evaluate its environment setup.
                FNM_DIR="${HOME}/.fnm"
                PATH="${FNM_DIR}:${PATH}"
                export PATH

                # Check if fnm command is now available
                if ! command -v fnm &>/dev/null; then
                    echo "Error: fnm command not found even after installation script. PATH might be wrong or install failed silently."
                    echo "Expected fnm location: ${FNM_DIR}"
                else
                    echo "FNM command found. Setting up FNM environment for this session..."
                    # This command loads fnm functions and sets PATHs for Node installations
                    # The exact command might depend on the shell, but this is common:
                    # Trying to be robust for bash/zsh
                    eval "$(fnm env --use-on-cd)"

                    # Now, attempt to install Node.js LTS using fnm
                    echo "Attempting to install Node.js LTS using fnm..."
                    # Let's install LTS by default. Replace 'lts' with required_version_str if needed,
                    # but fnm might not support partial versions like "18.12". LTS is safer.
                    local fnm_install_version="lts"
                    echo "Targeting FNM version: ${fnm_install_version}"

                    if fnm install "$fnm_install_version"; then
                        echo "Successfully installed Node.js ${fnm_install_version} via fnm."
                        # Optionally set it as default for future sessions
                        # fnm alias default "$fnm_install_version"
                        # Use the installed version in the current session
                        fnm use "$fnm_install_version"
                        installed_successfully=true
                    else
                        echo "Error: fnm failed to install Node.js version ${fnm_install_version}."
                    fi
                fi
            else
                echo "Error: Failed to download or execute the fnm installer script."
            fi
        fi
    fi

    # --- Post-Installation Verification ---
    if ! $installed_successfully; then
        echo "-----------------------------------------------------"
        echo "Error: Failed to install Node.js using any available method (Homebrew, MacPorts, FNM)."
        echo "Please install Node.js ${required_version_str} or later manually and ensure 'node' is available in your PATH."
        echo "You might need Xcode Command Line Tools ('xcode-select --install') for Homebrew/MacPorts."
        echo "-----------------------------------------------------"
        return 1
    fi

    echo "Installation attempt finished. Re-verifying Node.js environment..."
    # Add a small delay, especially important after fnm setup
    sleep 3
    if _find_compatible_node; then
        echo "Successfully installed/found and verified a compatible Node.js environment: $(command -v node) (Version: $found_version)"
        return 0 # Success
    else
        echo "-----------------------------------------------------"
        echo "Error: Node.js installation was attempted/reported successful, but still cannot find a compatible version (>= $required_version_str) in PATH after installation."
        echo "This might indicate a PATH configuration issue or the wrong version was installed/activated."
        echo "If FNM was used, you might need to run 'eval \"\$(fnm env --use-on-cd)\"' in your shell or restart your terminal."
        echo "Please check your shell configuration (~/.zshrc, ~/.bash_profile, etc.) and ensure the correct Node.js bin directory is in your PATH."
        echo "Relevant paths might be: /usr/local/bin (Brew), /opt/local/bin (MacPorts), $HOME/.fnm/node-versions/<version>/installation/bin (FNM)"
        echo "-----------------------------------------------------"
        return 1
    fi
}

# Check if uv is installed, install if not.
install_uv() {
    echo "=== UV Package Manager Setup ==="

    # --- Initial Check ---
    if command -v uv &>/dev/null; then
        echo "uv command found."
        local uv_path=$(command -v uv)
        echo "  Location: $uv_path"
        echo -n "  Version: "
        uv --version || echo "(failed to get version)"
        echo "uv is already installed and accessible."
        return 0
    fi

    echo "uv command not found. Attempting installation..."
    local installed_successfully=false
    local install_method="unknown"
    local potential_bin_path="" # Store the likely bin directory

    # --- Installation Attempts ---

    # 1. Try Homebrew
    echo "--- Attempting via Package Manager ---"
    if command -v brew &>/dev/null; then
        echo "Homebrew found. Attempting to install uv..."
        local brew_prefix # Get brew prefix for path finding
        if brew_prefix=$(brew --prefix); then
            potential_bin_path="${brew_prefix}/bin"
            if brew install uv; then
                echo "Successfully installed uv via Homebrew."
                installed_successfully=true
                install_method="brew"
                # Keep potential_bin_path
            else
                echo "Homebrew installation failed for uv."
                potential_bin_path="" # Reset on failure
            fi
        else
            echo "Warning: Could not determine Homebrew prefix. Cannot reliably predict PATH."
            potential_bin_path=""
        fi
    else
        echo "Homebrew (brew) command not found."
    fi

    # 2. Try MacPorts (if Homebrew failed or wasn't found)
    if ! $installed_successfully; then
        echo "--- Attempting via MacPorts ---"
        if command -v port &>/dev/null; then
            echo "MacPorts found. Attempting to install uv..."
            echo "MacPorts requires sudo privileges for installation."
            potential_bin_path="/opt/local/bin" # Standard MacPorts path
            if sudo port install uv; then
                echo "Successfully installed uv via MacPorts."
                installed_successfully=true
                install_method="macports"
                # Keep potential_bin_path
            else
                echo "MacPorts installation failed for uv."
                potential_bin_path="" # Reset on failure
            fi
        else
            echo "MacPorts (port) command not found."
        fi
    fi

    # 3. Try Official Install Script (if package managers failed or weren't found)
    if ! $installed_successfully; then
        echo "--- Attempting via Official Install Script (astral.sh) ---"
        if ! command -v curl &>/dev/null; then
            echo "Error: curl command not found. Cannot use the official install script."
        else
            echo "Running the official uv installer script..."
            potential_bin_path="$HOME/.cargo/bin" # Standard cargo path
            if curl -LsSf https://astral.sh/uv/install.sh | sh; then
                echo "Official uv installation script finished execution."
                # Verify the executable exists in the expected path
                if [[ -x "$potential_bin_path/uv" ]]; then
                    echo "Successfully installed uv via official script. Executable found in $potential_bin_path."
                    installed_successfully=true
                    install_method="script"
                    # Keep potential_bin_path
                else
                    echo "Warning: Official script ran, but uv executable was not found in the expected location ($potential_bin_path)."
                    potential_bin_path="" # Reset as we are unsure
                fi
            else
                echo "Error: Failed to download or execute the official uv install script."
                potential_bin_path="" # Reset on failure
            fi
        fi
    fi

    # 4. Try Pip (as a last resort)
    # Note: Determining pip's install location automatically is complex (depends on user/system/venv).
    # We won't automatically determine potential_bin_path for pip easily here.
    # If pip is the only method that works, the auto-path fix might not trigger.
    if ! $installed_successfully; then
        echo "--- Attempting via pip ---"
        local python_exe
        if python_exe=$(command -v python3 || command -v python); then
            echo "Found Python executable: $python_exe. Attempting 'pip install uv'..."
            # Try user install first as it's often safer and doesn't need sudo
            if "$python_exe" -m pip install --user uv; then
                echo "Successfully installed uv via pip (user)."
                installed_successfully=true
                install_method="pip_user"
                potential_bin_path="$HOME/.local/bin" # Common location for --user installs
            elif "$python_exe" -m pip install uv; then
                # If user install fails, try system (might need sudo, might fail)
                echo "Successfully installed uv via pip (system)."
                installed_successfully=true
                install_method="pip_system"
                potential_bin_path="" # Hard to predict system bin path reliably
            else
                echo "Error: Failed to install uv using '$python_exe -m pip install uv'."
                echo "You might need sudo privileges or need to install/upgrade pip itself."
                potential_bin_path=""
            fi
        else
            echo "Python (python3 or python) command not found. Cannot attempt pip installation."
        fi
    fi

    # --- Post-Installation Verification ---
    if ! $installed_successfully; then
        echo "-----------------------------------------------------"
        echo "[Error] Failed to install uv using any available method (Homebrew, MacPorts, Official Script, pip)."
        echo "Please install uv manually: https://github.com/astral-sh/uv#installation"
        echo "Ensure the 'uv' command is available in your PATH."
        echo "-----------------------------------------------------"
        return 1
    fi

    echo "Installation attempt finished. Verifying uv command availability..."
    # Add a small delay in case PATH changes need a moment
    sleep 1
    if command -v uv &>/dev/null; then
        local final_uv_path=$(command -v uv)
        echo "Successfully installed and verified uv."
        echo "  Location: $final_uv_path"
        echo -n "  Version: "
        uv --version || echo "(failed to get version)"
        return 0 # Success
    else
        # --- Automatic PATH Fix Attempt ---
        echo "-----------------------------------------------------"
        echo "[Warning] uv installation reported successful (method: $install_method), but the 'uv' command is still not found in the current PATH."

        if [[ -n "$potential_bin_path" ]]; then
            echo "Attempting to temporarily add the likely directory ($potential_bin_path) to PATH for this session..."
            if [[ -d "$potential_bin_path" ]]; then
                if [[ ":$PATH:" != *":$potential_bin_path:"* ]]; then
                    export PATH="$potential_bin_path:$PATH"
                    echo "Added $potential_bin_path to the beginning of PATH."

                    # Re-check after modifying PATH
                    sleep 1
                    if command -v uv &>/dev/null; then
                        local now_found_path=$(command -v uv)
                        echo "[Success] The 'uv' command is now working in this session ($now_found_path)."
                        echo "           Version: $(uv --version || echo '(failed to get version)')"
                        echo ""
                        echo "           ---------------------------------------------------------"
                        echo "           IMPORTANT: This PATH change is temporary!"
                        echo "           To make 'uv' available in future terminal sessions,"
                        echo "           you need to add the following line to your shell"
                        echo "           configuration file (e.g., ~/.zshrc, ~/.bash_profile):"
                        echo ""
                        # Escape $PATH for the user message
                        echo "               export PATH=\"$potential_bin_path:\$PATH\""
                        echo ""
                        echo "           After adding the line, restart your terminal or run:"
                        echo "               source ~/.your_shell_config_file"
                        echo "           ---------------------------------------------------------"
                        # Return 0 because the command is now usable for the rest of *this* script
                        return 0
                    else
                        echo "[Error] Even after adding $potential_bin_path to PATH, the 'uv' command could not be found."
                        echo "There might be an issue with the installation in that directory or another PATH problem."
                    fi
                else
                    echo "[Info] The directory $potential_bin_path is already in your PATH."
                    echo "The issue might be different (e.g., permissions, corrupted install)."
                fi
            else
                echo "[Warning] The predicted directory $potential_bin_path does not exist. Cannot add it to PATH."
            fi
        else
            echo "Could not determine the likely installation directory for method '$install_method'."
            echo "Cannot attempt automatic PATH configuration."
        fi

        # If we reach here, the automatic fix didn't work or wasn't possible.
        echo ""
        echo "[Action Required] Manual PATH configuration needed."
        echo "Please ensure the directory containing the 'uv' executable is in your PATH."
        echo "Common locations based on potential install methods:"
        echo "  - Homebrew: $(brew --prefix 2>/dev/null || echo '/usr/local or /opt/homebrew')/bin"
        echo "  - MacPorts: /opt/local/bin"
        echo "  - Official Script/Cargo: $HOME/.cargo/bin"
        echo "  - Pip (user install): $HOME/.local/bin"
        echo "  - Pip (system install): Python's system bin directory (varies)"
        echo ""
        echo "Check your shell configuration (~/.zshrc, ~/.bash_profile, etc.)."
        echo "You may need to open a new terminal window or run 'source ~/.your_shell_rc' after fixing the PATH."
        echo "-----------------------------------------------------"
        return 1 # Indicate failure requiring manual intervention
    fi
}

# --- Usage Message ---
usage() {
    echo "Usage: $0 [-p <python_version>] [-n <node_version>] [-h]"
    echo ""
    echo "Checks and installs required tools (Python, Node.js, uv) for the MCP environment on macOS."
    echo ""
    echo "Options:"
    echo "  -p <version>  Specify the minimum required Python version (e.g., '3.11')."
    echo "                Defaults to ${DEFAULT_PYTHON_REQ}."
    echo "                If installation is needed, ${PYTHON_INSTALL_TARGET} will be installed via Homebrew."
    echo "  -n <version>  Specify the minimum required Node.js version (e.g., '18', '18.0')."
    echo "                Defaults to ${DEFAULT_NODE_REQ}."
    echo "                If installation is needed, the latest LTS Node.js will be installed via Homebrew."
    echo "  -h            Display this help message and exit."
    echo ""
    echo "Example: $0 -p 3.11 -n 18"
}

# --- Main Function ---
main() {
    # Parse command-line options
    TARGET_PYTHON_REQ=$DEFAULT_PYTHON_REQ
    TARGET_NODE_REQ=$DEFAULT_NODE_REQ

    while getopts "p:n:h" opt; do
        case $opt in
        p) TARGET_PYTHON_REQ="$OPTARG" ;;
        n) TARGET_NODE_REQ="$OPTARG" ;;
        h)
            usage
            return 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            return 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            return 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    # Basic validation for version format (allow X.Y or just X for Node)
    if ! [[ "$TARGET_PYTHON_REQ" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
        echo "Error: Invalid Python version format specified: '$TARGET_PYTHON_REQ'. Use format like '3.10'." >&2
        usage
        return 1
    fi
    if ! [[ "$TARGET_NODE_REQ" =~ ^[0-9]+(\.[0-9]+([.][0-9]+)?)?$ ]]; then
        echo "Error: Invalid Node.js version format specified: '$TARGET_NODE_REQ'. Use format like '16' or '16.0'." >&2
        usage
        return 1
    fi

    echo "Starting MCP environment setup/check (macOS)..."
    echo "Using effective requirements: Python >= ${TARGET_PYTHON_REQ}, Node.js >= ${TARGET_NODE_REQ}"
    echo "Script will exit immediately if any essential step fails."
    echo "Checking system architecture..."
    local arch=$(uname -m)
    echo "Detected architecture: $arch"
    echo ""

    # Check/install Homebrew
    echo "=== Checking/Installing Package Manager ==="
    if ! command -v brew &>/dev/null && ! command -v port &>/dev/null; then
        echo "Neither Homebrew nor MacPorts detected. Attempting to install Homebrew..."
        if CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            echo "Homebrew installation completed successfully."
            local brew_path_prefix=""
            if [[ "$arch" == "arm64" ]] && [[ -d "/opt/homebrew" ]]; then
                brew_path_prefix="/opt/homebrew"
            elif [[ -d "/usr/local/Homebrew" ]]; then
                brew_path_prefix="/usr/local"
            elif [[ -d "/usr/local" ]]; then brew_path_prefix="/usr/local"; fi

            if [[ -n "$brew_path_prefix" ]] && [[ -x "$brew_path_prefix/bin/brew" ]]; then
                local brew_bin_dir="$brew_path_prefix/bin"
                echo "Adding Homebrew directory to PATH for this session: $brew_bin_dir"
                export PATH="$brew_bin_dir:$PATH"
                if command -v brew &>/dev/null; then
                    echo "Homebrew installation successful and brew command found."
                else
                    echo "Error: Homebrew installed but 'brew' command still not found in PATH. Setup may fail."
                    return 1
                fi
            else
                echo "Error: Homebrew installed but brew executable not found in standard locations ($brew_path_prefix/bin). Setup may fail."
                return 1
            fi
        else
            echo "Error: Failed to install Homebrew. Cannot proceed reliably."
            echo "Please install Homebrew manually: https://brew.sh/"
            return 1
        fi
    else
        echo "Homebrew is already installed."
        local brew_prefix=$(brew --prefix)
        local brew_bin_dir="$brew_prefix/bin"
        # 通用路径处理逻辑
        declare -a package_paths=(
            "$brew_bin_dir"     # Homebrew路径
            "/opt/local/bin"    # MacPorts默认路径
            "/opt/homebrew/bin" # M1 Homebrew备用路径
        )

        for pkg_path in "${package_paths[@]}"; do
            if [[ -d "$pkg_path" && ! ":$PATH:" == *":$pkg_path:"* ]]; then
                export PATH="$pkg_path:$PATH"
                echo "Added package manager path: $pkg_path"
            fi
        done
        echo "Package Manager bin directory ($brew_bin_dir) is already in PATH."
    fi
    echo "Homebrew check complete."
    echo ""
    # echo "Current PATH: $PATH"

    # Check/install Python using the target requirement
    if ! check_install_python "$TARGET_PYTHON_REQ"; then
        echo "Python setup failed (Required >= $TARGET_PYTHON_REQ). Exiting."
        return 1
    fi
    echo "Python check/installation complete."
    echo ""

    # Check/install Node.js using the target requirement
    if ! check_install_nodejs "$TARGET_NODE_REQ"; then
        echo "Node.js setup failed (Required >= $TARGET_NODE_REQ). Exiting."
        return 1
    fi
    echo "Node.js check/installation complete."
    echo ""

    # Check/install uv
    if ! install_uv; then
        echo "uv setup failed. Exiting."
        echo ""
        return 1
    fi
    echo "uv check/installation complete."
    echo ""

    # --- Final Summary ---
    echo ""
    echo "--------------------------------------------------"
    echo "MCP environment setup/check completed successfully!"
    echo "Required tools are available based on specified or default minimums:"
    echo "  - Python (Required >= ${TARGET_PYTHON_REQ})"
    echo "  - Node.js (Required >= ${TARGET_NODE_REQ})"
    echo "  - uv"
    echo "--------------------------------------------------"

    # Display final versions found
    echo "--- Verified Tool Versions ---"
    local final_python_version="Not found or check failed"
    local display_python_cmd="python3"
    local display_py_version=""
    for cmd in "python3.14" "python3.13" "python3.12" "python3.11" "python3.10" "python3"; do
        if command -v "$cmd" &>/dev/null; then
            if display_py_version=$("$cmd" --version 2>&1); then
                local num_ver
                num_ver=$(echo "$display_py_version" | sed -n 's/^Python \([0-9]*\.[0-9]*\).*/\1/p')
                if [[ -n "$num_ver" ]] && compare_versions "$num_ver" "$TARGET_PYTHON_REQ"; then
                    final_python_version="$display_py_version (using $cmd)"
                    break
                elif [[ "$final_python_version" == "Not found or check failed" ]]; then
                    final_python_version="$display_py_version (using $cmd, may not meet minimum)"
                fi
            fi
        fi
    done
    if [[ "$final_python_version" == "Not found or check failed" ]]; then
        if command -v python3 &>/dev/null; then final_python_version=$(python3 --version 2>&1) || final_python_version="(python3 found but version check failed)"; fi
    fi
    echo "Python 3: $final_python_version"

    local final_node_version="Not found"
    if command -v node &>/dev/null; then final_node_version=$(node --version 2>&1) || final_node_version="(Version check command failed)"; fi
    echo "Node.js:   $final_node_version"

    local final_uv_version="Not found"
    if command -v uv &>/dev/null; then final_uv_version=$(uv --version 2>&1) || final_uv_version="(Version check command failed)"; fi
    echo "uv:        $final_uv_version"
    echo "----------------------------"
    echo "Final PATH used by script: $PATH"
    echo ""
    echo "-----------------------------"
    echo "Note: You may need to restart your shell or run the following command to apply PATH changes:"
    echo "      For bash: source ~/.bashrc"
    echo "      For zsh: source ~/.zshrc"
    echo "      Alternatively, open a new terminal."
    echo "-----------------------------"

    return 0
}

# --- Script Entry Point ---
# Call the main function and exit with its status code
main "$@" # Pass all command-line arguments to main
exit $?
