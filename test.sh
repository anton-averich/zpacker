#!/bin/bash

# Automated test suite for zpacker.sh

# --- Configuration ---
ZPACKER_SCRIPT="./zpacker.sh" 
TEST_DIR="_test_run_area"    
VERBOSE=false                

# --- Colors (Optional) ---
# Use $'...' ANSI-C Quoting for proper escape sequence interpretation
COLOR_RESET=$'\e[0m'
COLOR_GREEN=$'\e[0;32m'
COLOR_RED=$'\e[0;31m'

# --- Determine Absolute Script Path ---
zpacker_script_abs_path="" 
if [[ "$ZPACKER_SCRIPT" == /* ]]; then 
    zpacker_script_abs_path="$ZPACKER_SCRIPT"
else 
    script_dir=""
    script_dirname=""
    script_dirname=$(dirname -- "$ZPACKER_SCRIPT") || {
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Could not parse directory from ZPACKER_SCRIPT: $ZPACKER_SCRIPT" >&2
        exit 1
    }
    if [[ "$script_dirname" == "." ]]; then
        script_dir=$(pwd -P) 
    else
        script_dir=$(cd -- "$script_dirname" 2>/dev/null && pwd -P) 
    fi

    if [ -z "$script_dir" ]; then
         echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Could not determine absolute directory for ZPACKER_SCRIPT: $ZPACKER_SCRIPT (from dir: $script_dirname)" >&2
         exit 1
    fi
    script_basename=""
    script_basename=$(basename -- "$ZPACKER_SCRIPT") || {
         echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Could not parse basename from ZPACKER_SCRIPT: $ZPACKER_SCRIPT" >&2
         exit 1
    }
    zpacker_script_abs_path="$script_dir/$script_basename"
fi
if [ ! -f "$zpacker_script_abs_path" ] || [ ! -x "$zpacker_script_abs_path" ]; then
     echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Resolved ZPACKER_SCRIPT path not found or not executable: $zpacker_script_abs_path" >&2
     exit 1
fi
echo "[INFO] Using zpacker script at absolute path: $zpacker_script_abs_path"


# --- Test Counters ---
tests_run=0
tests_passed=0
tests_failed=0

# --- Helper Functions ---

log_info() {
    echo -e "[INFO] $1"
}
log_pass() {
    echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} $1"
}
log_fail() {
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $1"
}
log_debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "[DEBUG] $1"
    fi
}

setup() {
    log_info "Setting up test environment in '$TEST_DIR'..."
    rm -rf "$TEST_DIR" 
    rm -f ./*.tar.zst 
    mkdir -p "$TEST_DIR/sub_dir"
    mkdir -p "$TEST_DIR/folder1"
    mkdir -p "$TEST_DIR/no_write_dir" && chmod 555 "$TEST_DIR/no_write_dir" 

    echo "content1" > "$TEST_DIR/file1.txt"
    echo "content2" > "$TEST_DIR/file2.txt"
    echo "nested" > "$TEST_DIR/sub_dir/nested_file.data"
    echo "space" > "$TEST_DIR/file with space.txt"
    echo "inside" > "$TEST_DIR/folder1/inside.txt"

    if [ ! -x "$zpacker_script_abs_path" ]; then
        log_fail "zpacker script '$zpacker_script_abs_path' not found or not executable."
        exit 1
    fi
    log_info "Setup complete."
}

cleanup() {
    log_info "Cleaning up test environment..."
    chmod 755 "$TEST_DIR/no_write_dir" 2>/dev/null || true 
    rm -rf "$TEST_DIR"
    rm -f ./*.tar.zst 
    log_info "Cleanup complete."
}

# Runs a single test case.
# Creates a subdirectory, executes the command, checks exit code and output/artifacts.
run_test() {
    local description="$1"
    local command_to_run_relative="$2" 
    local expected_exit_code="$3"
    shift 3
    local checks_relative=("$@")

    tests_run=$((tests_run + 1))
    local test_subdir="$TEST_DIR/test-$tests_run"
    local original_dir
    original_dir=$(pwd)
    
    log_info "Running test ($tests_run): $description (in $test_subdir)"

    mkdir -p "$test_subdir"
    if ! pushd "$test_subdir" > /dev/null; then
        log_fail "Test '$description' failed: Could not cd into $test_subdir"
        tests_failed=$((tests_failed + 1))
        # Restore original directory before returning
        popd > /dev/null 2>/dev/null || true 
        return 1
    fi

    local output_capture
    local exit_code=0

    # Replace placeholders in the command string
    local command_to_run_adjusted="${command_to_run_relative//\$SCRIPT_PATH/$zpacker_script_abs_path}"
    command_to_run_adjusted="${command_to_run_adjusted//\$TEST_AREA_PARENT/..}" 

    log_debug "Adjusted Command: $command_to_run_adjusted"

    # Execute the command, capturing stdout, stderr, and exit code
    { output_capture=$(bash -c "$command_to_run_adjusted" 2>&1); exit_code=$?; } || true

    log_debug "Raw exit code captured: $exit_code"
    log_debug "Output:\n$output_capture"

    # Check Exit Code
    if [ "$exit_code" -ne "$expected_exit_code" ]; then
        log_fail "Test '$description' failed: Expected exit code $expected_exit_code, but got $exit_code."
        log_debug "Command output was:\n$output_capture"
        tests_failed=$((tests_failed + 1))
        popd > /dev/null 
        return 1
    fi
    log_debug "Exit code check passed ($exit_code == $expected_exit_code)."

    # Perform additional checks
    local check_failed=false
    for check in "${checks_relative[@]}"; do
        local check_cmd="${check%% *}"
        local check_arg_raw="${check#* }"
        # Handle case where check has no argument (e.g., assert_something)
        if [[ "$check_arg_raw" == "$check_cmd" ]]; then
            check_arg_raw=""
        fi
        
        local check_arg=""
        # Adjust path for checks referring to parent dir artifacts ($TEST_AREA_PARENT -> ..)
        # OR keep paths relative if they refer to files inside the test subdir
        if [[ "$check_arg_raw" == *\$TEST_AREA_PARENT* ]]; then
             check_arg="${check_arg_raw//\$TEST_AREA_PARENT/..}"
        elif [[ "$check_cmd" == "assert_contains" ]]; then
             # Don't modify path for text search
             check_arg="$check_arg_raw"
        else
             # Assume path is relative to current test subdir
             check_arg="$check_arg_raw"
        fi

        log_debug "Check: $check_cmd '$check_arg' (Raw: '$check_arg_raw')"

        case "$check_cmd" in
            assert_exists)
                if [ ! -e "$check_arg" ]; then
                    log_fail "Check failed for '$description': assert_exists '$check_arg' - Item not found."
                    check_failed=true
                fi
                ;;
            assert_not_exists)
                 if [ -e "$check_arg" ]; then
                    log_fail "Check failed for '$description': assert_not_exists '$check_arg' - Item was found."
                    check_failed=true
                fi
                ;;
            assert_contains)
                # Use grep -F for fixed string search, -q for quiet
                if ! echo "$output_capture" | grep -Fq -- "$check_arg"; then 
                    log_fail "Check failed for '$description': assert_contains '$check_arg' - Text not found in output."
                    log_debug "Command output was:\n$output_capture"
                    check_failed=true
                fi
                ;;
            *)
                log_fail "Unknown check command '$check_cmd' in test '$description'."
                check_failed=true
                ;;
        esac
        if [ "$check_failed" = true ]; then
            break 
        fi
    done

    popd > /dev/null 

    if [ "$check_failed" = true ]; then
        tests_failed=$((tests_failed + 1))
        return 1
    fi

    log_pass "Test '$description' passed."
    tests_passed=$((tests_passed + 1))
    return 0
}


# --- Test Group Functions ---

run_pack_tests() {
    log_info "--- Starting Pack Tests ---"

    run_test "Pack: Single file, default name" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt' \
             0 \
             "assert_exists file1.txt.tar.zst" \
             "assert_contains Defaulting to 'file1.txt.tar.zst'"

    run_test "Pack: Single folder, default name" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/folder1' \
             0 \
             "assert_exists folder1.tar.zst" \
             "assert_contains Defaulting to 'folder1.tar.zst'"

    run_test "Pack: Single file with path, default name" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/sub_dir/nested_file.data' \
             0 \
             "assert_exists nested_file.data.tar.zst" \
             "assert_contains Defaulting to 'nested_file.data.tar.zst'"

    run_test "Pack: Single file with space in name, default name" \
             '$SCRIPT_PATH -i "$TEST_AREA_PARENT/file with space.txt"' \
             0 \
             "assert_exists file with space.txt.tar.zst" \
             "assert_contains Defaulting to 'file with space.txt.tar.zst'"

    run_test "Pack: Multiple inputs, default name ('archive.tar.zst')" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -i $TEST_AREA_PARENT/folder1' \
             0 \
             "assert_exists archive.tar.zst" \
             "assert_not_exists file1.txt.tar.zst" \
             "assert_not_exists folder1.tar.zst"

    run_test "Pack: Single input with explicit output name (-o)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -o custom_name.tar.zst' \
             0 \
             "assert_exists custom_name.tar.zst" \
             "assert_not_exists file1.txt.tar.zst"

    run_test "Pack: Force overwrite existing archive (-f)" \
             'touch existing.tar.zst && $SCRIPT_PATH -f -i $TEST_AREA_PARENT/file1.txt -o existing.tar.zst' \
             0 \
             "assert_exists existing.tar.zst" \
             "assert_contains Packing successfully completed"

    run_test "Pack: Fail on existing archive without -f" \
             'touch existing.tar.zst && $SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -o existing.tar.zst' \
             1 \
             "assert_exists existing.tar.zst" \
             "assert_contains already exists. Use -f to overwrite."

    run_test "Pack: Compression level 1 (-q 1)" \
             '$SCRIPT_PATH -q 1 -i $TEST_AREA_PARENT/file1.txt -o level1.tar.zst' \
             0 \
             "assert_exists level1.tar.zst" \
             "assert_contains zstd compression level: 1"

    run_test "Pack: Compression level 22 (-q 22 --ultra)" \
             '$SCRIPT_PATH -f -q 22 -i $TEST_AREA_PARENT/file1.txt -o level22.tar.zst' \
             0 \
             "assert_exists level22.tar.zst" \
             "assert_contains zstd compression level: 22" \
             "assert_contains Using zstd options: -T0 -22 --force --ultra"

    run_test "Pack: Edge case input '.' (current dir relative to setup)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/.' \
             0 \
             "assert_exists archive.tar.zst" \
             "assert_contains Warning: Could not determine a valid base name from input" \
             "assert_contains Falling back to default 'archive.tar.zst'"

    run_test "Pack: Fail on edge case input '/'" \
             '$SCRIPT_PATH -i /' \
             1 \
             "assert_contains Error: Archiving the root directory ('/') is not allowed." \
             "assert_not_exists archive.tar.zst"

    run_test "Pack: Fail on non-existent input file" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/non_existent_file.txt' \
             1 \
             "assert_contains Error: Input file or folder not found" \
             "assert_not_exists non_existent_file.txt.tar.zst"

    run_test "Pack: Fail on input file with no read permission" \
             'touch $TEST_AREA_PARENT/no_read.txt && chmod 000 $TEST_AREA_PARENT/no_read.txt && $SCRIPT_PATH -i $TEST_AREA_PARENT/no_read.txt' \
             1 \
             "assert_contains Error: Read permission denied for input" \
             "assert_not_exists no_read.txt.tar.zst"
    # Restore permissions for cleanup
    chmod 644 "$TEST_DIR/no_read.txt" 2>/dev/null || true 

    run_test "Pack: Fail if output directory does not exist (relative to test subdir)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -o non_existent_dir/output.tar.zst' \
             1 \
             "assert_contains Error: Output directory" \
             "assert_contains does not exist" \
             "assert_not_exists non_existent_dir/output.tar.zst"

    run_test "Pack: Fail if output directory is not writable" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -o $TEST_AREA_PARENT/no_write_dir/output.tar.zst' \
             1 \
             "assert_contains Error: Output directory" \
             "assert_contains is not writable" \
             "assert_not_exists $TEST_AREA_PARENT/no_write_dir/output.tar.zst"

    run_test "Pack: Default compression level (no -q)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt' \
             0 \
             "assert_contains zstd compression level: 9" \
             "assert_exists file1.txt.tar.zst"

    run_test "Pack: Fail if output target is existing directory" \
             'mkdir existing_dir && $SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -o existing_dir' \
             1 \
             "assert_contains Error: Output path" \
             "assert_contains cannot be a directory"

    run_test "Pack: Compression level 20 (-q 20 --ultra)" \
             '$SCRIPT_PATH -q 20 -i $TEST_AREA_PARENT/file1.txt -o lvl20.tar.zst' \
             0 \
             "assert_exists lvl20.tar.zst" \
             "assert_contains Using zstd options: -T0 -20 --ultra"
}

run_unpack_tests() {
    log_info "--- Starting Unpack Tests ---"

    log_info "Creating archives for unpack tests (inside main test area)..."
    local ARCHIVE_SINGLE="$TEST_DIR/single_file.tar.zst"
    local ARCHIVE_MULTI="$TEST_DIR/multi_item.tar.zst"
    # Use absolute path here directly as it's now globally defined
    "$zpacker_script_abs_path" -q 1 -f -i "$TEST_DIR/file1.txt" -o "$ARCHIVE_SINGLE" > /dev/null 2>&1
    "$zpacker_script_abs_path" -q 1 -f -i "$TEST_DIR/file1.txt" -i "$TEST_DIR/folder1" -o "$ARCHIVE_MULTI" > /dev/null 2>&1
    log_info "Archives created: $ARCHIVE_SINGLE, $ARCHIVE_MULTI"

    run_test "Unpack: Unpack single file to specified directory (relative)" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst -o unpack_target1' \
             0 \
             "assert_exists unpack_target1/_test_run_area/file1.txt"

    run_test "Unpack: Unpack multiple items to specified directory (relative)" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/multi_item.tar.zst -o unpack_target2' \
             0 \
             "assert_exists unpack_target2/_test_run_area/file1.txt" \
             "assert_exists unpack_target2/_test_run_area/folder1/inside.txt"

    run_test "Unpack: Unpack to current directory (test subdir)" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst' \
             0 \
             "assert_exists _test_run_area/file1.txt"

    run_test "Unpack: Creates target directory if it does not exist (relative)" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst -o new_unpack_dir' \
             0 \
             "assert_exists new_unpack_dir/_test_run_area/file1.txt"

    run_test "Unpack: Fail on non-existent archive" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/non_existent.tar.zst -o unpack_target3' \
             1 \
             "assert_contains Error: Archive not found" \
             "assert_not_exists unpack_target3"

    run_test "Unpack: Fail if target path exists and is a file" \
             'touch existing_file_target && $SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst -o existing_file_target' \
             1 \
             "assert_contains Error: Target path" \
             "assert_contains exists but is not a directory."

    run_test "Unpack: Fail if target directory is not writable" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst -o $TEST_AREA_PARENT/no_write_dir/sub' \
             1 \
             "assert_contains Error: No write permissions for creating directory"

    run_test "Unpack: Fail on corrupted archive (simulated)" \
             'echo "corrupted data" > corrupt.tar.zst && $SCRIPT_PATH -u corrupt.tar.zst -o unpack_target4' \
             1 \
             "assert_contains Error: An error occurred during unpacking." \
             "assert_not_exists unpack_target4/_test_run_area/file1.txt"
}

run_args_tests() {
    log_info "--- Starting Argument/Usage Tests ---"

    run_test "Args: Show help with -h" \
             '$SCRIPT_PATH -h' \
             0 \
             "assert_contains zpacker v" \
             "assert_contains Usage:"

    run_test "Args: Show help with no arguments" \
             '$SCRIPT_PATH' \
             0 \
             "assert_contains Usage:"

    run_test "Args: Fail on invalid option" \
             '$SCRIPT_PATH -x' \
             1 \
             "assert_contains Error: Invalid option: -x" \
             "assert_contains Usage:"

    run_test "Args: Fail on missing argument for -i" \
             '$SCRIPT_PATH -i' \
             1 \
             "assert_contains Error: Option -i requires an argument." \
             "assert_contains Usage:"

    run_test "Args: Fail on missing argument for -u" \
             '$SCRIPT_PATH -u' \
             1 \
             "assert_contains Error: Option -u requires an argument." \
             "assert_contains Usage:"

    run_test "Args: Fail on missing argument for -o (pack)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -o' \
             1 \
             "assert_contains Error: Option -o requires an argument." \
             "assert_contains Usage:"

    run_test "Args: Fail on missing argument for -q" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -q' \
             1 \
             "assert_contains Error: Option -q requires an argument." \
             "assert_contains Usage:"

    run_test "Args: Fail on conflicting modes (-i and -u)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -u $TEST_AREA_PARENT/single_file.tar.zst' \
             1 \
             "assert_contains Error: Cannot use -i (pack) and -u (unpack) simultaneously." \
             "assert_contains Usage:"

    run_test "Args: Fail on invalid compression level (too low)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -q 0' \
             1 \
             "assert_contains Error: Compression level (-q) must be a number between 1 and 22." \
             "assert_contains Usage:"

    run_test "Args: Fail on invalid compression level (too high)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -q 23' \
             1 \
             "assert_contains Error: Compression level (-q) must be a number between 1 and 22." \
             "assert_contains Usage:"

    run_test "Args: Fail on invalid compression level (not a number)" \
             '$SCRIPT_PATH -i $TEST_AREA_PARENT/file1.txt -q abc' \
             1 \
             "assert_contains Error: Compression level (-q) must be a number between 1 and 22." \
             "assert_contains Usage:"

    run_test "Args: Fail on pack mode required but missing (-i)" \
             '$SCRIPT_PATH -o some_archive.tar.zst' \
             1 \
             "assert_contains Error: Operating mode not specified" \
             "assert_contains Usage:"

    run_test "Args: Fail on unpack mode required but missing (-u)" \
             '$SCRIPT_PATH -o some_dir' \
             1 \
             "assert_contains Error: Operating mode not specified" \
             "assert_contains Usage:"

    run_test "Args: Warn on using -q in unpack mode" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst -q 15 -o unpack_q' \
             0 \
             "assert_contains Warning: Option -q (compression level) is ignored during unpack mode." \
             "assert_exists unpack_q/_test_run_area/file1.txt"

    run_test "Args: Warn on using -f in unpack mode" \
             '$SCRIPT_PATH -u $TEST_AREA_PARENT/single_file.tar.zst -f -o unpack_f' \
             0 \
             "assert_contains Warning: Option -f (force overwrite) is ignored during unpack mode." \
             "assert_exists unpack_f/_test_run_area/file1.txt"

    # REMOVED TEST for misplaced options, as the check was removed from zpacker.sh for simplicity
}

# --- Main Test Execution ---

# Enable fail-fast behavior during test execution
set -e
set -o pipefail

trap cleanup EXIT # Ensure cleanup happens even on error exit

# 1. Setup Environment
setup

# 2. Run Test Groups
run_pack_tests
run_unpack_tests
run_args_tests

# 3. Cleanup is handled by trap
# cleanup 

# 4. Print Summary (only reached if all tests passed due to set -e)
log_info "--- Test Summary ---"
echo "Total tests run: $tests_run"
if [ "$tests_failed" -eq 0 ]; then
    echo -e "${COLOR_GREEN}All tests passed!${COLOR_RESET}"
    # Cleanup already done by trap
    exit 0
else
    # This block is unlikely to be reached with set -e unless a check inside run_test fails
    # without exiting the script immediately (which shouldn't happen with current logic).
    # However, keep it for robustness.
    echo -e "${COLOR_RED}Tests passed: $tests_passed${COLOR_RESET}"
    echo -e "${COLOR_RED}Tests failed: $tests_failed${COLOR_RESET}"
    exit 1
fi