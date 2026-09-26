#!/bin/bash

# Run syntax checks for the project shell scripts.
# ShellCheck is optional and runs only when it is installed.

if ! SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; then
    echo "FAIL: Cannot determine the test script directory."
    exit 1
fi
if ! PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; then
    echo "FAIL: Cannot determine the project directory."
    exit 1
fi

SCRIPT_NAMES="
oracle_linux_8_19c_precheck.sh
oracle_linux_8_19c_full_install.sh
oracle_linux_8_19c_postcheck.sh
"

if ! command -v bash >/dev/null 2>&1; then
    echo "FAIL: bash is required."
    exit 1
fi

echo "=== Bash syntax checks ==="
for SCRIPT_NAME in $SCRIPT_NAMES; do
    SCRIPT_PATH="$PROJECT_DIR/$SCRIPT_NAME"
    if [ -L "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
        echo "FAIL: Script must be a regular file: $SCRIPT_PATH"
        exit 1
    fi
    if ! bash -n "$SCRIPT_PATH"; then
        echo "FAIL: Bash syntax check failed: $SCRIPT_NAME"
        exit 1
    fi
    echo "PASS: $SCRIPT_NAME"
done

echo ""
echo "=== ShellCheck ==="
if command -v shellcheck >/dev/null 2>&1; then
    for SCRIPT_NAME in $SCRIPT_NAMES; do
        if ! shellcheck -x -e SC1090 "$PROJECT_DIR/$SCRIPT_NAME"; then
            echo "FAIL: ShellCheck failed: $SCRIPT_NAME"
            exit 1
        fi
        echo "PASS: $SCRIPT_NAME"
    done
else
    echo "SKIP: ShellCheck is not installed."
fi

echo ""
echo "STATIC CHECK RESULT: PASS"
exit 0
