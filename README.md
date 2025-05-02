# McpEnvInstaller

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

一个跨平台的脚本集合，用于自动化安装和配置 **MCP (Model Context Protocol)** 的运行环境。

## ✨ 项目说明

本项目旨在简化在不同操作系统上搭建 MCP 运行环境的过程。MCP 环境的核心依赖包括 **Python (3.10 或更高版本)**, **Node.js (16.0 或更高版本)**, 以及 **uv (一个高性能的 Python 包管理工具)**。通过运行相应的平台脚本，可以自动完成这些依赖的安装和基础配置。

支持的平台：

* **Linux:** 兼容主流发行版，包括 **Debian 系 (如 Ubuntu), CentOS 系 (如 RHEL, Fedora), Alpine Linux, Arch Linux, OpenSUSE** (通过 `linux.sh` 脚本自动检测并处理)。
* **Windows:** 通过 PowerShell 脚本 (`windows.ps1`) 支持。
* **macOS:** 通过 Shell 脚本 (`macos.sh`) 支持。

## 🚀 使用方法

### 准备工作

1. **网络连接:** 脚本执行过程中需要从互联网下载软件包和依赖项（Python, Node.js, uv 等）。
2. **权限:**
    * 在 Linux 上，通常需要 `sudo` 权限来安装系统软件包。
    * 在 Windows 上，建议使用 **管理员权限** 运行 PowerShell 以确保能正确安装软件。
    * 在 macOS 上，脚本执行期间可能需要输入用户密码以允许 `sudo` 命令执行（例如，通过 Homebrew 安装依赖时）。
3. **(macOS 用户) 安装 Homebrew:** `macos.sh` 脚本通常依赖 [Homebrew](https://brew.sh/) 来安装 Python 和 Node.js。如果尚未安装，请先访问其官网进行安装。

### 直接下载执行

你可以直接使用curl下载并执行对应平台的安装脚本：

**请将 `aidyou/McpEnvInstaller` 替换为实际的仓库地址。**

### 不同平台的用法

#### 🐧 Linux

1. 打开终端并运行以下命令：

    ```bash
    curl -fsSL https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/linux.sh | sudo sh
    ```

    *脚本会自动下载并执行，它会尝试检测你的 Linux 发行版，并使用相应的包管理器（apt, yum/dnf, apk, pacman, zypper）安装 Python 3.10+, Node.js 16.0+, 以及 uv。*

#### 🪟 Windows

1. 打开 **PowerShell** (强烈建议 **以管理员身份运行**) 并运行以下命令：

    ```powershell
    iwr -useb https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/windows.ps1 | iex
    ```

    *脚本会自动下载并执行，负责在 Windows 系统上安装 Python 3.10+, Node.js 16.0+, 以及 uv。它可能会使用如 Chocolatey 或 Winget 包管理器，或者直接下载安装程序。*
    *(注意：如果遇到执行策略问题，你可能需要临时调整 PowerShell 执行策略，例如运行 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`。请了解相关风险后再操作。)*

#### 🍎 macOS

1. 打开 **终端 (Terminal)** 并运行以下命令：

    ```bash
    curl -fsSL https://raw.githubusercontent.com/aidyou/McpEnvInstaller/main/macos.sh | sh
    ```

    *脚本会自动下载并执行，通常会使用 Homebrew 来安装或更新 Python (确保 >= 3.10) 和 Node.js (确保 >= 16.0)，并安装 uv。如果 Homebrew 未安装，脚本可能会提示或失败。*

## 🤝 贡献

欢迎任何形式的贡献！如果你发现了 Bug、脚本在某个平台上运行不正常，或者有改进建议，请随时创建 [Issues](https://github.com/aidyou/McpEnvInstaller/issues) 或提交 [Pull Requests](https://github.com/aidyou/McpEnvInstaller/pulls)。

## 📜 开源协议

本项目采用 **MIT 许可证**。

MIT 许可证是一种非常宽松的自由软件许可协议，允许用户自由地使用、复制、修改、合并、出版发行、散布、再授权及贩售软件及软件的副本，只需在所有副本或重要部分的软件中包含原始的版权声明和许可声明即可。

详情请参阅仓库根目录下的 [LICENSE](LICENSE) 文件。
