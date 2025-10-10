#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

# Target files:
BREWFILE="dot_Brewfile"
NIX_FLAKE_FILE="flake.nix"
README="README.md"
SCRIPT="scripts/lint.sh"
BREW_SYNC_CHECK="scripts/brew-sync-check.sh"

cleanup() {
  # Exit with the status of the command that triggered this trap.
  local status=$?

  [ -f "${BREWFILE_SNAPSHOT:-}" ] && rm "$BREWFILE_SNAPSHOT"
  [ -f "${NIX_FLAKE_FILE_SNAPSHOT:-}" ] && rm "$NIX_FLAKE_FILE_SNAPSHOT"
  [ -f "${README_SNAPSHOT:-}" ] && rm "$README_SNAPSHOT"
  [ -f "${SCRIPT_SNAPSHOT:-}" ] && rm "$SCRIPT_SNAPSHOT"
  [ -f "${BREW_SYNC_CHECK_SNAPSHOT:-}" ] && rm "$BREW_SYNC_CHECK_SNAPSHOT"

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

  if ((${#missing_files[@]})); then
    local msg="Error: The following required file(s) are missing in the project root (${PROJECT_ROOT##*/}): "
    msg+="${missing_files[*]}. Linting & formatting aborted."

    echo "$msg" >&2
    exit 1
  fi
}

require_file "$BREWFILE" "$NIX_FLAKE_FILE" "$README" "$SCRIPT" "$BREW_SYNC_CHECK"

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

RUBOCOP_EXIT_CODE=0
NIXFMT_EXIT_CODE=0
MDFORMAT_EXIT_CODE=0
SHELLCHECK_EXIT_CODE=0
SHFMT_EXIT_CODE=0

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
echo "Running nix fmt on '${NIX_FLAKE_FILE}' (applying formatting)..."
nix fmt -- --ci --quiet "$NIX_FLAKE_FILE" || NIXFMT_EXIT_CODE=1
echo

git_diff "$NIX_FLAKE_FILE_SNAPSHOT" "$NIX_FLAKE_FILE" "$NIXFMT_EXIT_CODE"

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

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  MDFORMAT (FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "───────────"
echo "mdformat path: $(command -v mdformat)"
echo "mdformat version: $(mdformat --version)"
echo

README_SNAPSHOT="$(file_snapshot "$README" ".readme.md")"

echo "🛠️ [Execution]"
echo "────────────────"
echo "Running mdformat on '${README}' (applying formatting)..."
mdformat --check "$README" || MDFORMAT_EXIT_CODE=1
mdformat "$README"
echo

git_diff "$README_SNAPSHOT" "$README" "$MDFORMAT_EXIT_CODE"

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  SHELLCHECK (LINTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "───────────"
echo "shellcheck path: $(command -v shellcheck)"
echo "shellcheck version: $(shellcheck --version | awk '/^version:/ {print $2}')"
echo

echo "🛠️ [Execution]"
echo "────────────────"
echo "Running shellcheck on '${SCRIPT}' (linting)..."
shellcheck "$SCRIPT" || SHELLCHECK_EXIT_CODE=1

echo "Running shellcheck on '${BREW_SYNC_CHECK}' (linting)..."
shellcheck "$BREW_SYNC_CHECK" || SHELLCHECK_EXIT_CODE=1
echo

echo "┏━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  SHFMT (FORMATTING)  ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━┛"
echo "📌 [Info]"
echo "───────────"
echo "shfmt path: $(command -v shfmt)"
echo "shfmt version: $(shfmt --version)"
echo

SCRIPT_SNAPSHOT="$(file_snapshot "$SCRIPT" ".lint.sh")"
BREW_SYNC_CHECK_SNAPSHOT="$(file_snapshot "$BREW_SYNC_CHECK" ".brew_sync_check.sh")"

echo "🛠️ [Execution]"
echo "────────────────"
echo "Running shfmt on '${SCRIPT}' (applying formatting)..."
shfmt -i 2 -ci -s --diff "$SCRIPT" >/dev/null 2>&1 || SHFMT_EXIT_CODE=1
shfmt -i 2 -ci -s --write "$SCRIPT"
echo
git_diff "$SCRIPT_SNAPSHOT" "$SCRIPT" "$SHFMT_EXIT_CODE"

echo "Running shfmt on '${BREW_SYNC_CHECK}' (applying formatting)..."
shfmt -i 2 -ci -s --diff "$BREW_SYNC_CHECK" >/dev/null 2>&1 || SHFMT_EXIT_CODE=1
shfmt -i 2 -ci -s --write "$BREW_SYNC_CHECK"
echo
git_diff "$BREW_SYNC_CHECK_SNAPSHOT" "$BREW_SYNC_CHECK" "$SHFMT_EXIT_CODE"

echo "┏━━━━━━━━━━━┓"
echo "┃  SUMMARY  ┃"
echo "┗━━━━━━━━━━━┛"
echo

TOOL_STATUSES=(
  "Nixfmt:$NIXFMT_EXIT_CODE"
  "RuboCop:$RUBOCOP_EXIT_CODE"
  "Mdformat:$MDFORMAT_EXIT_CODE"
  "Shellcheck:$SHELLCHECK_EXIT_CODE"
  "shfmt:$SHFMT_EXIT_CODE"
)

EXIT_CODE=0

OUTPUT="Tool\tStatus\n"
OUTPUT+="-------\t-------\n"

for status in "${TOOL_STATUSES[@]}"; do
  name="${status%%:*}"
  code="${status##*:}"

  if ((code)); then
    line="${name}\t❌\n"
    EXIT_CODE=1
  else
    line="${name}\t✅\n"
  fi
  OUTPUT+="$line"
done

printf "%b" "$OUTPUT" | column -t

[[ $EXIT_CODE -eq 0 ]] || exit 1
