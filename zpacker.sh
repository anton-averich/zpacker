#!/bin/bash

set -o pipefail # Exit immediately if a command in a pipeline fails.
# set -u # Treat unset variables as an error (optional, requires careful checking)
# set -e # Exit immediately if a command exits with a non-zero status (optional)

# Script for packing and unpacking files/folders using tar and zstd.
# Supports dependency checking and installation via Homebrew on macOS.
# Improved path handling to prevent creating unwanted parent directories during extraction.

# --- Configuration & Defaults ---
VERSION="1.0.0"
DEFAULT_OUTPUT_FILE="archive.tar.zst"
DEFAULT_COMPRESSION_LEVEL=9
DEFAULT_OUTPUT_DIR="."

# --- Variables to store arguments ---
output_file="$DEFAULT_OUTPUT_FILE"
compression_level="$DEFAULT_COMPRESSION_LEVEL"
unpack_archive_name=""
output_dir="$DEFAULT_OUTPUT_DIR"
input_files=()
mode="" # "pack" or "unpack"
force_overwrite=false # Flag for -f option

# --- Functions ---

# Displays help message
usage() {
  echo "zpacker v$VERSION" # Display version
  echo "Usage:"
  echo "  Pack:   $0 [OPTIONS] -i <file/folder1> [file/folder2...]"
  echo "  Unpack: $0 -u <archive.tar.zst> [-o <destination_folder>]"
  echo ""
  echo "Options:"
  echo "  -i <input...> : Pack mode. Specify one or more files/folders to archive."
  echo "  -u <archive>  : Unpack mode. Specify the archive file to unpack."
  echo "  -o <path>     : In pack mode: name of the output archive (default: $DEFAULT_OUTPUT_FILE)."
  echo "                  In unpack mode: folder to extract files into (default: current dir '$DEFAULT_OUTPUT_DIR')."
  echo "  -q <level>    : zstd compression level (1-22, default: $DEFAULT_COMPRESSION_LEVEL). Levels 20-22 are ultra levels. Used only for packing."
  echo "  -f            : Force overwrite of the output file if it exists (pack mode only)."
  echo "  -h            : Show this help message."
}

# Checks if a command exists in PATH
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# Prints instructions for installing Homebrew
install_homebrew_instructions() {
  echo "Error: Homebrew not found." >&2
  echo "Please install Homebrew by running the following command in your terminal:" >&2
  echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
  echo "Then run this script again." >&2
  return 1 # Return error code instead of exiting directly
}

# Installs zstd using Homebrew
install_zstd_brew() {
  echo "Attempting to install zstd using Homebrew..."
  if brew install zstd; then
    echo "zstd successfully installed."
  else
    echo "Error: Failed to install zstd using Homebrew." >&2
    return 1
  fi
}

# Checks for tar and zstd dependencies, prompts for zstd installation if needed
check_deps() {
  echo "Checking dependencies..."
  if ! check_command tar; then
    echo "Critical Error: 'tar' command not found. It is required for archiving." >&2
    echo "On macOS, 'tar' is usually included. If missing, you might need to reinstall Xcode Command Line Tools." >&2
    echo "On Linux, please install it using your system's package manager. Examples:" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install tar" >&2
    echo "  Fedora/RHEL/CentOS (newer): sudo dnf install tar" >&2
    echo "  Fedora/RHEL/CentOS (older): sudo yum install tar" >&2
    echo "  Arch Linux: sudo pacman -S tar" >&2
    echo "Consult your distribution's documentation if unsure." >&2
    exit 1
  fi
  echo "  [✓] tar found."

  if check_command zstd; then
    echo "  [✓] zstd found."
    return 0
  fi

  echo "  [✗] zstd not found."
  # Check OS and Homebrew presence (for macOS)
  if [[ "$(uname)" == "Darwin" ]]; then
    if check_command brew; then
      # Ask for confirmation before installing
      local response
      read -p "zstd not found. Attempt to install using Homebrew? (y/N): " response
      echo # Add a newline for cleaner output after user input
      if [[ "$response" =~ ^[Yy]$ ]]; then
        install_zstd_brew || exit 1
      else
        echo "Installation aborted by user. zstd is required to continue." >&2
        exit 1
      fi
    else
      install_homebrew_instructions
      exit 1
    fi
  else
    # For other OS (Linux / potentially other Unix-like)
    echo "Please install zstd using your system's package manager. Examples:" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install zstd" >&2
    echo "  Fedora/RHEL/CentOS (newer): sudo dnf install zstd" >&2
    echo "  Fedora/RHEL/CentOS (older): sudo yum install zstd" >&2
    echo "  Arch Linux: sudo pacman -S zstd" >&2
    # Add other distributions as needed (e.g., zypper for openSUSE)
    echo "Consult your distribution's documentation if unsure." >&2
    exit 1
  fi
  # Re-check after installation attempt
  if ! check_command zstd; then
     echo "Error: zstd was not found even after attempting installation." >&2
     exit 1
  fi
   echo "  [✓] zstd is now available."
   return 0
}

# Packing function (improved path handling)
pack_files() {
  local output_archive="$1"
  local level="$2"
  shift 2 # Remove the first two arguments (output_archive, level)
  local inputs=("$@") # Remaining arguments are input files/folders
  local tar_args=() # Array for tar arguments

  echo "Starting packing process..."
  echo "  Input items: ${inputs[@]}"
  echo "  Output archive: $output_archive"
  echo "  zstd compression level: $level"

  # --- Pre-flight Checks ---
  # 1. Check input files existence and permissions
  for item in "${inputs[@]}"; do
    # Prevent attempting to archive the root directory
    if [[ "$(readlink -f "$item")" == "/" ]]; then
        echo "Error: Archiving the root directory ('/') is not allowed." >&2
        exit 1
    fi
    if [ ! -e "$item" ]; then
      echo "Error: Input file or folder not found: '$item'" >&2
      exit 1
    fi
    # Check read permission
    if [ ! -r "$item" ]; then
      echo "Error: Read permission denied for input: '$item'" >&2
      exit 1
    fi
    # --- Get parent directory and base name for tar --- 
    local parent_dir
    parent_dir=$(dirname -- "$item")
    # Handle cases where the item is in the current directory (dirname returns '.')
    if [[ "$parent_dir" == "." ]]; then
        parent_dir=$(pwd) # Use absolute path for current directory
    fi

    local base_name
    base_name=$(basename -- "$item")

    # Add -C option and the base name to the arguments array
    # This tells tar to change to parent_dir before adding base_name
    tar_args+=("-C" "$parent_dir" "$base_name")
  done
  
  # 2. Check output directory permissions
  local output_dir
  output_dir=$(dirname -- "$output_archive")
  # If dirname returns '.', the directory is the current one
  if [[ "$output_dir" == "." ]]; then
      output_dir=$(pwd)
  fi
  # Check if output directory exists and is writable
  if [ ! -d "$output_dir" ]; then
      echo "Error: Output directory '$output_dir' does not exist." >&2
      # Optionally, we could offer to create it, but for now, require it to exist.
      exit 1
  fi
  if [ ! -w "$output_dir" ]; then
      echo "Error: Output directory '$output_dir' is not writable." >&2
      exit 1
  fi
  # Check if the output *file* itself exists and handle -f flag
  if [ -e "$output_archive" ] && [ "$force_overwrite" = false ]; then
      echo "Error: Output file '$output_archive' already exists. Use -f to overwrite." >&2
      exit 1
  # We don't need the 'elif [ ! -w ... ]' check specifically for the file,
  # because if the directory is writable, we can create/overwrite the file.
  fi

  echo "  Pre-flight checks passed."
  echo "  tar command will use arguments: ${tar_args[@]}"

  # --- Execute Packing --- 
  # Pipe tar output to zstd for compression
  # Add --force to zstd if -f flag is set
  local zstd_options=(-T0 "-$level")
  if [ "$force_overwrite" = true ]; then
      zstd_options+=("--force")
  fi
  # Add --ultra for levels 20-22
  if [ "$level" -ge 20 ]; then
      zstd_options+=("--ultra")
  fi

  echo "  Using zstd options: ${zstd_options[@]}"

  if tar -cf - "${tar_args[@]}" | zstd "${zstd_options[@]}" -o "$output_archive"; then
    echo "Packing successfully completed: $output_archive"
  else
    echo "Error: An error occurred during packing." >&2
    # Attempt to remove partially created file (if it exists)
    [ -f "$output_archive" ] && rm "$output_archive"
    exit 1
  fi
}

# Unpacking function
unpack_archive() {
  local archive_to_unpack="$1"
  local target_dir="$2"
  local dir_created_by_script=false # Flag to track if we created the dir

  echo "Starting unpacking process..."
  echo "  Archive: $archive_to_unpack"
  echo "  Destination directory: $target_dir"

  # Check if archive exists
  if [ ! -f "$archive_to_unpack" ]; then
    echo "Error: Archive not found: '$archive_to_unpack'" >&2
    exit 1
  fi

  # Check if the target path exists and is a file
  if [ -e "$target_dir" ] && [ ! -d "$target_dir" ]; then
    echo "Error: Target path '$target_dir' exists but is not a directory." >&2
    exit 1
  fi

  # Create destination directory if it doesn't exist
  if [ "$target_dir" != "." ] && [ ! -d "$target_dir" ]; then
    echo "  Creating destination directory: $target_dir"
    # Check if parent directory is writable before attempting to create
    local parent_target_dir
    parent_target_dir=$(dirname -- "$target_dir")
    if [ ! -w "$parent_target_dir" ]; then
        echo "Error: No write permissions for creating directory in '$parent_target_dir'." >&2
        exit 1
    fi
    if mkdir -p "$target_dir"; then
        dir_created_by_script=true
    else
        echo "Error: Failed to create destination directory '$target_dir'." >&2;
        exit 1;
    fi
  elif [ ! -w "$target_dir" ]; then # Check if existing target directory is writable
      echo "Error: Destination directory '$target_dir' is not writable." >&2
      exit 1
  fi

  # Execute the unpacking command
  # Pipe zstd decompression output to tar for extraction
  # Add -v for verbose output (list extracted files)
  # Use -C for tar to extract into the target directory
  # Note: Relying on modern tar's default security features to prevent path traversal
  # (extraction of files with '../' in the path or absolute paths like '/etc/passwd').
  # Do NOT use options like -P or --absolute-names with tar during unpack.
  if zstd -d "$archive_to_unpack" -c | tar -C "$target_dir" -xvf -; then
    echo "Unpacking successfully completed into '$target_dir'."
  else
    # Note: Due to pipefail, this error could be from zstd (e.g., corrupted archive)
    # or from tar (e.g., filesystem error during extraction).
    echo "Error: An error occurred during unpacking." >&2
    # Attempt to remove the directory only if we created it and it's empty
    if [ "$dir_created_by_script" = true ]; then
       # Check if directory is empty before removing
       if [ -d "$target_dir" ] && [ -z "$(ls -A "$target_dir")" ]; then
         echo "  Attempting to remove empty directory created by script: $target_dir"
         rmdir "$target_dir" || echo "Warning: Could not remove directory '$target_dir'." >&2
       else
         echo "  Directory '$target_dir' was created but is not empty or does not exist anymore, not removing." >&2
       fi
    fi
    exit 1
  fi
}

# --- Parse Command Line Arguments ---
output_target="" # Temporary variable for -o

while getopts ":i:u:o:q:hf" opt; do
  case ${opt} in
    i )
      # Check if mode is already set to unpack
      if [ "$mode" == "unpack" ]; then
          echo "Error: Cannot use -i (pack) and -u (unpack) simultaneously." >&2
          usage
          exit 1
      fi
      mode="pack"
      input_files+=("$OPTARG") # Add file to the list
      ;;
    u )
      # Unpack mode
      if [ "$mode" == "pack" ]; then
        echo "Error: Cannot use -i (pack) and -u (unpack) simultaneously." >&2
        usage
        exit 1
      fi
      mode="unpack"
      unpack_archive_name="$OPTARG"
      ;;
    o )
      output_target="$OPTARG"
      ;;
    q )
      compression_level="$OPTARG"
      # Validate compression level
      if ! [[ "$compression_level" =~ ^[0-9]+$ ]] || [ "$compression_level" -lt 1 ] || [ "$compression_level" -gt 22 ]; then
         echo "Error: Compression level (-q) must be a number between 1 and 22." >&2
         usage
         exit 1
      fi
      ;;
    f ) # Handle the force flag
      force_overwrite=true
      ;;
    h )
      usage
      exit 0 # Exit successfully after showing help
      ;;
    \? )
      echo "Error: Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
    : )
      echo "Error: Option -$OPTARG requires an argument." >&2
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND -1)) # Shift positional parameters to remove processed options

# Check for misplaced options after non-option arguments (common in pack mode)
if [ "$mode" == "pack" ]; then
  for arg in "$@"; do
    # Stop checking if we encounter the explicit '--' separator
    if [[ "$arg" == "--" ]]; then
      break
    fi
    # Check if an argument looks like an option but wasn't processed by getopts
    # This usually means it came after a non-option argument (filename)
    if [[ "$arg" == -* ]]; then
      echo "Error: Found argument '$arg' after potential file/folder names." >&2
      echo "Please place all options (like -q, -o, -f) *before* the input files/folders specified with -i." >&2
      echo "Example: $0 -f -q 10 -o myarchive.tar.zst -i file1 folder2" >&2
      # You can also use '--' to explicitly separate options from filenames:
      # echo "Example: $0 -q 10 -o myarchive.tar.zst -i -- file1 -tricky-filename-" >&2
      usage # Show usage for context
      exit 1
    fi
  done
fi

# --- Main Logic Based on Mode ---

if [ "$mode" == "pack" ]; then
  # Assign output file name
  if [ -n "$output_target" ]; then
    output_file="$output_target"
  fi

  # Check if the output target is explicitly a directory
  if [ -d "$output_file" ] || [[ "$output_file" == */ ]]; then
    echo "Error: Output path specified with -o in pack mode ('$output_file') cannot be a directory." >&2
    usage
    exit 1
  fi

  # Check if any input files were provided via -i
  if [ ${#input_files[@]} -eq 0 ]; then
    echo "Error: At least one input file or folder must be specified for packing via -i." >&2
    usage
    exit 1
  fi

  # Check dependencies
  check_deps || exit 1

  # Call packing function
  pack_files "$output_file" "$compression_level" "${input_files[@]}"

elif [ "$mode" == "unpack" ]; then
  # Assign destination directory
  if [ -n "$output_target" ]; then
    output_dir="$output_target"
  fi

  # Warn if pack-specific options were used unnecessarily
  if [ "$compression_level" != "$DEFAULT_COMPRESSION_LEVEL" ]; then
      echo "Warning: Option -q (compression level) is ignored during unpack mode." >&2
  fi
  if [ "$force_overwrite" = true ]; then
      echo "Warning: Option -f (force overwrite) is ignored during unpack mode." >&2
  fi

  # Check if archive name was provided via -u
  if [ -z "$unpack_archive_name" ]; then
     echo "Error: Archive name must be specified using -u for unpacking." >&2
     usage
     exit 1
  fi
   # Check for extraneous arguments
  if [ $# -gt 0 ]; then
    echo "Error: Unexpected arguments in unpack mode: $@" >&2
    usage
    exit 1
  fi

  # Check dependencies
  check_deps || exit 1

  # Call unpacking function
  unpack_archive "$unpack_archive_name" "$output_dir"

else
  # If no mode was selected
  if [ $# -eq 0 ]; then
      # Show usage and exit successfully if no args are given
      usage
      exit 0
  else
      # Maybe the user just passed a filename without specifying a mode?
      # Check if the first argument exists as a file or directory to provide a better hint.
      local first_arg="$1"
      echo "Error: Operating mode not specified (-i for pack or -u for unpack)." >&2
      if [ -n "$first_arg" ]; then # Check if $1 is not empty
          if [ -e "$first_arg" ]; then
              echo "If you wanted to pack '$first_arg', use:" >&2
              echo "  $0 -i '$first_arg' [other files...] [-o ...] [-q ...]" >&2
              echo "If you wanted to unpack '$first_arg', use:" >&2
              echo "  $0 -u '$first_arg' [-o ...]" >&2
          else
               echo "Please specify -i <input>... for packing or -u <archive> for unpacking." >&2
          fi
      else
          usage # Show usage if no arguments were given at all (already handled, but safe fallback)
      fi
      exit 1
  fi
fi

exit 0
