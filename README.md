# 🚀 Script Installer

A powerful, interactive, and intelligent shell script installer designed to dynamically fetch, install, and manage multiple bash scripts or tools from a central JSON configuration.

## Features

- **Dynamic Configuration**: Reads a centralized `config.json` file from your repository to discover available tools.
- **Interactive Menu**: Provides a sleek, interactive terminal UI to easily select which tools to install or update.
- **Smart Updates**: Compares local file hashes with remote files; it skips untouched files and only updates scripts that have actually changed.
- **Dependency Management**: Automatically resolves and installs any required dependencies for your chosen tools using `apt-get`.
- **CLI Support**: Supports command-line arguments for headless or automated batch installations.
- **Zero-Dependency Core**: Built with standard Unix tools (Bash, Python3, cURL) ensuring it runs smoothly on modern Linux distributions without bloated prerequisites.

## ⚡ Quick Install

You can launch the installer directly from your terminal using the following command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/raj5222/Script-Installer/main/install.sh)
```

## 📖 Usage

### Interactive Mode
Simply run the script without any arguments to launch the interactive menu:
```bash
./install.sh
```
You will be greeted with a numbered list of available tools. You can:
- Type a single number (e.g., `1`) to install one tool.
- Type multiple numbers separated by spaces (e.g., `1 3 4`) to batch install specific tools.
- Type the specified "ALL" number to install/update everything in the catalog.
- Type `q`, `quit`, or `exit` to quit the installer.

### Command-Line (Headless) Mode
You can bypass the interactive menu entirely by passing arguments directly to the script:

**Install everything automatically:**
```bash
./install.sh --all
# or
./install.sh -a
```

**Install specific tools by their Menu ID:**
```bash
./install.sh 1 4 5
```

## ⚙️ Configuration (`config.json`)

The installer relies on a remote JSON configuration file. By default, it downloads the configuration from:
`https://raw.githubusercontent.com/raj5222/Script-Installer/main/config.json`

### JSON Structure
Your `config.json` should contain an array of script objects. Each object dictates how a specific tool is installed:

```json
{
  "scripts": [
    {
      "name": "db-toolkit",
      "description": "Advanced database backup and restoration utility",
      "url": "https://raw.githubusercontent.com/raj5222/DB-Restore-Export-Script/main/db-toolkit.sh",
      "install_path": "/usr/local/bin/db-toolkit",
      "dependencies": ["curl", "mysql-client", "jq"]
    },
    {
      "name": "git-record",
      "description": "Git commit history recording tool",
      "url": "https://raw.githubusercontent.com/raj5222/git-record-repo/main/git-record.sh",
      "install_path": "/usr/local/bin/git-record",
      "dependencies": ["git"]
    }
  ]
}
```

### Configuration Fields
- **`name`** *(Required)*: The display name of the tool.
- **`url`** *(Required)*: The raw URL to the bash script to be downloaded.
- **`install_path`** *(Required)*: The absolute path where the script should be installed on the system (e.g., `/usr/local/bin/my-tool`).
- **`description`** *(Optional)*: A short summary of what the tool does. This is displayed inline in the interactive terminal menu.
- **`dependencies`** *(Optional)*: An array of package names required by the tool. The installer will gather these across all selected tools and automatically install them via `apt-get` before installing the scripts.

## 🔒 Requirements

- Linux-based OS (Debian/Ubuntu recommended for `apt-get` automated dependency resolution)
- `python3` (Pre-installed on almost all modern Linux distros; used for robust JSON parsing)
- `curl`
- `sudo` privileges (The installer checks and requests `sudo` automatically to place files in protected directories like `/usr/local/bin`).

---
*Built to make bash utility installation fast, reliable, and beautiful.*
