# McpEnvInstaller

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![CI Status](https://github.com/aidyou/McpEnvInstaller/actions/workflows/test.yml/badge.svg)
![Language](https://img.shields.io/badge/Language-简体中文%20%7C%20English-blue)

简体中文 | [English](README.md)

[McpEnvInstaller](https://github.com/aidyou/McpEnvInstaller)是用于自动化部署 **MCP (Model Context Protocol)** 运行环境的跨平台脚本工具集。

> MCP 是一种开放协议，它标准化了应用程序如何为大型语言模型 (LLM) 提供上下文。可以把 MCP 想象成 AI 应用的 USB-C 接口。就像 USB-C 提供了一种标准化方式来连接你的设备和各种外围设备及配件一样，MCP 提供了一种标准化方式来连接 AI 模型和不同的数据源以及工具。更多 MCP 信息请访问 [https://modelcontextprotocol.io/introduction](https://modelcontextprotocol.io/introduction)

## ✨ 项目说明

本项目致力于简化和自动化在不同操作系统上搭建 MCP 运行环境的复杂过程。

`MCP`的`STDIO`协议允许通过标准输入输出与本地程序进行交互，通常依赖于两个命令行工具：

* `uvx`：用于快速执行通过 uv 或 pip 安装的 Python 包提供的命令行工具或入口点，通常在隔离环境中进行。
* `npx`：用于轻松运行通过 Node.js 包管理器 (`npm`) 安装的命令行工具，无需全局安装。

这些执行器（`uvx` 和 `npx`）的正常工作，离不开它们各自的运行时基础：`uvx` 执行的 Python 工具需要 **Python 运行时**，而 `npx` 及其执行的 Node.js 工具需要 **Node.js 运行时**。

因此，本项目的核心目标就是负责检测、安装并配置 MCP 环境所需的以下关键依赖：

* **Python**：提供必要的 Python 运行时环境。
* **uv**：作为高性能的 Python 包管理工具，并提供 `uvx` 执行器。
* **Node.js**：提供 Node.js 运行时环境，并已包含 `npx` 工具。

为了确保多数 MCP 项目及其所依赖的其他库（例如 crawl4ai）能够正常运行，**强烈推荐**使用 Python **3.10 或更高版本**。请注意，`uv` 本身并不依赖于 Python 版本，但为了兼容生态中的常用库并获得更好的开发体验，建议遵循此推荐。

同样，为了确保与 MCP 生态中的工具和应用的良好兼容性，我们也**推荐**使用 Node.js **16.0 或更高版本**。

通过运行相应的平台脚本，可以自动检测并安装这些依赖项，从而快速构建 MCP 运行环境。

## 支持的操作系统与架构

| 操作系统           | 芯片架构 | 支持状态  | 测试环境                                    |
| :----------------------------------- | :-------------------- | :---------------------- | :---------------------------------------------- |
| macOS              | AMD64 (Intel)         | ✅ 已支持/已测试          | GitHub Workflow                                |
| macOS              | ARM64 (Apple Silicon) | ✅ 已支持/已测试          | MacOS M1 15.4.1、GitHub Workflow               |
| Windows            | AMD64                 | ✅ 已支持/已测试          | Windows2019、Windows11、GitHub Workflow: 2019、2022         |
| Windows            | ARM64                 | ✅ 已支持/已测试          | Windows11                                      |
| Linux (Red Hat 系) | AMD64 (x86_64)        | ✅ 已支持/已测试   | GitHub Workflow Docker: Rockylinux9                         |
| Linux (Red Hat 系) | ARM64 (aarch64)       | ✅ 已支持/已测试   | Fedora38、Openeuler25              |
| Linux (Debian 系)  | AMD64 (x86_64)        | ✅ 已支持/已测试   | Ubuntu24、GitHub Workflow: Ubuntu24、GitHub Workflow Docker: debian-latest      |
| Linux (Debian 系)  | ARM64 (aarch64)       | ✅ 已支持/已测试   | Ubuntu22                                       |
| Linux (Alpine、Opensuse、Archlinux)        | AMD64 (x86_64)   | ✅ 已支持/已测试          | GitHub Workflow Docker                         |
| Linux (Alpine)    | ARM64 (aarch64)       | ✅ 已支持/已测试          | Docker                                         |

* **Linux:** 兼容主流发行版（如 Debian/Ubuntu - `apt`, RHEL/CentOS/Fedora - `yum`/`dnf`, Alpine - `apk`, Arch - `pacman`, OpenSUSE - `zypper` 等），通过 `linux.sh` 脚本自动处理。
* **Windows:** 通过 PowerShell 脚本 (`windows.ps1`) 支持。
* **macOS:** 通过 Shell 脚本 (`macos.sh`) 支持。

## 🚀 使用方法

### 准备工作

1. **网络连接:** 脚本执行过程中需要从互联网下载软件包和依赖项（Python, Node.js, uv 等）。确保您的网络连接稳定。
2. **权限:**
    * **Linux:** 通常需要 `sudo` 权限来安装系统级软件包。
    * **Windows:** 要求使用 **管理员权限** 运行 PowerShell 以确保软件能正确安装到系统路径并配置环境变量。
    * **macOS:** 脚本执行期间可能需要输入用户密码以允许 `sudo` 命令执行（例如，使用系统包管理器安装依赖时）。
3. **包管理器 (macOS & Linux):** 脚本会尝试使用系统自带或推荐的包管理器（如 `apt`, `yum`, `dnf`, `pacman`, `zypper`, `apk`, `brew`, `port`）。macOS 用户如果未安装 Homebrew 或 MacPorts，脚本会提示并优先尝试安装 Homebrew。

### 脚本下载说明

我们同时提供 GitHub 和 jsDelivr 的下载地址。如果直接访问 GitHub (raw.githubusercontent.com) 遇到网络问题，请优先尝试使用 jsDelivr 的地址，它在全球范围内有更好的访问速度和稳定性。

### 🍎 macOS

**主要特性:**

* 支持 AMD64、ARM64 (M1/M2) 架构。
* 智能检测并安装合适版本的 Python (>=**3.10**) 和 Node.js (>=**16.0**)。
* 自动选择 Homebrew (首选) 或 MacPorts 进行安装。若两者皆无，则引导安装 Homebrew。
* 安装 `uv`，并提供清晰的 PATH 配置指引（如果需要）。
* 自动处理 M1/M2 (ARM64) 架构的安装路径差异。

**安装步骤:**

打开 **终端 (Terminal)** 并运行以下命令之一：

* **推荐 (gitee):**

    ```bash
    curl -fsSL https://gitee.com/aidyou/McpEnvInstaller/raw/main/macos.sh | sh
    ```

* **备用一 (jsDelivr):**

    ```bash
    curl -fsSL https://cdn.jsdelivr.net/gh/aidyou/McpEnvInstaller@main/macos.sh | sh
    ```

* **备用二 (GitHub Raw):**

    ```bash
    curl -fsSL https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/macos.sh | sh
    ```

**注意事项:**

* **网络代理:** 如果下载缓慢或失败，请尝试设置网络代理：

    ```bash
    export http_proxy="http://your-proxy-server:port"
    export https_proxy="http://your-proxy-server:port"
    # 然后再运行上面的 curl 命令
    ```

* **旧版 macOS:** 对于较旧的系统 (如 macOS Mojave 10.14)，可能需要手动安装 Xcode Command Line Tools (`xcode-select --install`) 或使用官方 Python 安装包。脚本会尽力兼容，但不能保证在所有旧版本上完美运行。
* **PATH 配置:** 如果 `uv` 或其他工具安装后提示 `command not found`，请根据脚本输出的提示，将类似 `$HOME/.cargo/bin` 或 `/opt/homebrew/bin` 的路径添加到您的 Shell 配置文件中。常见的配置文件包括 `~/.zshrc` (macOS Catalina+ 默认), `~/.bash_profile` 或 `~/.bashrc`。例如，对于 Zsh 用户：

    ```bash
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.zshrc
    source ~/.zshrc # 使配置生效
    ```

    对于 Bash 用户：

    ```bash
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bash_profile
    source ~/.bash_profile # 使配置生效
    ```

### 🪟 Windows

**主要特性:**

* 支持 x64, ARM64, x86 架构。
* 兼容 Windows 10 (1809+) 及 Windows 11。
* 自动下载并静默安装推荐版本的 Python (>=**3.10**) 和 Node.js LTS (>=**16.0**)。
* 自动安装 `uv`。

**安装步骤:**

右键点击 "开始" 按钮，选择 "终端 (管理员)" 或 "Windows PowerShell (管理员)"，然后运行：

* **推荐 (gitee):**

    ```powershell
    irm https://gitee.com/aidyou/McpEnvInstaller/raw/main/windows.ps1 | iex
    ```

* **备用一 (jsdelivr):**

    ```powershell
    irm https://cdn.jsdelivr.net/gh/aidyou/McpEnvInstaller@main/windows.ps1 | iex
    ```

* **备用二 (GitHub Raw):**

    ```powershell
    irm https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/windows.ps1 | iex
    ```

**注意事项:**

* **执行策略:** 如果遇到禁止执行脚本的错误，可以临时为当前进程放宽策略：

    ```powershell
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    # 然后再运行上面的 irm 命令
    ```

* **安装路径:**
  * 管理员安装：Python 通常在 `%ProgramFiles%\PythonXX` 或 `%LOCALAPPDATA%\Programs\Python` (取决于安装选项)，Node.js 在 `C:\Program Files\nodejs`。
* **验证:** 安装完成后，可以新开一个终端窗口，运行 `python --version`, `node --version`, `uv --version` 来验证是否安装成功。

### 🐧 Linux

**主要特性:**

* 自动检测发行版并使用相应的包管理器 (apt, dnf, yum, pacman, zypper, apk 等)。
* 尝试安装满足版本要求的 Python (>=**3.10**) 和 Node.js (>=**16.0**)。
* 如果系统仓库版本过低，会尝试添加可靠的第三方源 (如 deadsnakes PPA for Ubuntu, NodeSource) 或提示用户手动处理。
* 安装 `uv`，优先使用官方静态二进制包。

**安装步骤:**

打开终端并运行以下命令之一：

* **推荐 (gitee):**

    ```bash
    curl -fsSL https://gitee.com/aidyou/McpEnvInstaller/raw/main/linux.sh | sh
    ```

* **备用一 (jsDelivr):**

    ```bash
    curl -fsSL https://cdn.jsdelivr.net/gh/aidyou/McpEnvInstaller@main/linux.sh | sh
    ```

* **备用二 (GitHub Raw):**

    ```bash
    curl -fsSL https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/linux.sh | sh
    ```

**注意事项:**

* **网络代理:** 同 macOS，如果下载有问题，请先设置 `http_proxy` 和 `https_proxy` 环境变量。
* **旧版发行版:** 对于已停止维护的发行版（如 CentOS 7），系统自带的包可能非常旧。脚本会尝试兼容，但可能需要用户根据提示进行额外操作（如启用 SCL 等）。
* **非 Root 用户:** 脚本内部的安装命令默认使用 `sudo` 执行安装命令。请确保当前用户有 `sudo` 权限。
* **静默安装:** 可以添加 `-s -- -q` 参数来减少脚本输出：

    ```bash
    curl -fsSL ... | sh -s -- -q
    ```

* **包管理器差异:** 不同发行版的包名和可用版本可能不同。脚本会尽力适配，但如果遇到特定发行版的问题，欢迎提 Issue。

## 🤝 贡献

欢迎任何形式的贡献！如果你发现了 Bug、脚本在某个平台上运行不正常，或者有改进建议，请随时创建 [Issues](https://github.com/aidyou/McpEnvInstaller/issues) 或提交 [Pull Requests](https://github.com/aidyou/McpEnvInstaller/pulls)。

## 📜 开源协议

本项目采用 **MIT 许可证**。

MIT 许可证是一种非常宽松的自由软件许可协议。详情请参阅仓库根目录下的 [LICENSE](LICENSE) 文件。
