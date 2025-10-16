#!/usr/bin/env bash

# Exit immediately if any variables are unset.
set -u

declare_global_variables() {
  # Target files:
  declare -g \
    BREWFILE \
    NIX_FLAKE_FILE \
    README \
    BREW_SYNC_CHECK

  BREWFILE="dot_Brewfile"
  NIX_FLAKE_FILE="flake.nix"
  README="README.md"
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

get_script_path() {
  git ls-files --full-name "${BASH_SOURCE[0]}"
}

disable_all_traps() {
  trap - SIGINT SIGTERM EXIT
}

cleanup() {
  # cleanup is triggered via the trap command in `setup_signal_handling` on the following signals:
  #   ∙ SIGINT  : Interrupt (Ctrl+C)
  #   ∙ SIGTERM : Termination signal
  #   ∙ EXIT    : Normal script exit

  # Exit with the status of the command that triggered this trap.
  local status="$?"
  (( "$status" == 0 )) && status="$EXIT_CODE"

  disable_all_traps

  local snapshots=(
    "${BREWFILE_SNAPSHOT:-}"
    "${NIX_FLAKE_FILE_SNAPSHOT:-}"
    "${README_SNAPSHOT:-}"
    "${SCRIPT_SNAPSHOT:-}"
    "${BREW_SYNC_CHECK_SNAPSHOT:-}"
  )

  for s in "${snapshots[@]}"; do
    [[ -f "$s" ]] && rm -- "$s"
  done

  exit "$status"
}

setup_signal_handling() {
  # Handle process interruption signals.
  trap cleanup SIGINT SIGTERM

  # Handle the EXIT signal for any script termination.
  trap cleanup EXIT
}

in_nix_dev_shell() {
  # The IN_NIX_SHELL environment variable is only present in Nix flake dev shells.
  case "${IN_NIX_SHELL:-}" in
    pure | impure) return 0 ;;
    *) return 1;;
  esac
}

generate_error_mode_metadata() {
  local file="$1"
  local ci_mode="$2"

  local error_prefix
  local ci_suffix

  if $ci_mode; then
    error_prefix="::error file=${file}::"
    ci_suffix=" --ci"
  else
    error_prefix="Error:"
    ci_suffix=""
  fi

  echo "$error_prefix" "$ci_suffix"
}

print_nix_shell_error() {
  local file="$1"
  local error_prefix="$2"
  local ci_suffix="$3"

  local message="${error_prefix} ${file} must be run inside a Nix flake development shell.

To enter the flake shell, run:
  $ nix develop
  $ ./${file}${ci_suffix}

Alternatively, you can run this script ad hoc without entering the shell:
  $ nix develop .#adhoc --command ./${file}${ci_suffix}"

  printf "%s\n" "$message" >&2
}

ensure_nix_shell() {
  local file="$1"
  local ci_mode="$2"

  in_nix_dev_shell && return 0

  local error_prefix ci_suffix
  read -r error_prefix ci_suffix <<< "$(generate_error_mode_metadata "$file" "$ci_mode")"

  print_nix_shell_error "$file" "$error_prefix" "$ci_suffix"

  exit 1
}

parse_script_flags() {
  local ci_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ci)
        ci_mode=true
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

  echo "$ci_mode"
}

change_to_project_root() {
  # Ensure this script runs from the project root.
  declare -g PROJECT_ROOT
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -z "${PROJECT_ROOT:-}" ]]; then
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
    if [[ ! -f "$file" ]]; then
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
  local ci_mode="$5"

  if [[ "$tool_status" -eq 1 ]]; then
    if $ci_mode; then
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

    field="$(trim "$field")"

    length=${#field}

    ((length > max_length)) && max_length=$length
  done

  echo "$max_length"
}

run_nixfmt() {
  local ci_mode="$1"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  NIXFMT (FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
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

  git_diff_section "$NIX_FLAKE_FILE_SNAPSHOT" "$NIX_FLAKE_FILE" "Nixfmt" "$NIXFMT_EXIT_CODE" "$ci_mode"
}

run_rubocop() {
  local ci_mode="$1"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  RUBOCOP (LINTING & FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "RuboCop path: $(bundle exec command -v rubocop)"
  echo "RuboCop version: $(bundle exec rubocop -v)"
  echo

  declare -g BREWFILE_SNAPSHOT
  BREWFILE_SNAPSHOT="$(file_snapshot "$BREWFILE" ".brewfile")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running RuboCop on '${BREWFILE}' (linting, formatting, and applying corrections)..."
  bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$BREWFILE" || RUBOCOP_EXIT_CODE=1
  echo

  git_diff_section "$BREWFILE_SNAPSHOT" "$BREWFILE" "RuboCop" "$RUBOCOP_EXIT_CODE" "$ci_mode"
}

run_mdformat() {
  local ci_mode="$1"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  MDFORMAT (FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "mdformat path: $(command -v mdformat)"
  echo "mdformat version: $(mdformat --version)"
  echo

  declare -g README_SNAPSHOT
  README_SNAPSHOT="$(file_snapshot "$README" ".readme.md")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running mdformat on '${README}' (applying formatting)..."
  mdformat --check "$README" || MDFORMAT_EXIT_CODE=1
  mdformat "$README"
  echo

  git_diff_section "$README_SNAPSHOT" "$README" "Mdformat" "$MDFORMAT_EXIT_CODE" "$ci_mode"
}

run_shellcheck() {
  local ci_mode="$1"
  local script="$2"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  SHELLCHECK (LINTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "shellcheck path: $(command -v shellcheck)"
  echo "shellcheck version: $(shellcheck --version | awk '/^version:/ {print $2}')"
  echo

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running shellcheck on '${script}' (linting)..."
  if $ci_mode; then
    shellcheck --format=gcc "$script" 2>&1 | while IFS=: read -r file line column severity message; do
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
    shellcheck "$script" || SHELLCHECK_EXIT_CODE_SCRIPT=1
  fi
  echo

  echo "Running shellcheck on '${BREW_SYNC_CHECK}' (linting)..."
  if $ci_mode; then
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
}

run_shfmt() {
  local ci_mode="$1"
  local script="$2"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  SHFMT (FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "shfmt path: $(command -v shfmt)"
  echo "shfmt version: $(shfmt --version)"
  echo

  declare -g SCRIPT_SNAPSHOT
  SCRIPT_SNAPSHOT="$(file_snapshot "$script" ".${script##*/}")"

  declare -g BREW_SYNC_CHECK_SNAPSHOT
  BREW_SYNC_CHECK_SNAPSHOT="$(file_snapshot "$BREW_SYNC_CHECK" ".brew_sync_check.sh")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running shfmt on '${script}' (applying formatting)..."
  shfmt -i 2 -ci -s --diff "$script" >/dev/null 2>&1 || SHFMT_EXIT_CODE_SCRIPT=1
  shfmt -i 2 -ci -s --write "$script"
  echo
  git_diff_section "$SCRIPT_SNAPSHOT" "$script" "shfmt" "$SHFMT_EXIT_CODE_SCRIPT" "$ci_mode"

  echo "Running shfmt on '${BREW_SYNC_CHECK}' (applying formatting)..."
  shfmt -i 2 -ci -s --diff "$BREW_SYNC_CHECK" >/dev/null 2>&1 || SHFMT_EXIT_CODE_BREW_SYNC_CHECK=1
  shfmt -i 2 -ci -s --write "$BREW_SYNC_CHECK"
  echo
  git_diff_section "$BREW_SYNC_CHECK_SNAPSHOT" "$BREW_SYNC_CHECK" "shfmt" "$SHFMT_EXIT_CODE_BREW_SYNC_CHECK" "$ci_mode"
}

build_tool_statuses() {
  local script="$1"

  local script_basename brew_sync_check_file
  script_basename="${script##*/}"
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
    "Shellcheck : ${script_basename}      : $SHELLCHECK_EXIT_CODE_SCRIPT"
    "Shellcheck : ${brew_sync_check_file} : $SHELLCHECK_EXIT_CODE_BREW_SYNC_CHECK"
    "shfmt      : ${script_basename}      : $SHFMT_EXIT_CODE_SCRIPT"
    "shfmt      : ${brew_sync_check_file} : $SHFMT_EXIT_CODE_BREW_SYNC_CHECK"
  )
}

generate_summary_output() {
  # Generate a dynamic separator.
  local max_tool_length max_file_length
  max_tool_length=$(max_field_length 0 ":" "${TOOL_STATUSES[@]}")
  max_file_length=$(max_field_length 1 ":" "${TOOL_STATUSES[@]}")

  local tool_separator file_separator
  tool_separator="$(printf '%*s' "$max_tool_length" '' | tr ' ' '-')"
  file_separator="$(printf '%*s' "$max_file_length" '' | tr ' ' '-')"

  EXIT_CODE=0

  local field1="Tool"
  local field2="File"
  local field3="Result"

  OUTPUT_MD="| ${field1} | ${field2} | ${field3} |\n"
  OUTPUT_MD+="---|---|---|\n"

  OUTPUT_CONSOLE="${field1}\t${field2}\t${field3}\n"
  OUTPUT_CONSOLE+="${tool_separator}\t${file_separator}\t-------\n"

  local entry tool file code
  for entry in "${TOOL_STATUSES[@]}"; do
    IFS=":" read -r tool file code <<<"$entry"

    # Trim whitespace:
    tool=$(trim "$tool")
    file=$(trim "$file")

    local checkmark
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
}

print_summary_to_console() {
  printf "%b" "$OUTPUT_CONSOLE" | column -t -s $'\t'
}

print_summary_to_gh_workflow() {
  local ci_mode="$1"

  if $ci_mode; then
    {
      echo "### 📝 Lint／Format Summary"
      echo ""
      printf "%b" "$OUTPUT_MD"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

print_summary() {
  local ci_mode="$1"
  local script="$2"

  echo "┏━━━━━━━━━━━┓"
  echo "┃  SUMMARY  ┃"
  echo "┗━━━━━━━━━━━┛"
  echo

  build_tool_statuses "$script"
  generate_summary_output
  print_summary_to_console
  print_summary_to_gh_workflow "$ci_mode"
}

main() {
  local script
  script="$(get_script_path)"

  setup_signal_handling
  declare_global_variables

  local ci_mode
  ci_mode="$(ci_parse_script_flags "$@")"
  ensure_nix_shell "$script" "$ci_mode"
  change_to_project_root

  require_file "$BREWFILE" "$NIX_FLAKE_FILE" "$README" "$script" "$BREW_SYNC_CHECK"

  run_nixfmt "$ci_mode"
  run_rubocop "$ci_mode"
  run_mdformat "$ci_mode"
  run_shellcheck "$ci_mode" "$script"
  run_shfmt "$ci_mode" "$script"

  print_summary "$ci_mode" "$script"
}

main "$@"
