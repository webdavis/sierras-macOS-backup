#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

# Target files:
BREWFILE="dot_Brewfile"
NIX_FLAKE_FILE="flake.nix"

cleanup() {
  # Exit with the status of the command that triggered this trap.
  local status=$?

  [ -f "${BREWFILE_SNAPSHOT:-}" ] && rm "$BREWFILE_SNAPSHOT"
  [ -f "${NIX_FLAKE_FILE_SNAPSHOT:-}" ] && rm "$NIX_FLAKE_FILE_SNAPSHOT"

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
  echo "Error: could not change into project root directory (${PROJECT_ROOT##*/})" >&2
  exit 1
fi

require_file() {
  local files=("$@")
  local missing_files=()

  local file
  for file in "${files[@]}"; do
    if [ ! -f "$file" ]; then
      missing_files+=("$file")
    fi
  done

  if (( ${#missing_files[@]} )); then
    local msg="Error: The following required file(s) are missing in the project root (${PROJECT_ROOT##*/}): "
    msg+="${missing_files[*]}. Linting & formatting aborted."

    echo "$msg" >&2
    exit 1
  fi
}

file_snapshot() {
  local file="$1"
  local file_suffix="$2"
  local snapshot
  snapshot="$(mktemp -p "$PROJECT_ROOT" --suffix "$file_suffix")"
  cp "$file" "$snapshot"

  echo "$snapshot"
}

git_diff() {
  local snapshot="$1"
  local file="$2"
  local tool_status="$3"

  if [ "$tool_status" -eq 1 ]; then
    echo "📝 [Diff]"
    echo "───────────"
    GIT_CONFIG_GLOBAL=/dev/null git diff --unified=0 --no-index "$snapshot" "$file"
    echo
  fi
}

require_file "$BREWFILE" "$NIX_FLAKE_FILE"

RUBOCOP_EXIT_CODE=0
NIXFMT_EXIT_CODE=0

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  RUBOCOP (LINTING & FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "───────────"
echo "RuboCop path: $(bundle exec command -v rubocop)"
echo "RuboCop version: $(bundle exec rubocop -v)"
echo

BREWFILE_SNAPSHOT="$(file_snapshot "$BREWFILE" ".brewfile")"

echo "🛠️ [Execution]"
echo "────────────────"
echo "Running RuboCop on '${BREWFILE}' (linting, formatting, and applying corrections)..."
bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$BREWFILE" || RUBOCOP_EXIT_CODE=1
echo

git_diff "$BREWFILE_SNAPSHOT" "$BREWFILE" "$RUBOCOP_EXIT_CODE"

echo "┏━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  NIXFMT (FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "───────────"
echo "nixfmt path: $(command -v treefmt)"
echo "nixfmt version: $(nix fmt -- --version)"
echo

NIX_FLAKE_FILE_SNAPSHOT="$(file_snapshot "$NIX_FLAKE_FILE" ".flake.nix")"

echo "🛠️ [Execution]"
echo "────────────────"
echo "Formatting '${NIX_FLAKE_FILE}' with nixfmt..."
echo "Running nix fmt '${NIX_FLAKE_FILE}' (applying formatting)..."
nix fmt -- --ci --quiet "$NIX_FLAKE_FILE" || NIXFMT_EXIT_CODE=1
echo

git_diff "$NIX_FLAKE_FILE_SNAPSHOT" "$NIX_FLAKE_FILE" "$NIXFMT_EXIT_CODE"

echo "┏━━━━━━━━━━━┓"
echo "┃  SUMMARY  ┃"
echo "┗━━━━━━━━━━━┛"
echo

TOOL_STATUSES=(
  "RuboCop:$RUBOCOP_EXIT_CODE"
  "nixfmt:$NIXFMT_EXIT_CODE"
)

EXIT_CODE=0

OUTPUT="Tool\tStatus\n"
OUTPUT+="-------\t-------\n"

for status in "${TOOL_STATUSES[@]}"; do
  name="${status%%:*}"
  code="${status##*:}"

  if (( code )); then
    line="${name}\t❌\n"
    EXIT_CODE=1
  else
    line="${name}\t✅\n"
  fi
  OUTPUT+="$line"
done

printf "%b" "$OUTPUT" | column -t

[[ $EXIT_CODE -eq 0 ]] || exit 1
