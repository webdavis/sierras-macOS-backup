#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

# Target files:
BREWFILE="dot_Brewfile"
NIX_FLAKE_FILE="flake.nix"

# Ensure this script runs from the project root.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "${PROJECT_ROOT:-}" ]; then
  echo "Error: could not determine project root directory (are you in a Git repository?)" >&2
  exit 1
fi

if ! cd "$PROJECT_ROOT"; then
  echo "Error: could not change into project root directory (${PROJECT_ROOT})" >&2
  exit 1
fi

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
echo "📌 [Info]"
echo "RuboCop path: $(bundle exec which rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo

original_brewfile="$(mktemp -p "$PROJECT_ROOT" tmp.brewfile.XXXXXX)"
cp "$BREWFILE" "$original_brewfile"

echo "🛠️ [Execution]"
echo "Running RuboCop on '${BREWFILE}' (linting, formatting, and applying corrections)..."
bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$BREWFILE" || RUBOCOP_EXIT_CODE=1
echo

if [ $RUBOCOP_EXIT_CODE -eq 1 ]; then
  echo "📝 [Diff]"
  GIT_CONFIG_GLOBAL=/dev/null git diff --unified=0 --no-index "$original_brewfile" "$BREWFILE"
  echo
fi
rm "$original_brewfile"

check_file "$NIX_FLAKE_FILE"
echo "┏━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  NIXFMT (FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "nixfmt path: $(which treefmt)"
echo "nixfmt version: $(nix fmt -- --version)"
echo

original_nix_flake_file="$(mktemp -p "$PROJECT_ROOT" tmp.flake.XXXXXX.nix)"
cp "$NIX_FLAKE_FILE" "$original_nix_flake_file"

echo "🛠️ [Execution]"
echo "Formatting '${NIX_FLAKE_FILE}' with nixfmt..."
echo "Running nix fmt '${NIX_FLAKE_FILE}' (applying formatting)..."
nix fmt -- --ci --quiet "$NIX_FLAKE_FILE" || NIXFMT_EXIT_CODE=1
echo

if [ $NIXFMT_EXIT_CODE -eq 1 ]; then
  echo "📝 [Diff]"
  GIT_CONFIG_GLOBAL=/dev/null git diff --unified=0 --no-index "$original_nix_flake_file" "$NIX_FLAKE_FILE"
  echo
fi
rm "$original_nix_flake_file"

{
  echo -e "Tool\tStatus"
  echo -e "-------\t-------"
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
