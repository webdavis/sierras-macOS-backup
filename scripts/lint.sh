#!/usr/bin/env bash

# Exit immediately if any command fails, or if any variables are unset.
set -eu

# Target files:
BREWFILE="dot_Brewfile"
FLAKE_NIX_FILE="flake.nix"

# Ensure this script runs from the project root.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
cd "$PROJECT_ROOT"

if [ ! -f "$BREWFILE" ]; then
  echo "Error: '$BREWFILE' is missing in the project root ($PROJECT_ROOT). Linting aborted." >&2
  exit 1
fi

echo "RuboCop path: $(bundle exec which rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo

echo "Linting '${BREWFILE}' with RuboCop..."
bundle exec rubocop --display-time -- "$BREWFILE"

echo "Linting '${FLAKE_NIX_FILE}' with nix fmt..."
nix fmt "$FLAKE_NIX_FILE"
