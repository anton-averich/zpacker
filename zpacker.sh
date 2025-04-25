#!/bin/bash

set -o pipefail # Exit immediately if a command in a pipeline fails.
# set -u # Treat unset variables as an error (optional, requires careful checking)
# set -e # Exit immediately if a command exits with a non-zero status (optional)

# Script for packing and unpacking files/folders using tar and zstd.
# Supports dependency checking and installation via Homebrew on macOS.
# Improved path handling to prevent creating unwanted parent directories during extraction.

# --- Configuration & Defaults ---
VERSION="1.0.1"
DEFAULT_OUTPUT_FILE="archive.tar.zst"
DEFAULT_COMPRESSION_LEVEL=9
DEFAULT_OUTPUT_DIR="."

# --- Global Variables (set by parse_arguments) ---
output_target="" 
input_files=()   
mode=""          
compression_level="$DEFAULT_COMPRESSION_LEVEL" 
force_overwrite=false
unpack_archive_name=""
output_dir="$DEFAULT_OUTPUT_DIR" # Can be overridden by -o in unpack mode
output_file=""   # Determined in main() for pack mode

# --- Functions ---

# Displays help message
usage() {
  echo "zpacker v$VERSION" # Display version
  echo "Usage:"
  echo "  Pack:   $0 [OPTIONS] -i <file/folder1> [-i <file/folder2>...] [-o <archive.tar.zst>] [-q <level>] [-f]"
  echo "  Unpack: $0 -u <archive.tar.zst> [-o <destination_folder>]"
  echo ""
  echo "Options:"
  echo "  -i <input>    : Pack mode. Specify input file/folder. Use multiple -i for multiple inputs."
  echo "  -u <archive>  : Unpack mode. Specify the archive file to unpack."
  echo "  -o <path>     : In pack mode: name of the output archive (default: derived from input or '$DEFAULT_OUTPUT_FILE')."
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
  local tar_input_paths=() # Array for tar input paths (relative or absolute)

  echo "Starting packing process..."
  echo "  Input items: ${inputs[@]}"
  echo "  Output archive: $output_archive"
  echo "  zstd compression level: $level"

  # --- Pre-flight Checks --- 
  # 1. Check input files existence and permissions using readlink -f, but prepare simple paths for tar
  for item in "${inputs[@]}"; do
    # Check for existence first, as readlink -f might fail on non-existent files
    if [ ! -e "$item" ]; then
      echo "Error: Input file or folder not found: '$item'" >&2
      exit 1
    fi
    # Use readlink -f to get canonical path for checks
    local abs_item
    abs_item=$(readlink -f "$item")
    # Prevent attempting to archive the root directory (using resolved path)
    if [[ "$abs_item" == "/" ]]; then
        echo "Error: Archiving the root directory ('/') is not allowed." >&2
        exit 1
    fi
    # Check read permission (on the resolved path)
    if [ ! -r "$abs_item" ]; then
      echo "Error: Read permission denied for input: '$item' (resolved to '$abs_item')" >&2
      exit 1
    fi
    
    # Add the original item path to the list for tar
    tar_input_paths+=("$item")
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
  fi

  echo "  Pre-flight checks passed."
  # Echo the paths tar will process
  echo "  tar command will process input paths: ${tar_input_paths[@]}"

  # --- Execute Packing --- 
  # Pipe tar output to zstd for compression
  local zstd_options=(-T0 "-$level")
  if [ "$force_overwrite" = true ]; then
      zstd_options+=("--force")
  fi
  # Add --ultra for levels 20-22
  if [ "$level" -ge 20 ]; then
      zstd_options+=("--ultra")
  fi

  echo "  Using zstd options: ${zstd_options[@]}"

  # Execute tar with the list of paths (no -C here)
  if tar -cf - "${tar_input_paths[@]}" | zstd "${zstd_options[@]}" -o "$output_archive"; then
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

parse_arguments() {
  # Parses command line options using getopts.
  # Sets global variables: mode, input_files, output_target, compression_level, force_overwrite, unpack_archive_name
  
  # Reset global variables for safety (in case function is called multiple times, though not expected here)
  input_files=()
  mode=""
  output_target=""
  compression_level="$DEFAULT_COMPRESSION_LEVEL"
  force_overwrite=false
  unpack_archive_name=""

  # Ensure OPTIND is reset if getopts is used in a function
  OPTIND=1 

  while getopts ":i:u:o:q:hf" opt; do
    case ${opt} in
      i )
        if [ "$mode" == "unpack" ]; then
            echo "Error: Cannot use -i (pack) and -u (unpack) simultaneously." >&2; usage; exit 1
        fi
        mode="pack"
        input_files+=("$OPTARG") 
        ;;
      u )
        if [ "$mode" == "pack" ]; then
          echo "Error: Cannot use -i (pack) and -u (unpack) simultaneously." >&2; usage; exit 1
        fi
        if [ -n "$unpack_archive_name" ]; then
            echo "Error: Cannot specify multiple archives with -u." >&2; usage; exit 1
        fi
        mode="unpack"
        unpack_archive_name="$OPTARG"
        ;;
      o )
        if [ -n "$output_target" ]; then
            echo "Error: Cannot specify multiple output targets with -o." >&2; usage; exit 1
        fi
        output_target="$OPTARG"
        ;;
      q )
        if [[ "$compression_level" != "$DEFAULT_COMPRESSION_LEVEL" && "$compression_level" != "$OPTARG" ]]; then
           echo "Error: Cannot specify multiple compression levels with -q." >&2; usage; exit 1
        fi
        compression_level="$OPTARG"
        if ! [[ "$compression_level" =~ ^[0-9]+$ ]] || [ "$compression_level" -lt 1 ] || [ "$compression_level" -gt 22 ]; then
           echo "Error: Compression level (-q) must be a number between 1 and 22." >&2; usage; exit 1
        fi
        ;;
      f )
        force_overwrite=true
        ;;
      h )
        usage
        exit 0 
        ;;
      \? )
        echo "Error: Invalid option: -$OPTARG" >&2; usage; exit 1
        ;;
      : )
        echo "Error: Option -$OPTARG requires an argument." >&2; usage; exit 1
        ;;
    esac
  done
  shift $((OPTIND -1)) 

  # Check for any remaining non-option arguments after processing options
  if [ $# -gt 0 ]; then
      if [ "$mode" == "pack" ]; then
          echo "Error: Unexpected arguments found after options: $@" >&2
          echo "Please specify all input files/folders using the -i option." >&2
      elif [ "$mode" == "unpack" ]; then
          echo "Error: Unexpected arguments found after archive name in unpack mode: $@" >&2
      else
          echo "Error: Unexpected arguments: $@" >&2
      fi
      usage
      exit 1
  fi
}

main() {
  # Handle the case of no arguments or only -h (which exits in parse_arguments)
  # OPTIND is global and retains its value after getopts
  # $# reflects the number of non-option arguments remaining after shift in parse_arguments
  if [ $OPTIND -eq 1 ] && [ $# -eq 0 ]; then 
      usage
      exit 0
  fi

  # Check if an operating mode was specified
  if [ -z "$mode" ]; then
      echo "Error: Operating mode not specified (-i for pack or -u for unpack)." >&2
      usage
      exit 1
  fi

  # Execute logic based on mode
  if [ "$mode" == "pack" ]; then
    # Check if any input files were provided via -i
    if [ ${#input_files[@]} -eq 0 ]; then
      echo "Error: At least one input file or folder must be specified for packing using -i." >&2
      usage
      exit 1
    fi

    # Determine the final output file name
    output_file="$DEFAULT_OUTPUT_FILE" # Start with default
    if [ -n "$output_target" ]; then
      output_file="$output_target" # User override
    elif [ ${#input_files[@]} -eq 1 ]; then
      # Default name based on single input
      local single_input_basename=""
      local single_input_cleaned="${input_files[0]%/}"
      if [[ -n "$single_input_cleaned" ]]; then
          single_input_basename=$(basename -- "$single_input_cleaned")
      fi
      if [[ -n "$single_input_basename" && "$single_input_basename" != "." && "$single_input_basename" != "/" ]]; then
          output_file="${single_input_basename}.tar.zst"
          echo "Info: No output name specified (-o). Defaulting to '$output_file' based on single input." >&2
      else
          echo "Warning: Could not determine a valid base name from input '${input_files[0]}'. Falling back to default '$DEFAULT_OUTPUT_FILE'." >&2
          # output_file remains $DEFAULT_OUTPUT_FILE
      fi
    fi
    # else: multiple inputs, no -o -> output_file remains $DEFAULT_OUTPUT_FILE
    
    # Check if the determined output path is explicitly a directory
    if [ -d "$output_file" ] || [[ "$output_file" == */ ]]; then
      echo "Error: Output path ('$output_file') cannot be a directory." >&2
      usage
      exit 1
    fi

    check_deps || exit 1
    pack_files "$output_file" "$compression_level" "${input_files[@]}"

  elif [ "$mode" == "unpack" ]; then
    # Assign destination directory (can be default or from -o)
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

    # Check if archive name was provided via -u (redundant check, already done in parse_arguments)
    # if [ -z "$unpack_archive_name" ]; then ... 

    check_deps || exit 1
    unpack_archive "$unpack_archive_name" "$output_dir"
  
  # No final else needed, mode is guaranteed to be pack or unpack here
  fi
}

# --- Script Execution ---

parse_arguments "$@"
main

# Exit 0 if main logic completes successfully
exit 0 
