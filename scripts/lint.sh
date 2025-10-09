#!/usr/bin/env bash

# Exit immediately if any command fails, or if any variables are unset.
set -eu

# Target files:
BREWFILE="dot_Brewfile"
FLAKE_NIX_FILE="flake.nix"

# Ensure this script runs from the project root.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
cd "$PROJECT_ROOT"

check_file() {
  local file="$1"

  if [ ! -f "$file" ]; then
    echo "Error: '$file' is missing in the project root ($PROJECT_ROOT). Linting aborted." >&2
    exit 1
  fi
}

check_file "$BREWFILE"
echo "RuboCop path: $(bundle exec which rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo "Linting '${BREWFILE}' with RuboCop..."
bundle exec rubocop --display-time -- "$BREWFILE"
echo

check_file "$FLAKE_NIX_FILE"
echo "nix fmt path: $(which treefmt)"
echo "nix fmt version: $(nix fmt -- --version)"
echo "Linting '${FLAKE_NIX_FILE}' with nix fmt..."
nix fmt -- --verbose "$FLAKE_NIX_FILE"
echo
