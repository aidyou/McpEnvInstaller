#!/bin/bash

# Strict mode
set -eo pipefail

# --- Default Minimum Versions ---
DEFAULT_PYTHON_REQ="3.10"
DEFAULT_NODE_REQ="16.0" # Specify minor as 0 for comparison

# --- Target Versions (will be set by defaults or args) ---
TARGET_PYTHON_REQ=""
TARGET_NODE_REQ=""

# --- Installation Targets (what brew will install if needed) ---
PYTHON_INSTALL_TARGET="python@3.12" # Preferred modern version to install
NODE_INSTALL_TARGET="node"          # Brew default (LTS)

# --- Helper Functions ---

# Function to normalize version string (remove suffixes and pad to X.Y format)
# Example: "3.12.0a1" -> "3.12", "18" -> "18.0"
normalize_version() {
    local version=$1
    # Remove any non-digit characters after version numbers
    version=$(echo "$version" | sed -E 's/([0-9]+\.[0-9]+).*/\1/; s/^([0-9]+)$/\1.0/')
    # Ensure we have at least major.minor format
    [[ $version =~ \.. ]] || version="${version}.0"
    echo "$version"
}

# Function to compare semantic versions (handles non-standard versions)
# Returns 0 if version1 >= version2, 1 otherwise
compare_versions() {
    local ver1=$(normalize_version "$1")
    local ver2=$(normalize_version "$2")
    local IFS='.'

    read -ra ver1_parts <<< "$ver1"
    read -ra ver2_parts <<< "$ver2"

    # Compare Major version
    if [[ ${ver1_parts[0]} -gt ${ver2_parts[0]} ]]; then
        return 0
    elif [[ ${ver1_parts[0]} -lt ${ver2_parts[0]} ]]; then
        return 1
    fi

    # Compare Minor version (if major versions are equal)
    # Use :-0 to handle cases where minor version might be missing
    if [[ ${ver1_parts[1]:-0} -ge ${ver2_parts[1]:-0} ]]; then
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

    echo "=== Python Environment Validation ==="
    echo "Required version: >= ${required_version_str}"
    echo "Checking specific Python versions first (e.g., python3.13, python3.12...)"

    # Check Python versions in descending order (newest first)
    local python_versions=("3.14" "3.13" "3.12" "3.11" "3.10")

    for version in "${python_versions[@]}"; do
        local cmd="python$version"
        local cmd_path
        if cmd_path=$(command -v "$cmd" 2>/dev/null); then
            echo "Found Python $version at $cmd_path"
            local version_output
            if version_output=$("$cmd_path" -c "import sys; print('%s.%s' % sys.version_info[:2])" 2>/dev/null); then
                echo "  Version: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Version $version_output meets requirement (>= $required_version_str)"
                        python_found=true
                        found_version=$version_output
                        found_cmd=$cmd_path
                        break
                    else
                        echo "  Version $version_output does not meet requirement"
                    fi
                else
                    echo "  Warning: Invalid version format '$version_output'"
                fi
            else
                echo "  Warning: Failed to get version from $cmd_path"
            fi
        fi
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
            if version_output=$("$python3_executable" -c "import sys; print('%s.%s' % sys.version_info[:2])" 2>/dev/null); then
                echo "  Version reported by python3: $version_output"
                if [[ "$version_output" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    if compare_versions "$version_output" "$required_version_str"; then
                        echo "  Generic python3 version $version_output meets the requirement (>= $required_version_str)."
                        python_found=true
                        found_version=$version_output
                        found_cmd=$python3_executable
                    else
                        echo "  Generic python3 version ($version_output) is < $required_version_str."
                    fi
                else
                    echo "  Warning: Could not parse version output '$version_output' from generic 'python3'."
                fi
            else
                local exit_status=$?
                echo "  Warning: Failed to execute '$python3_executable -c ...' to get version (Exit status: $exit_status)."
            fi
        fi
    fi

    # --- Decision Point ---
    if $python_found; then
        echo "Suitable Python found: $found_cmd (Version: $found_version)"
        return 0 # Success
    fi

    # --- Installation Block ---
    echo "No compatible Python version (>= $required_version_str) found or version check failed."
    echo "Attempting to ensure ${PYTHON_INSTALL_TARGET} is installed via Homebrew..."
    if ! command -v brew &> /dev/null; then
         echo "Error: Homebrew (brew) command not found, cannot install Python."
         return 1
    fi

    if brew list --versions "$PYTHON_INSTALL_TARGET" > /dev/null; then
        echo "${PYTHON_INSTALL_TARGET} is already managed by Homebrew."
        if ! brew info "$PYTHON_INSTALL_TARGET" | grep -q "is already installed and up-to-date"; then
             echo "Attempting brew upgrade/link for ${PYTHON_INSTALL_TARGET}..."
             if ! brew upgrade --fetch-HEAD "$PYTHON_INSTALL_TARGET"; then
                  echo "Warning: brew upgrade/link for ${PYTHON_INSTALL_TARGET} failed. Trying to proceed..."
             fi
        fi
    else
        echo "Attempting to install ${PYTHON_INSTALL_TARGET} using brew..."
        if ! brew install "$PYTHON_INSTALL_TARGET"; then
            echo "Error: Failed to install ${PYTHON_INSTALL_TARGET} using brew."
            return 1
        fi
        echo "${PYTHON_INSTALL_TARGET} installation successful."
    fi

    # --- Post-Install Verification ---
    echo "Verifying Python installation after brew operation..."
    local final_python_exec
    local verified_version=""
    local brew_prefix=$(brew --prefix "$PYTHON_INSTALL_TARGET")
    local specific_installed_cmd="$brew_prefix/bin/python${PYTHON_INSTALL_TARGET#python@}"

    if [[ -x "$specific_installed_cmd" ]]; then
        echo "Checking specific installed command: $specific_installed_cmd"
        if verified_version=$("$specific_installed_cmd" -c "import sys; print('%s.%s' % sys.version_info[:2])" 2>/dev/null); then
             if compare_versions "$verified_version" "$required_version_str"; then
                  echo "Verified specific installed Python version ($verified_version) meets requirement >= $required_version_str."
                  final_python_exec=$specific_installed_cmd
             else
                  echo "Warning: Specific installed Python version ($verified_version) seems incompatible (< $required_version_str)."
                  verified_version=""
             fi
        else
             echo "Warning: Failed to get version from specific installed command $specific_installed_cmd."
             verified_version=""
        fi
    else
        echo "Could not find specific installed command at $specific_installed_cmd. Will check generic 'python3'."
    fi

    if [[ -z "$final_python_exec" ]]; then
        if ! final_python_exec=$(command -v python3 2>/dev/null); then
            echo "Error: 'python3' command still not found in PATH after brew install/check."
            local brew_bin_dir=$(brew --prefix)/bin
            if [[ ! ":$PATH:" == *":$brew_bin_dir:"* ]]; then
                export PATH="$brew_bin_dir:$PATH"
                echo "Re-added Homebrew bin directory ($brew_bin_dir) to PATH."
                if ! final_python_exec=$(command -v python3 2>/dev/null); then
                    echo "Error: Still cannot find 'python3' even after PATH update."
                    return 1
                fi
            else
                echo "Error: Brew bin directory already in PATH, but python3 not found."
                return 1
            fi
        fi

        echo "Found python3 post-install at: ${final_python_exec}"
        if verified_version=$("$final_python_exec" -c "import sys; print('%s.%s' % sys.version_info[:2])" 2>/dev/null); then
             echo "Verified generic python3 version: $verified_version"
             if compare_versions "$verified_version" "$required_version_str"; then
                  echo "Installed/verified generic python3 version meets requirement >= $required_version_str."
             else
                  echo "Error: Installed generic python3 version ($verified_version) is incompatible (< $required_version_str)."
                  return 1
             fi
        else
             echo "Error: Failed to verify Python version using '$final_python_exec -c ...' even after installation attempt."
             return 1
        fi
    fi

    echo "Successfully verified a compatible Python environment post-installation."
    return 0 # Success
}


# Check if Node.js meets the required version, install LTS via Homebrew if not.
# Arguments:
#   $1: Required version string (e.g., "16.0", "18")
check_install_nodejs() {
    local required_version_str=$1
    local node_executable

    echo "=== Node.js Runtime Check ==="
    echo "Required version: >= ${required_version_str}"

    if ! node_executable=$(command -v node); then
        echo "node command not found in PATH."
    else
        echo "Found node executable at: ${node_executable}"
        local version_output
        if version_output=$("$node_executable" --version 2>/dev/null); then
             echo "Detected Node.js version string: $version_output"
             local version_numeric=${version_output#v}
             if [[ "$version_numeric" =~ ^[0-9]+\.[0-9]+ ]]; then
                 if compare_versions "$version_numeric" "$required_version_str"; then
                     echo "Found compatible Node.js version ($version_numeric) >= $required_version_str."
                     return 0 # Success
                 else
                     echo "Found Node.js version ($version_numeric) but it's < $required_version_str."
                 fi
             else
                 echo "Warning: Could not parse version output '$version_output' from '$node_executable'."
                 echo "Proceeding to ensure LTS version is installed."
             fi
        else
             local exit_status=$?
             echo "Warning: Failed to execute '$node_executable --version' to get version (Exit status: $exit_status)."
             echo "Proceeding to ensure LTS version is installed."
        fi
    fi

    # --- Installation Block ---
    echo "Compatible Node.js version not found or check failed. Attempting to install/update Node.js (LTS)..."
    if ! command -v brew &> /dev/null; then
         echo "Error: Homebrew (brew) command not found, cannot install Node.js."
         return 1
    fi

    echo "Attempting to install/update ${NODE_INSTALL_TARGET} using brew..."
    if brew install "$NODE_INSTALL_TARGET"; then
        echo "Node.js installation/update successful (or already up-to-date)."
        if ! command -v node &> /dev/null; then
             echo "Error: Installed/updated Node.js but 'node' command is still not found in PATH."
             local brew_prefix=$(brew --prefix)
             if [[ ! ":$PATH:" == *":$brew_prefix/bin:"* ]]; then
                 export PATH="$brew_prefix/bin:$PATH"
                 echo "Re-added Homebrew bin directory ($brew_prefix/bin) to PATH."
                 if ! command -v node &> /dev/null; then
                      echo "Error: Still cannot find 'node' after PATH update."
                      return 1
                 fi
             else
                 return 1
             fi
        fi
         echo "Verifying installed Node.js version..."
         local installed_version_output
         if installed_version_output=$(node --version 2>/dev/null); then
             local installed_numeric=${installed_version_output#v}
             echo "Verified Node.js version: $installed_numeric"
             if compare_versions "$installed_numeric" "$required_version_str"; then
                  echo "Installed Node.js version meets requirement >= $required_version_str."
                  return 0 # Success
             else
                  # This might happen if LTS is older than a specifically requested newer version
                  echo "Error: Installed Node.js version ($installed_numeric) is incompatible with the requirement (>= $required_version_str)."
                  return 1
             fi
         else
             echo "Error: Failed to verify Node.js version even after installation."
             return 1
         fi
    else
        echo "Error: Failed to install/update ${NODE_INSTALL_TARGET} using brew."
        return 1
    fi
}


# Check if uv is installed, install if not.
install_uv() {
    echo "=== UV Package Manager Setup ==="
    if command -v uv &> /dev/null; then
        echo "uv is already installed."
        local uv_path=$(command -v uv)
        echo "Found at: $uv_path"
        echo -n "uv version: "
        uv --version || echo "(failed to get version)"
        return 0
    fi

    echo "uv not found. Attempting to install uv using recommended curl | sh method..."
    if curl -LsSf https://astral.sh/uv/install.sh | sh; then
         echo "uv installation script finished."
         local uv_executable
         local cargo_bin="$HOME/.cargo/bin"
         if [[ -x "$cargo_bin/uv" ]]; then
             if [[ ! ":$PATH:" == *":$cargo_bin:"* ]]; then
                 echo "Adding $cargo_bin to PATH for this session."
                 export PATH="$cargo_bin:$PATH"
             fi
             if uv_executable=$(command -v uv); then
                  echo "uv installation successful and command found at $uv_executable."
                  echo -n "uv version: "
                  uv --version || echo "(failed to get version)"
                  return 0
             fi
         fi
         echo "Warning: uv installation script ran, but 'uv' command might not be in the current PATH."
         echo "Please ensure the directory mentioned by the installer (e.g., ~/.cargo/bin) is in your PATH."
         echo "You might need to restart your shell or run 'source ~/.bashrc', 'source ~/.zshrc', etc."
         if command -v uv &> /dev/null; then
             echo "Update: 'uv' command is now detectable."
             return 0
         else
             echo "Error: Could not automatically detect 'uv' command after installation."
             return 1
         fi
    else
         echo "Error: Failed to install uv using curl | sh method."
         return 1
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
            h) usage; return 0 ;;
            \?) echo "Invalid option: -$OPTARG" >&2; usage; return 1 ;;
            :) echo "Option -$OPTARG requires an argument." >&2; usage; return 1 ;;
        esac
    done
    shift $((OPTIND-1))

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

    # Check/install Homebrew
    echo "--- Checking/Installing Homebrew ---"
    if ! command -v brew &> /dev/null; then
        echo "Homebrew not detected. Attempting to install Homebrew..."
        if CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            echo "Homebrew installation completed successfully."
             local brew_path_prefix=""
             if [[ "$arch" == "arm64" ]] && [[ -d "/opt/homebrew" ]]; then brew_path_prefix="/opt/homebrew";
             elif [[ -d "/usr/local/Homebrew" ]]; then brew_path_prefix="/usr/local";
             elif [[ -d "/usr/local" ]]; then brew_path_prefix="/usr/local"; fi

             if [[ -n "$brew_path_prefix" ]] && [[ -x "$brew_path_prefix/bin/brew" ]]; then
                 local brew_bin_dir="$brew_path_prefix/bin"
                 echo "Adding Homebrew directory to PATH for this session: $brew_bin_dir"
                 export PATH="$brew_bin_dir:$PATH"
                 if command -v brew &> /dev/null; then echo "Homebrew installation successful and brew command found.";
                 else echo "Error: Homebrew installed but 'brew' command still not found in PATH. Setup may fail."; return 1; fi
             else echo "Error: Homebrew installed but brew executable not found in standard locations ($brew_path_prefix/bin). Setup may fail."; return 1; fi
        else echo "Error: Failed to install Homebrew. Cannot proceed reliably."; echo "Please install Homebrew manually: https://brew.sh/"; return 1; fi
    else
        echo "Homebrew is already installed."
         local brew_prefix=$(brew --prefix)
         local brew_bin_dir="$brew_prefix/bin"
         if [[ ! ":$PATH:" == *":$brew_bin_dir:"* ]]; then export PATH="$brew_bin_dir:$PATH"; echo "Ensured Homebrew bin directory ($brew_bin_dir) is in PATH.";
         else echo "Homebrew bin directory ($brew_bin_dir) is already in PATH."; fi
    fi
    echo "Homebrew check complete."
    echo "Current PATH: $PATH"


    # Check/install Python using the target requirement
    if ! check_install_python "$TARGET_PYTHON_REQ"; then
        echo "Python setup failed (Required >= $TARGET_PYTHON_REQ). Exiting."
        return 1
    fi
    echo "Python check/installation complete."

    # Check/install Node.js using the target requirement
    if ! check_install_nodejs "$TARGET_NODE_REQ"; then
        echo "Node.js setup failed (Required >= $TARGET_NODE_REQ). Exiting."
        return 1
    fi
    echo "Node.js check/installation complete."

    # Check/install uv
    if ! install_uv; then
        echo "uv setup failed. Exiting."
        return 1
    fi
    echo "uv check/installation complete."

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
    for cmd in "python3.13" "python3.12" "python3.11" "python3.10" "python3"; do
        if command -v "$cmd" &>/dev/null; then
             if display_py_version=$("$cmd" --version 2>&1); then
                 local num_ver; num_ver=$(echo "$display_py_version" | sed -n 's/^Python \([0-9]*\.[0-9]*\).*/\1/p')
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
        if command -v python3 &> /dev/null; then final_python_version=$(python3 --version 2>&1) || final_python_version="(python3 found but version check failed)"; fi
    fi
    echo "Python 3: $final_python_version"

    local final_node_version="Not found"
    if command -v node &> /dev/null; then final_node_version=$(node --version 2>&1) || final_node_version="(Version check command failed)"; fi
    echo "Node.js:   $final_node_version"

    local final_uv_version="Not found"
    if command -v uv &> /dev/null; then final_uv_version=$(uv --version 2>&1) || final_uv_version="(Version check command failed)"; fi
    echo "uv:        $final_uv_version"
    echo "----------------------------"
    echo "Final PATH used by script: $PATH"

    return 0
}

# --- Script Entry Point ---
# Call the main function and exit with its status code
main "$@" # Pass all command-line arguments to main
exit $?