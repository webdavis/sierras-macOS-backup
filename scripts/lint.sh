#!/usr/bin/env bash

# Exit immediately if any command fails, or if any variables are unset.
set -eu

# The target file.
TARGET_FILE="dot_Brewfile"

# Ensure this script runs from the project root.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
cd "$PROJECT_ROOT"

if [ ! -f "$TARGET_FILE" ]; then
  echo "Error: '$TARGET_FILE' is missing in the project root ($PROJECT_ROOT). Linting aborted." >&2
  exit 1
fi

echo "RuboCop path: $(bundle exec which rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo

echo "Linting '${TARGET_FILE}' with RuboCop..."
bundle exec rubocop --display-time -- "$TARGET_FILE"
