#!/usr/bin/env bash
# shellcheck disable=SC2178

# Exit immediately if any variables are unset.
set -u

# Global array used to hold temporary snapshot files for pre- and post-lint/format comparisons.
# These snapshots are automatically removed up when this script exits via cleanup().
declare -a SNAPSHOTS

get_project_files() {
  local -n files="$1"
  files=(
    [nix_flake]="flake.nix"
    [brewfile]="dot_Brewfile"
    [readme]="README.md"
    [this_script]="$(get_script_path)"
    [brew_sync_check]="scripts/brew-sync-check.sh"
  )
}

get_tool_exit_codes() {
  local -n exit_codes="$1"
  exit_codes=(
    [Nixfmt]=0
    [RuboCop]=0
    [Mdformat]=0
    [Shellcheck_this_script]=0
    [Shellcheck_brew_sync_check]=0
    [Shfmt_this_script]=0
    [Shfmt_brew_sync_check]=0
  )
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

  disable_all_traps

  for s in "${SNAPSHOTS[@]:-}"; do
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

get_project_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

change_to_project_root() {
  # Ensure this script runs from the project root.
  local project_root="$1"

  if [[ -z "${project_root:-}" ]]; then
    echo "Error: could not determine project root directory (are you in a Git repository?)" >&2
    exit 1
  fi

  if ! cd "$project_root"; then
    echo "Error: could not change into project root directory (${project_root##*/})" >&2
    exit 1
  fi
}

require_file() {
  local -n files=$1
  local project_root="$2"

  local missing_files=()

  local file
  for file in "${files[@]}"; do
    if [[ ! -f "$file" ]]; then
      missing_files+=("$file")
    fi
  done

  if ((${#missing_files[@]})); then
    local message="Error: The following required file(s) are missing in the project root (${project_root##*/}): "
    message+="${missing_files[*]}. Linting & formatting aborted."

    echo "$message" >&2
    exit 1
  fi
}

file_snapshot() {
  local file="$1"
  local file_suffix="$2"
  local project_root="$3"

  local snapshot
  snapshot="$(mktemp -p "$project_root" --suffix "$file_suffix")"
  cp "$file" "$snapshot"

  SNAPSHOTS+=("$snapshot")

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
      local red='\033[0;31m'
      local reset='\033[0m' # No Color
      echo -e "${red}Error: ${file} has formatting/linting issues. See diff below ↓${reset}"
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
  local file="$2"
  local project_root="$3"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  NIXFMT (FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "nixfmt path: $(command -v treefmt)"
  echo "nixfmt version: $(nix fmt -- --version)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".flake.nix" "$project_root")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running nix fmt on '${file}' (applying formatting)..."

  local status=0

  nix fmt -- --ci --quiet "$file" || status=$?
  echo

  git_diff_section "$snapshot" "$file" "Nixfmt" "$status" "$ci_mode"

  return "$status"
}

run_rubocop() {
  local ci_mode="$1"
  local file="$2"
  local project_root="$3"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  RUBOCOP (LINTING & FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "RuboCop path: $(bundle exec command -v rubocop)"
  echo "RuboCop version: $(bundle exec rubocop -v)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".brewfile" "$project_root")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running RuboCop on '${file}' (linting, formatting, and applying corrections)..."

  local status=0

  bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$file" || status=$?
  echo

  git_diff_section "$snapshot" "$file" "RuboCop" "$status" "$ci_mode"

  return "$status"
}

run_mdformat() {
  local ci_mode="$1"
  local file="$2"
  local project_root="$3"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  MDFORMAT (FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "mdformat path: $(command -v mdformat)"
  echo "mdformat version: $(mdformat --version)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".readme.md" "$project_root")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running mdformat on '${file}' (applying formatting)..."

  local status=0

  mdformat --check "$file" || status="$?"
  mdformat "$file"
  echo

  git_diff_section "$snapshot" "$file" "Mdformat" "$status" "$ci_mode"

  return "$status"
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

  local status=0

  if $ci_mode; then
    local file line column severity message
    shellcheck --format=gcc "$script" 2>&1 | while IFS=: read -r file line column severity message; do
      file=$(trim "$file")
      line=$(trim "$line")
      column=$(trim "$column")
      severity=$(trim "$severity")
      message=$(trim "$message")

      local github_annotation="$severity"
      if [[ $github_annotation != "error" ]]; then
        github_annotation="warning"
      fi

      echo "::${github_annotation} file=${file},line=${line},col=${column}::${file}:${line}:${column}: ${severity}: ${message}"
    done

    # Capture nonzero exit code for syntax errors etc.
    status="${PIPESTATUS[0]}"
  else
    shellcheck "$script" || status="$?"
  fi
  echo

  return "$status"
}

run_shfmt() {
  local ci_mode="$1"
  local script="$2"
  local project_root="$3"

  echo "┏━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  SHFMT (FORMATTING)  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━┛"
  echo
  echo "📌 [Info]"
  echo "───────────"
  echo "shfmt path: $(command -v shfmt)"
  echo "shfmt version: $(shfmt --version)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$script" ".${script##*/}" "$project_root")"

  echo "🛠️ [Execution]"
  echo "────────────────"
  echo "Running shfmt on '${script}' (applying formatting)..."

  local status=0

  shfmt -i 2 -ci -s --diff "$script" >/dev/null 2>&1 || status="$?"
  shfmt -i 2 -ci -s --write "$script"
  echo

  git_diff_section "$snapshot" "$script" "shfmt" "$status" "$ci_mode"

  return "$status"
}

build_tool_statuses() {
  local -n files="$1"
  local -n exit_codes="$2"

  local script_basename="${files[this_script]##*/}"
  local brew_sync_check_file="${files[brew_sync_check]##*/}"

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
    "Nixfmt     : ${files[nix_flake]}     : ${exit_codes[Nixfmt]}"
    "RuboCop    : ${files[brewfile]}      : ${exit_codes[RuboCop]}"
    "Mdformat   : ${files[readme]}        : ${exit_codes[Mdformat]}"
    "Shellcheck : ${script_basename}      : ${exit_codes[Shellcheck_this_script]}"
    "Shellcheck : ${brew_sync_check_file} : ${exit_codes[Shellcheck_brew_sync_check]}"
    "shfmt      : ${script_basename}      : ${exit_codes[Shfmt_this_script]}"
    "shfmt      : ${brew_sync_check_file} : ${exit_codes[Shfmt_brew_sync_check]}"
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

  local status=0

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
      status=1
    else
      checkmark="✅"
    fi

    OUTPUT_MD+="| ${tool} | \`${file}\` | ${checkmark} |\n"

    OUTPUT_CONSOLE+="${tool}\t${file}\t${checkmark}\n"
  done
  OUTPUT_CONSOLE+="${tool_separator}\t${file_separator}\t-------\n"

  return "$status"
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

  local -n files="$2"
  local -n exit_codes="$3"

  echo "┏━━━━━━━━━━━┓"
  echo "┃  SUMMARY  ┃"
  echo "┗━━━━━━━━━━━┛"
  echo

  build_tool_statuses files exit_codes

  local status
  generate_summary_output || status="$?"

  print_summary_to_console
  print_summary_to_gh_workflow "$ci_mode"

  return "$status"
}

main() {
  local args=("$@")

  setup_signal_handling

  declare -A files
  get_project_files files

  declare -A exit_codes
  get_tool_exit_codes exit_codes

  local ci_mode
  ci_mode="$(parse_script_flags "${args[@]}")"

  ensure_nix_shell "${files[this_script]}" "$ci_mode"

  local project_root
  project_root="$(get_project_root)"
  change_to_project_root "$project_root"

  require_file files "$project_root"

  run_nixfmt "$ci_mode" "${files[nix_flake]}" "$project_root" || exit_codes[Nixfmt]="$?"
  run_rubocop "$ci_mode" "${files[brewfile]}" "$project_root" || exit_codes[RuboCop]="$?"
  run_mdformat "$ci_mode" "${files[readme]}" "$project_root" || exit_codes[Mdformat]="$?"
  run_shellcheck "$ci_mode" "${files[this_script]}" || exit_codes[Shellcheck_this_script]="$?"
  run_shellcheck "$ci_mode" "${files[brew_sync_check]}" || exit_codes[Shellcheck_brew_sync_check]="$?"
  run_shfmt "$ci_mode" "${files[this_script]}" "$project_root" || exit_codes[Shfmt_this_script]="$?"
  run_shfmt "$ci_mode" "${files[brew_sync_check]}" "$project_root" || exit_codes[Shfmt_brew_sync_check]="$?"

  local status=0
  print_summary "$ci_mode" files exit_codes || status="$?"

  return "$status"
}

main "$@"
