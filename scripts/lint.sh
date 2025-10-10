#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

# Target files:
BREWFILE="dot_Brewfile"
NIX_FLAKE_FILE="flake.nix"

cleanup() {
  # Exit with the status of the command that triggered this trap.
  local status=$?

  [ -f "$ORIGINAL_BREWFILE" ] && rm "$ORIGINAL_BREWFILE"
  [ -f "$ORIGINAL_NIX_FLAKE_FILE" ] && rm "$ORIGINAL_NIX_FLAKE_FILE"

  exit $status
}

setup_signal_handling() {
    # Handle process interruption signals.
    trap cleanup SIGINT SIGTERM

    # Handle the EXIT signal for any script termination.
    trap cleanup EXIT
}

setup_signal_handling

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
echo "───────────"
echo "RuboCop path: $(bundle exec which rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo

ORIGINAL_BREWFILE="$(mktemp -p "$PROJECT_ROOT" tmp.brewfile.XXXXXX)"
cp "$BREWFILE" "$ORIGINAL_BREWFILE"

echo "🛠️ [Execution]"
echo "────────────────"
echo "Running RuboCop on '${BREWFILE}' (linting, formatting, and applying corrections)..."
bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$BREWFILE" || RUBOCOP_EXIT_CODE=1
echo

if [ $RUBOCOP_EXIT_CODE -eq 1 ]; then
  echo "📝 [Diff]"
  echo "───────────"
  GIT_CONFIG_GLOBAL=/dev/null git diff --unified=0 --no-index "$ORIGINAL_BREWFILE" "$BREWFILE"
  echo
fi

check_file "$NIX_FLAKE_FILE"
echo "┏━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  NIXFMT (FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "───────────"
echo "nixfmt path: $(which treefmt)"
echo "nixfmt version: $(nix fmt -- --version)"
echo

ORIGINAL_NIX_FLAKE_FILE="$(mktemp -p "$PROJECT_ROOT" tmp.flake.XXXXXX.nix)"
cp "$NIX_FLAKE_FILE" "$ORIGINAL_NIX_FLAKE_FILE"

echo "🛠️ [Execution]"
echo "────────────────"
echo "Formatting '${NIX_FLAKE_FILE}' with nixfmt..."
echo "Running nix fmt '${NIX_FLAKE_FILE}' (applying formatting)..."
nix fmt -- --ci --quiet "$NIX_FLAKE_FILE" || NIXFMT_EXIT_CODE=1
echo

if [ $NIXFMT_EXIT_CODE -eq 1 ]; then
  echo "📝 [Diff]"
  echo "───────────"
  GIT_CONFIG_GLOBAL=/dev/null git diff --unified=0 --no-index "$ORIGINAL_NIX_FLAKE_FILE" "$NIX_FLAKE_FILE"
  echo
fi

echo "┏━━━━━━━━━━━┓"
echo "┃  SUMMARY  ┃"
echo "┗━━━━━━━━━━━┛"
echo

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
