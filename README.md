# zpacker v1.0.1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A simple yet powerful Bash script for packing and unpacking files/folders using `tar` and `zstd`. Features automatic dependency checking and installation prompt for `zstd` via Homebrew on macOS.

## Features

* **Pack:** Create `.tar.zst` archives from specified files and folders.
* **Unpack:** Extract `.tar.zst` archives.
* **Dependency Check:** Verifies if `tar` and `zstd` are installed.
* **Interactive Install Prompt (macOS):** Asks for confirmation before attempting to install `zstd` using Homebrew if missing.
* **Custom Compression:** Choose zstd compression level (**1-22**). Levels 20-22 automatically enable ultra mode.
* **Overwrite Protection:** Optional force overwrite (`-f`) for packing.
* **Flexible Output:** Specify output archive name (`-o`) or extraction directory (`-o`).
* **Safe Extraction:** Uses `tar -C` during unpack to prevent common path traversal issues.
* **Robust Error Handling:** Includes pre-flight checks for file/directory permissions and existence, prevents accidental overwrites or archiving the root directory, and handles target path conflicts during unpacking.
* **Symbolic Links:** Archives and restores symbolic links as links (default `tar` behavior).

### Compression Levels

* **Range:** Supports `zstd` compression levels from 1 (fastest) to 22 (highest compression, slowest). Levels 20-22 require the `--ultra` flag, which the script adds automatically.
* **Script Default:** The default compression level is set to **9** within the script (`DEFAULT_COMPRESSION_LEVEL=9`), offering a good balance between speed and compression ratio for general use.
* **Zstd Default:** Note that the standard default level for the `zstd` command-line tool itself is 3.
* **Customization:** You can change the script's default level by modifying the `DEFAULT_COMPRESSION_LEVEL` variable at the beginning of the `zpacker.sh` file.

## Prerequisites

* **Bash:** The script is written for **Bash** and uses bash-specific features. It may not function correctly in other shells like `sh`.
* **`tar`:** Standard archiving utility. Usually pre-installed on Linux and macOS.
* **`zstd`:** Zstandard compression tool. The script will prompt for installation if needed (macOS via Homebrew, instructions provided for Linux package managers like `apt`, `dnf`, `yum`, `pacman`).

## Installation

1. Clone the repository or download the `zpacker.sh` and `test.sh` scripts.
2. Make the scripts executable:

   ```bash
   chmod +x zpacker.sh test.sh
   ```

3. **(Recommended)** Place the `zpacker.sh` script in a directory included in your system's `PATH` for easy access from any location. Common choices include `/usr/local/bin` (for system-wide access, might require `sudo`) or `~/bin` (for user-specific access).
   * Example (user-specific `~/bin`):

     ```bash
     # Ensure ~/bin exists and is in your PATH
     mkdir -p ~/bin
     # Add 'export PATH="$HOME/bin:$PATH"' to your ~/.bashrc or ~/.zshrc if not already present, then reload your shell
     source ~/.zshrc # or source ~/.bashrc

     # Move the script
     mv zpacker.sh ~/bin/
     ```

   * After moving (and ensuring the directory is in PATH), you can run the script simply by typing `zpacker.sh` from anywhere.

## Usage

The script operates in two main modes: **Pack** (`-i`) and **Unpack** (`-u`).

```bash
# Display help message
./zpacker.sh -h
```

### Packing Files/Folders

Use the `-i` option to specify **each** input file or folder separately.

**Default Output Name:**

* If you provide **exactly one** input item (`-i file`) and do **not** specify an output name (`-o`), the default archive name will be `<input_name>.tar.zst` (where `<input_name>` is the base name of the input file or folder).
* If you provide **multiple** input items (`-i file1 -i file2 ...`) or explicitly specify an output name with `-o`, the default is `archive.tar.zst` (unless overridden by `-o`).

```bash
# Pack a single file, default output: my_document.txt.tar.zst
./zpacker.sh -i my_document.txt

# Pack a single folder, default output: my_folder.tar.zst
./zpacker.sh -i my_folder/

# Pack multiple items, default output: archive.tar.zst
./zpacker.sh -i my_document.txt -i my_folder/ -i project_files/

# Specify output archive name (overrides default)
./zpacker.sh -i my_folder/ -o backup.tar.zst

# Specify compression level (1-22, e.g., level 3 for faster compression or 22 for max)
./zpacker.sh -i large_dataset/ -q 3 -o dataset_archive_fast.tar.zst
./zpacker.sh -i important_docs/ -q 22 -o docs_archive_max.tar.zst

# Force overwrite if output file exists
./zpacker.sh -f -i src/ -o latest_build.tar.zst
```

### Unpacking Archives

Use the `-u` option to specify the archive file.

```bash
# Unpack archive into the current directory
./zpacker.sh -u archive.tar.zst

# Unpack archive into a specific destination folder
./zpacker.sh -u backup.tar.zst -o /path/to/restore/location
```

Options like `-q` and `-f` are ignored during unpacking.

## Testing

The project includes an automated test suite located in `test.sh`.
To run the tests, navigate to the project directory in your terminal and execute:

```bash
bash test.sh
```

The test suite will create a temporary directory (`_test_run_area` by default), run various packing, unpacking, and argument validation scenarios, and report the results. It cleans up after itself.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues.

## Limitations

* The script relies on external commands (`tar`, `zstd`, `brew` (macOS), `readlink`, `dirname`, `basename`). Ensure these are available and function correctly in your environment.
* Error handling for external commands depends on their exit codes. Unusual errors within these commands might not be caught gracefully.
* While care has been taken with quoting, extremely unusual filenames (e.g., containing newlines) might cause issues.
* The script does not provide interactive file selection within directories; it archives the specified items entirely.
* Progress indication for long operations is not implemented.
