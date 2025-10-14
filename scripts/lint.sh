#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

declare_global_variables() {
  # Target files:
  declare -g \
    BREWFILE \
    NIX_FLAKE_FILE \
    README \
    SCRIPT \
    BREW_SYNC_CHECK

  BREWFILE="dot_Brewfile"
  NIX_FLAKE_FILE="flake.nix"
  README="README.md"
  SCRIPT="scripts/lint.sh"
  BREW_SYNC_CHECK="scripts/brew-sync-check.sh"

  # Script exit code:
  declare -g EXIT_CODE
  EXIT_CODE=0

  # Formatter/linter exit codes:
  declare -g \
    RUBOCOP_EXIT_CODE \
    NIXFMT_EXIT_CODE \
    MDFORMAT_EXIT_CODE \
    SHELLCHECK_EXIT_CODE_SCRIPT \
    SHELLCHECK_EXIT_CODE_BREW_SYNC_CHECK \
    SHFMT_EXIT_CODE_SCRIPT \
    SHFMT_EXIT_CODE_BREW_SYNC_CHECK

  RUBOCOP_EXIT_CODE=0
  NIXFMT_EXIT_CODE=0
  MDFORMAT_EXIT_CODE=0
  SHELLCHECK_EXIT_CODE_SCRIPT=0
  SHELLCHECK_EXIT_CODE_BREW_SYNC_CHECK=0
  SHFMT_EXIT_CODE_SCRIPT=0
  SHFMT_EXIT_CODE_BREW_SYNC_CHECK=0

  # Colors:
  declare -g \
    RED \
    RESET

  RED='\033[0;31m'
  RESET='\033[0m' # No Color
}

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

parse_script_flags() {
  declare -g CI_MODE
  CI_MODE=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ci)
        CI_MODE=true
        shift
        ;;
      --) # End of options.
        shift
        break
        ;;
      -*)
        echo "Error: invalid option '$1'" >&2
        exit 1
        ;;
      *)
        # Positional argument.
        break
        ;;
    esac
  done
}

change_to_project_root() {
  # Ensure this script runs from the project root.
  declare -g PROJECT_ROOT
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "${PROJECT_ROOT:-}" ]; then
    echo "Error: could not determine project root directory (are you in a Git repository?)" >&2
    exit 1
  fi

  if ! cd "$PROJECT_ROOT"; then
    echo "Error: could not change into project root directory (${PROJECT_ROOT##*/})" >&2
    exit 1
  fi
}

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
    local message="Error: The following required file(s) are missing in the project root (${PROJECT_ROOT##*/}): "
    message+="${missing_files[*]}. Linting & formatting aborted."

    echo "$message" >&2
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

  GIT_CONFIG_GLOBAL=/dev/null git diff --color=always --unified=0 --no-index "$snapshot" "$file"
}

git_diff_section() {
  local snapshot="$1"
  local file="$2"
  local tool="$3"
  local tool_status="$4"

  if [ "$tool_status" -eq 1 ]; then
    if $CI_MODE; then
      echo "::error file=${file}::${tool}: detected formatting/linting issues in ${file}. See diff below ↓"

      echo "::group::📝 [Diff] → '${file}'"
      git_diff "$snapshot" "$file" || true
      echo "::endgroup::"
    else
      echo -e "${RED}Error: ${file} has formatting/linting issues. See diff below ↓${RESET}"
      echo "📝 [Diff] → '${file}'"
      echo "─────────────────────────────"
      git_diff "$snapshot" "$file"
      echo
    fi
  fi
}

trim() {
  local var="$1"

  var="${var#"${var%%[![:space:]]*}"}" # Remove leading whitespace.
  var="${var%"${var##*[![:space:]]}"}" # Remove trailing whitespace.

  printf '%s' "$var"
}

max_field_length() {
  # Returns the length of the longest field at the given column index
  # Usage: max_field_length <column_index> ":" "${ARRAY[@]}"
  local index="$1"
  local delimiter="$2"
  shift 2

  local array=("$@")
  local max_length=0
  local item field length
  for item in "${array[@]}"; do
    IFS="$delimiter" read -r -a fields <<<"$item"
    field="${fields[$index]}"

    # Trim leading/trailing whitespace
    field="${field#"${field%%[![:space:]]*}"}"
    field="${field%"${field##*[![:space:]]}"}"

    length=${#field}

    ((length > max_length)) && max_length=$length
  done

  echo "$max_length"
}

build_tool_statuses() {
  local script_file brew_sync_check_file
  script_file="${SCRIPT##*/}"
  brew_sync_check_file="${BREW_SYNC_CHECK##*/}"

  # TOOL_STATUSES array Format:
  #
  #   Tool Name : File Path : Exit Code
  #
  # Each entry represents a tool check:
  #
  #    - Tool Name : The name of the tool (e.g., Nixfmt, RuboCop)
  #    - File Path : The file being checked (e.g., flake.nix, dot_Brewfile)
  #    - Exit Code : The result of the tool execution ($? for that tool)
  #
  TOOL_STATUSES=(
    "Nixfmt     : $NIX_FLAKE_FILE         : $NIXFMT_EXIT_CODE"
    "RuboCop    : $BREWFILE               : $RUBOCOP_EXIT_CODE"
    "Mdformat   : $README                 : $MDFORMAT_EXIT_CODE"
    "Shellcheck : ${script_file}          : $SHELLCHECK_EXIT_CODE_SCRIPT"
    "Shellcheck : ${brew_sync_check_file} : $SHELLCHECK_EXIT_CODE_BREW_SYNC_CHECK"
    "shfmt      : ${script_file}          : $SHFMT_EXIT_CODE_SCRIPT"
    "shfmt      : ${brew_sync_check_file} : $SHFMT_EXIT_CODE_BREW_SYNC_CHECK"
  )
}

main() {
  setup_signal_handling
  declare_global_variables
  parse_script_flags "$@"
  change_to_project_root

  require_file "$BREWFILE" "$NIX_FLAKE_FILE" "$README" "$SCRIPT" "$BREW_SYNC_CHECK"

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

  git_diff_section "$NIX_FLAKE_FILE_SNAPSHOT" "$NIX_FLAKE_FILE" "Nixfmt" "$NIXFMT_EXIT_CODE"

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

  git_diff_section "$BREWFILE_SNAPSHOT" "$BREWFILE" "RuboCop" "$RUBOCOP_EXIT_CODE"

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

  git_diff_section "$README_SNAPSHOT" "$README" "Mdformat" "$MDFORMAT_EXIT_CODE"

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
  if $CI_MODE; then
    shellcheck --format=gcc "$SCRIPT" 2>&1 | while IFS=: read -r file line column severity message; do
    file=$(trim "$file")
    line=$(trim "$line")
    column=$(trim "$column")
    severity=$(trim "$severity")
    message=$(trim "$message")

    github_annotation="$severity"
    if [[ $github_annotation != "error" ]]; then
      github_annotation="warning"
    fi

    echo "::${github_annotation} file=${file},line=${line},col=${column}::${file}:${line}:${column}: ${severity}: ${message}"
  done

  # Capture nonzero exit code for syntax errors etc.
  SHELLCHECK_EXIT_CODE_SCRIPT=${PIPESTATUS[0]}
else
  shellcheck "$SCRIPT" || SHELLCHECK_EXIT_CODE_SCRIPT=1
  fi
  echo

  echo "Running shellcheck on '${BREW_SYNC_CHECK}' (linting)..."
  if [ "${CI_MODE:-false}" = "true" ]; then
    shellcheck --format=gcc "$BREW_SYNC_CHECK" 2>&1 | while IFS=: read -r file line column severity message; do
    file=$(trim "$file")
    line=$(trim "$line")
    column=$(trim "$column")
    severity=$(trim "$severity")
    message=$(trim "$message")

    github_annotation="$severity"
    if [[ $github_annotation != "error" ]]; then
      github_annotation="warning"
    fi

    echo "::${github_annotation} file=${file},line=${line},col=${column}::${file}:${line}:${column}: ${severity}: ${message}"
  done

  # Capture nonzero exit code for syntax errors etc.
  SHELLCHECK_EXIT_CODE_BREW_SYNC_CHECK=${PIPESTATUS[0]}
else
  shellcheck "$BREW_SYNC_CHECK" || SHELLCHECK_EXIT_CODE_BREW_SYNC_CHECK=1
  fi
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
  shfmt -i 2 -ci -s --diff "$SCRIPT" >/dev/null 2>&1 || SHFMT_EXIT_CODE_SCRIPT=1
  shfmt -i 2 -ci -s --write "$SCRIPT"
  echo
  git_diff_section "$SCRIPT_SNAPSHOT" "$SCRIPT" "shfmt" "$SHFMT_EXIT_CODE_SCRIPT"

  echo "Running shfmt on '${BREW_SYNC_CHECK}' (applying formatting)..."
  shfmt -i 2 -ci -s --diff "$BREW_SYNC_CHECK" >/dev/null 2>&1 || SHFMT_EXIT_CODE_BREW_SYNC_CHECK=1
  shfmt -i 2 -ci -s --write "$BREW_SYNC_CHECK"
  echo
  git_diff_section "$BREW_SYNC_CHECK_SNAPSHOT" "$BREW_SYNC_CHECK" "shfmt" "$SHFMT_EXIT_CODE_BREW_SYNC_CHECK"

  echo "┏━━━━━━━━━━━┓"
  echo "┃  SUMMARY  ┃"
  echo "┗━━━━━━━━━━━┛"
  echo

  build_tool_statuses

  # Generate a dynamic separator.
  max_tool_length=$(max_field_length 0 ":" "${TOOL_STATUSES[@]}")
  max_file_length=$(max_field_length 1 ":" "${TOOL_STATUSES[@]}")

  tool_separator="$(printf '%*s' "$max_tool_length" '' | tr ' ' '-')"
  file_separator="$(printf '%*s' "$max_file_length" '' | tr ' ' '-')"

  EXIT_CODE=0

  field1="Tool"
  field2="File"
  field3="Result"

  OUTPUT_MD="| ${field1} | ${field2} | ${field3} |\n"
  OUTPUT_MD+="---|---|---|\n"

  OUTPUT_CONSOLE="${field1}\t${field2}\t${field3}\n"
  OUTPUT_CONSOLE+="${tool_separator}\t${file_separator}\t-------\n"

  for entry in "${TOOL_STATUSES[@]}"; do
    IFS=":" read -r tool file code <<<"$entry"

    # Trim whitespace:
    tool=$(trim "$tool")
    file=$(trim "$file")

    if ((code)); then
      checkmark="❌"
      EXIT_CODE=1
    else
      checkmark="✅"
    fi

    OUTPUT_MD+="| ${tool} | \`${file}\` | ${checkmark} |\n"

    OUTPUT_CONSOLE+="${tool}\t${file}\t${checkmark}\n"
  done
  OUTPUT_CONSOLE+="${tool_separator}\t${file_separator}\t-------\n"

  printf "%b" "$OUTPUT_CONSOLE" | column -t -s $'\t'

  if $CI_MODE; then
    {
      echo "### 📝 Lint／Format Summary"
      echo ""
      printf "%b" "$OUTPUT_MD"
    } >>"$GITHUB_STEP_SUMMARY"
  fi

  [[ $EXIT_CODE -eq 0 ]] || exit 1
}

main "$@"
