#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

# Target files:
BREWFILE="dot_Brewfile"
NIX_FLAKE_FILE="flake.nix"

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

RUBOCOP_EXIT_CODE=0
NIXFMT_EXIT_CODE=0

check_file "$BREWFILE"
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  RUBOCOP (LINTING & FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "RuboCop path: $(bundle exec which rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo "Linting '${BREWFILE}' with RuboCop..."
bundle exec rubocop --display-time -- "$BREWFILE" || RUBOCOP_EXIT_CODE=1
echo

check_file "$NIX_FLAKE_FILE"
echo "┏━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  NIXFMT (FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "nixfmt path: $(which treefmt)"
echo "nixfmt version: $(nix fmt -- --version)"
echo "Formatting '${NIX_FLAKE_FILE}' with nixfmt..."
nix fmt -- --ci "$NIX_FLAKE_FILE" || NIXFMT_EXIT_CODE=1
echo

{
  echo -e "Tool\tStatus"
  echo -e "-------\t-----"
  for tool in "RuboCop:$RUBOCOP_EXIT_CODE" "nixfmt:$NIXFMT_EXIT_CODE"; do
    IFS=":" read -r name code <<< "$tool"
    if [ "$code" -eq 0 ]; then
      echo -e "$name\t✅"
    else
      echo -e "$name\t❌"
    fi
  done
} | column -t

if [ $RUBOCOP_EXIT_CODE -ne 0 ] || [ $NIXFMT_EXIT_CODE -ne 0 ]; then
  exit 1
fi
