# McpEnvInstaller

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

English | [简体中文](README-ZH.md)

[McpEnvInstaller](https://github.com/aidyou/McpEnvInstaller) is a cross-platform script toolset for automating the deployment of the **MCP (Model Context Protocol)** runtime environment.

> MCP is an open protocol that standardizes how applications provide context to LLMs. Think of MCP like a USB-C port for AI applications. Just as USB-C provides a standardized way to connect your devices to various peripherals and accessories, MCP provides a standardized way to connect AI models to different data sources and tools. For more information about MCP, please visit [https://modelcontextprotocol.io/introduction](https://modelcontextprotocol.io/introduction)

## ✨ Project Description

This project is dedicated to simplifying and automating the complex process of setting up the MCP runtime environment across different operating systems.

The MCP STDIO protocol allows interaction with local programs via standard input and output, and typically relies on two command-line tools:

* `uvx`: Used for quickly executing command-line tools or entry points provided by Python packages installed via uv or pip, often in isolated environments.
* `npx`: Used for easily running command-line tools installed via the Node.js package manager (`npm`), without requiring global installation.

The proper functioning of these executors (`uvx` and `npx`) depends on their respective runtime foundations: the Python tools executed by `uvx` require a **Python runtime**, while `npx` and the Node.js tools it executes require a **Node.js runtime**

Therefore, the core objective of this project is to detect, install, and configure the following key dependencies required for the MCP environment:

* **Python**: Provides the necessary Python runtime environment.
* **uv**: Serves as a high-performance Python package manager and provides the `uvx` executor.
* **Node.js**: Provides the Node.js runtime environment and includes the `npx` tool.

To ensure that most MCP projects and other libraries they depend on (such as crawl4ai) can function correctly, using Python **3.10 or higher** is **strongly recommended**. Please note that while `uv` itself does not run *on* Python, adhering to this recommendation is advised for compatibility with commonly used libraries in the ecosystem and for a better development experience.

Similarly, to ensure good compatibility with tools and applications within the MCP ecosystem, we also **recommend** using Node.js **LTS 16.0 or higher**.

By running the corresponding platform scripts, these dependencies can be automatically detected and installed, allowing for rapid construction of the MCP runtime environment.

## Supported Operating Systems and Architectures

| Operating System                 | Architecture          | Support Status      | Test Environment                                              |
| :------------------------------- | :-------------------- | :------------------ | :------------------------------------------------------------ |
| macOS                            | AMD64 (Intel)         | ✅ Supported / Tested | GitHub Workflow                                              |
| macOS                            | ARM64 (Apple Silicon) | ✅ Supported / Tested | macOS M1 15.4.1, GitHub Workflow                              |
| Windows                          | AMD64                 | ✅ Supported / Tested | Windows 2019, Windows 11, GitHub Workflow: 2019, 2022        |
| Windows                          | ARM64                 | ✅ Supported / Tested | Windows 11                                                   |
| Linux (Red Hat-based)            | AMD64 (x86_64)        | ✅ Supported / Tested | GitHub Workflow Docker: Rockylinux 9                          |
| Linux (Red Hat-based)            | ARM64 (aarch64)       | ✅ Supported / Tested | Fedora 38, Openeuler25                                       |
| Linux (Debian-based)             | AMD64 (x86_64)        | ✅ Supported / Tested | Ubuntu 24, GitHub Workflow: Ubuntu 24, GitHub Workflow Docker: debian-latest |
| Linux (Debian-based)             | ARM64 (aarch64)       | ✅ Supported / Tested | Ubuntu 22                                                    |
| Linux (Alpine, Opensuse, Archlinux)| AMD64 (x86_64)      | ✅ Supported / Tested | GitHub Workflow Docker                                       |
| Linux (Alpine)                   | ARM64 (aarch64)       | ✅ Supported / Tested | Docker                                                       |

* **Linux:** Compatible with major distributions (e.g., Debian/Ubuntu - `apt`, RHEL/CentOS/Fedora - `yum`/`dnf`, Alpine - `apk`, Arch - `pacman`, OpenSUSE - `zypper`, etc.), handled automatically by the `linux.sh` script.
* **Windows:** Supported via a PowerShell script (`windows.ps1`).
* **macOS:** Supported via a Shell script (`macos.sh`).

## 🚀 Usage

### Preparation

1. **Network Connection:** The script needs to download software packages and dependencies (Python, Node.js, uv, etc.) from the internet during execution. Ensure you have a stable network connection.
2. **Permissions:**
    * **Linux:** `sudo` privileges are usually required to install system-level packages.
    * **Windows:** Running PowerShell with **Administrator privileges** is required to ensure software is installed correctly to system paths and environment variables are configured.
    * **macOS:** You may be asked to enter your user password during script execution to allow `sudo` commands (e.g., when installing dependencies using a system package manager).
3. **Package Managers (macOS & Linux):** The script will attempt to use the system's native or recommended package manager (e.g., `apt`, `yum`, `dnf`, `pacman`, `zypper`, `apk`, `brew`, `port`). If macOS users do not have Homebrew or MacPorts installed, the script will prompt and prioritize installing Homebrew.

### Script Download Note

We provide download links from both GitHub and jsDelivr. If you experience network issues accessing GitHub directly (raw.githubusercontent.com), please try using the jsDelivr link first, as it offers better access speed and stability globally.

### 🍎 macOS

**Key Features:**

* Supports AMD64 and ARM64 (M1/M2) architectures.
* Intelligently detects and installs suitable versions of Python (>=**3.10**) and Node.js (>=**16.0**).
* Automatically selects Homebrew (preferred) or MacPorts for installation. If neither is present, it guides the installation of Homebrew.
* Installs `uv` and provides clear guidance for PATH configuration if needed.
* Automatically handles installation path differences for M1/M2 (ARM64) architecture.

**Installation Steps:**

Open **Terminal** and run one of the following commands:

* **Recommended (jsDelivr):**

    ```bash
    curl -fsSL https://cdn.jsdelivr.net/gh/aidyou/McpEnvInstaller@main/macos.sh | sh
    ```

* **Alternate (GitHub Raw):**

    ```bash
    curl -fsSL https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/macos.sh | sh
    ```

* **Recommended (For chinese users):**

    ```bash
    curl -fsSL https://gitee.com/aidyou/McpEnvInstaller/raw/main/macos.sh | sh
    ```

**Important Notes:**

* **Network Proxy:** If downloads are slow or fail, try setting up a network proxy:

    ```bash
    export http_proxy="http://your-proxy-server:port"
    export https_proxy="http://your-proxy-server:port"
    # Then run the curl command again
    ```

* **Older macOS Versions:** For older systems (e.g., macOS Mojave 10.14), you may need to manually install Xcode Command Line Tools (`xcode-select --install`) or use official Python installers. The script attempts compatibility but cannot guarantee perfect operation on all older versions.
* **PATH Configuration:** If `uv` or other tools are installed but you get `command not found`, please add paths like `$HOME/.cargo/bin` or `/opt/homebrew/bin` to your Shell configuration file (`~/.zshrc` (default for macOS Catalina+), `~/.bash_profile`, `~/.bashrc`, etc.) according to the script's output. For example, for Zsh users:

    ```bash
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.zshrc
    source ~/.zshrc # Apply the configuration
    ```

    For Bash users:

    ```bash
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bash_profile
    source ~/.bash_profile # Apply the configuration
    ```

### 🪟 Windows

**Key Features:**

* Supports AMD64 (x64), ARM64, x86 architectures.
* Compatible with Windows 10 (1809+) and Windows 11.
* Automatically downloads and silently installs recommended versions of Python (>=**3.10**) and Node.js LTS (>=**16.0**).
* Automatically installs `uv`.

**Installation Steps:**

Right-click the "Start" button, select "Windows PowerShell (Admin)", and run:

* **Recommended (jsdelivr):**

```powershell
irm https://cdn.jsdelivr.net/gh/aidyou/McpEnvInstaller@main/windows.ps1 | iex
```

* **Alternate (GitHub Raw):**

```powershell
irm https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/windows.ps1 | iex
```

* **Recommended (For chinese users):**

```powershell
irm https://gitee.com/aidyou/McpEnvInstaller/raw/main/windows.ps1 | iex
```

**Important Notes:**

* **Execution Policy:** If you encounter an error preventing script execution, you can temporarily relax the policy for the current process:

    ```powershell
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    # Then run the irm command again
    ```

* **Installation Paths:**
  Python is typically in `%ProgramFiles%\PythonXX` or `%LOCALAPPDATA%\Programs\Python` (depending on installation options), Node.js in `C:\Program Files\nodejs`.
* **Verification:** After installation, open a new terminal window and run `python --version`, `node --version`, `uv --version` to verify successful installation.

### 🐧 Linux

**Key Features:**

* Automatically detects the distribution and uses the corresponding package manager (apt, dnf, yum, pacman, zypper, apk, etc.).
* Attempts to install Python (>=**3.10**) and Node.js (>=**16.0**) meeting the version requirements.
* If the system repository version is too old, it will attempt to add reliable third-party sources (like deadsnakes PPA for Ubuntu, NodeSource) or prompt the user for manual action.
* Installs `uv`, prioritizing the official static binary.

**Installation Steps:**

Open a terminal and run one of the following commands:

* **Recommended (jsDelivr):**

    ```bash
    curl -fsSL https://cdn.jsdelivr.net/gh/aidyou/McpEnvInstaller@main/linux.sh | sh
    ```

* **Alternate (GitHub Raw):**

    ```bash
    curl -fsSL https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/linux.sh | sh
    ```

* **Recommended (For chinese users):**

    ```bash
    curl -fsSL https://gitee.com/aidyou/McpEnvInstaller/raw/main/linux.sh | sh
    ```

**Important Notes:**

* **Network Proxy:** Similar to macOS, if you have download issues, set `http_proxy` and `https_proxy` environment variables first.
* **Older Distributions:** For distributions that are no longer maintained (like CentOS 7), system packages might be very old. The script attempts compatibility, but you might need to perform additional steps (like enabling SCL, etc.) based on the prompts.
* **Non-Root Users:** The script defaults to using `sudo` for installation commands. Ensure your current user has `sudo` privileges.
* **Silent Installation:** You can add the `-s -- -q` parameters to reduce script output:

    ```bash
    curl -fsSL ... | sh -s -- -q
    ```

* **Package Manager Differences:** Package names and available versions may differ across distributions. The script attempts to adapt, but if you encounter issues on a specific distribution, feel free to open an Issue.

## 🤝 Contributing

Contributions of any kind are welcome! If you find a bug, the script doesn't work correctly on a platform, or you have suggestions for improvement, please feel free to create [Issues](https://github.com/aidyou/McpEnvInstaller/issues) or submit [Pull Requests](https://github.com/aidyou/McpEnvInstaller/pulls).

## 📜 License

This project is licensed under the **MIT License**.

The MIT License is a very permissive free software license. See the [LICENSE](LICENSE) file in the repository root for details.
