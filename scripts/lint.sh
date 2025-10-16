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
  local exit_status="${1:-$?}"

  disable_all_traps

  for s in "${SNAPSHOTS[@]:-}"; do
    [[ -f "$s" ]] && rm -- "$s"
  done

  exit "$exit_status"
}

setup_signal_handling() {
  # Handle process interruption signals.
  trap 'cleanup $?' SIGINT SIGTERM

  # Handle the EXIT signal for any script termination.
  trap 'cleanup $?' EXIT
}

in_nix_dev_shell() {
  # The IN_NIX_SHELL environment variable is only present in Nix flake dev shells.
  case "${IN_NIX_SHELL:-}" in
    pure | impure) return 0 ;;
    *) return 1;;
  esac
}

verify_rubocop() {
  if ! bundle exec rubocop --version &>/dev/null; then
    printf "%s\n\n" "\
Oops! Looks like you don't have rubocop installed.

Please install it and then try again (e.g. bundle install)" >&2

    return 1
  fi
  return 0
}

verify_tool() {
  local tool="$1"

  if [[ ! -x "$(builtin command -v "$tool")" ]]; then
    printf "%s\n\n" "\
Oops! Looks like you don't have ${tool} installed.

Please install it and then try again (e.g. brew install ${tool})" >&2

    return 1
  fi
  return 0
}

verify_required_tools() {
  local required_tools=("$@")

  local tool
  local missing_tool=false

  for tool in "${required_tools[@]}"; do
    if [[ "$tool" == "rubocop" ]]; then
      verify_rubocop || missing_tool=true
    else
      verify_tool "$tool" || missing_tool=true
    fi
  done

  $missing_tool || exit 1
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
    local f message="Error: The following required file(s) are missing in the project root (${project_root##*/}):\n"
    for f in "${missing_files[@]}"; do
      message+="\t${f}\n"
    done
    message+="Linting & formatting aborted."

    printf "%b\n" "$message" >&2
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
  local ci_mode="$4"

  local message

  local prefix suffix
  if $ci_mode; then
    prefix="::error file=${file}::"
    suffix=""
    message="::group::📝 [Diff] → '${file}'\n"
    message+="$(git_diff "$snapshot" "$file" || true)"
    message+="\n::endgroup::"
  else
    local red='\033[0;31m'
    local reset='\033[0m' # No Color

    prefix="${red}Error: "
    suffix="${reset}"
    message="📝 [Diff] → '${file}'"
    message+="─────────────────────────────\n"
    message+="$(git_diff "$snapshot" "$file")"
  fi

  printf "%s\n" "${prefix}${tool}: detected formatting/linting issues in ${file}. See diff below ↓${suffix}" >&2
  printf "%b\n\n" "$message" >&2
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

repeat() {
  local character="$1"
  local amount="$2"
  for _ in $(seq 1 "$amount"); do
    printf "%s" "$character"
  done
}

print_section_title() {
  local title="$1"

  local title_length="${#title}"

  local padding=2
  local total_width=$((title_length + padding*2))

  local top bottom middle
  top="┏$(repeat "━" "$total_width")┓"
  middle="┃$(repeat " " "$padding")${title}$(repeat " " "$padding")┃"
  bottom="┗$(repeat "━" "$total_width")┛"

  echo "$top"
  echo "$middle"
  echo "$bottom"
  echo
}

print_info_header() {
  echo "📌 [Info]"
  echo "───────────"
}

print_execution_header() {
  echo "🛠️ [Execution]"
  echo "────────────────"
}

run_nixfmt() {
  local ci_mode="$1"
  local file="$2"
  local project_root="$3"

  print_section_title "NIXFMT (FORMATTING)"
  print_info_header
  echo "nixfmt path: $(command -v treefmt)"
  echo "nixfmt version: $(nix fmt -- --version)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".flake.nix" "$project_root")"

  print_execution_header
  echo "Running nix fmt on '${file}' (applying formatting)..."

  local status=0

  nix fmt -- --ci --quiet "$file" || status=$?
  echo

  [[ "$status" -eq 0 ]] || git_diff_section "$snapshot" "$file" "Nixfmt" "$ci_mode"

  return "$status"
}

run_rubocop() {
  local ci_mode="$1"
  local file="$2"
  local project_root="$3"

  print_section_title "RUBOCOP (LINTING & FORMATTING)"
  print_info_header
  echo "RuboCop path: $(bundle exec command -v rubocop)"
  echo "RuboCop version: $(bundle exec rubocop -v)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".brewfile" "$project_root")"

  print_execution_header
  echo "Running RuboCop on '${file}' (linting, formatting, and applying corrections)..."

  local status=0

  bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$file" || status=$?
  echo

  [[ "$status" -eq 0 ]] || git_diff_section "$snapshot" "$file" "RuboCop" "$ci_mode"

  return "$status"
}

run_mdformat() {
  local ci_mode="$1"
  local file="$2"
  local project_root="$3"

  print_section_title "MDFORMAT (FORMATTING)"
  print_info_header
  echo "mdformat path: $(command -v mdformat)"
  echo "mdformat version: $(mdformat --version)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".readme.md" "$project_root")"

  print_execution_header
  echo "Running mdformat on '${file}' (applying formatting)..."

  local status=0

  mdformat --check "$file" || status="$?"
  mdformat "$file"
  echo

  [[ "$status" -eq 0 ]] || git_diff_section "$snapshot" "$file" "Mdformat" "$ci_mode"

  return "$status"
}

run_shellcheck() {
  local ci_mode="$1"
  local script="$2"

  print_section_title "SHELLCHECK (LINTING)"
  print_info_header
  echo "shellcheck path: $(command -v shellcheck)"
  echo "shellcheck version: $(shellcheck --version | awk '/^version:/ {print $2}')"
  echo

  print_execution_header
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
  local file="$2"
  local project_root="$3"

  print_section_title "SHFMT (FORMATTING)"
  print_info_header
  echo "shfmt path: $(command -v shfmt)"
  echo "shfmt version: $(shfmt --version)"
  echo

  local snapshot
  snapshot="$(file_snapshot "$file" ".${file##*/}" "$project_root")"

  print_execution_header
  echo "Running shfmt on '${file}' (applying formatting)..."

  local status=0

  shfmt -i 2 -ci -s --diff "$file" >/dev/null 2>&1 || status="$?"
  shfmt -i 2 -ci -s --write "$file"
  echo

  [[ "$status" -eq 0 ]] || git_diff_section "$snapshot" "$file" "shfmt" "$ci_mode"

  return "$status"
}

run_all_tools() {
  local ci_mode="$1"
  local project_root="$2"
  local -n files="$3"
  local -n exit_codes="$4"

  verify_required_tools "treefmt" "rubocop" "mdformat" "shellcheck" "shfmt"

  run_nixfmt "$ci_mode" "${files[nix_flake]}" "$project_root" || exit_codes[Nixfmt]="$?"
  run_rubocop "$ci_mode" "${files[brewfile]}" "$project_root" || exit_codes[RuboCop]="$?"
  run_mdformat "$ci_mode" "${files[readme]}" "$project_root" || exit_codes[Mdformat]="$?"
  run_shellcheck "$ci_mode" "${files[this_script]}" || exit_codes[Shellcheck_this_script]="$?"
  run_shellcheck "$ci_mode" "${files[brew_sync_check]}" || exit_codes[Shellcheck_brew_sync_check]="$?"
  run_shfmt "$ci_mode" "${files[this_script]}" "$project_root" || exit_codes[Shfmt_this_script]="$?"
  run_shfmt "$ci_mode" "${files[brew_sync_check]}" "$project_root" || exit_codes[Shfmt_brew_sync_check]="$?"
}

build_tool_statuses() {
  local -n tool_statuses="$1"
  local -n files="$2"
  local -n exit_codes="$3"

  # Map of tools -> file keys:
  local -A tool_file_map=(
    [Nixfmt]=nix_flake
    [RuboCop]=brewfile
    [Mdformat]=readme
    [Shellcheck_this_script]=this_script
    [Shellcheck_brew_sync_check]=brew_sync_check
    [Shfmt_this_script]=this_script
    [Shfmt_brew_sync_check]=brew_sync_check
  )

  local key tool file
  for key in "${!tool_file_map[@]}"; do
    tool="$key"
    file="${files[${tool_file_map[$key]}]##*/}"
    tool_statuses+=("${tool} : ${file} : ${exit_codes[$key]}")
  done
}

console_header() {
  local -n table_fields="$1"
  local -n output_ref="$2"

  # Generate a dynamic separator.
  local max_tool_length max_file_length
  max_tool_length=$(max_field_length 0 ":" "${output_ref[@]}")
  max_file_length=$(max_field_length 1 ":" "${output_ref[@]}")

  local tool_separator file_separator
  tool_separator="$(printf '%*s' "$max_tool_length" '' | tr ' ' '-')"
  file_separator="$(printf '%*s' "$max_file_length" '' | tr ' ' '-')"

  local output="${table_fields[0]}\t${table_fields[1]}\t${table_fields[2]}\n"
  output+="${tool_separator}\t${file_separator}\t-------\n"

  printf "%b" "$output"
}

console_row() {
  local tool="$1"
  local file="$2"
  local checkmark="$3"
  printf "%b" "${tool}\t${file}\t${checkmark}\n"
}

markdown_header() {
  local -n table_fields="$1"

  local output="| ${table_fields[0]} | ${table_fields[1]} | ${table_fields[2]} |\n"
  output+="| --- | --- | --- |\n"

  printf "%b" "$output"
}

markdown_row() {
  local tool="$1"
  local file="$2"
  local checkmark="$3"
  printf "%b" "| ${tool} | \`${file}\` | ${checkmark} |\n"
}

format_table() {
  local -n output_ref="$1"
  local -n table_fields="$2"
  local header_formatter="$3"
  local row_formatter="$4"

  local output
  output="$("$header_formatter" table_fields output_ref)"

  local entry tool file checkmark
  for entry in "${output_ref[@]}"; do
    IFS=":" read -r tool file checkmark <<<"$entry"
    output+="$("$row_formatter" "$tool" "$file" "$checkmark")"
  done

  printf "%b" "$output"
}

generate_output_reference() {
  local -n tool_statuses="$1"
  local -n output_ref="$2"

  local status=0

  local entry tool file code
  for entry in "${tool_statuses[@]}"; do
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

    output_ref+=("${tool}:${file}:${checkmark}")
  done

  return "$status"
}

print_to_console() {
  local output="$1"
  printf "%b" "$output" | column -t -s $'\t'
}

write_to_github_step_summary() {
  local output="$1"
  {
    echo "### 📝 Lint／Format Summary"
    echo ""
    printf "%b" "$output"
  } >>"$GITHUB_STEP_SUMMARY"
}

print_summary() {
  local ci_mode="$1"
  local -n files="$2"
  local -n exit_codes="$3"

  print_section_title "SUMMARY"

  declare -a tool_statuses
  build_tool_statuses tool_statuses files exit_codes

  local -a output_ref
  local status
  generate_output_reference tool_statuses output_ref || status="$?"

  local -a table_fields=("Tool" "File" "Result")

  if $ci_mode; then
    write_to_github_step_summary "$(format_table output_ref table_fields markdown_header markdown_row)"
  else
    print_to_console "$(format_table output_ref table_fields console_header console_row)"
  fi

  return "$status"
}

main() {
  # --- Setup ---
  setup_signal_handling

  local args=("$@")
  local ci_mode
  ci_mode="$(parse_script_flags "${args[@]}")"

  # --- Load project context ---
  declare -A files
  get_project_files files

  declare -A exit_codes
  get_tool_exit_codes exit_codes

  local project_root
  project_root="$(get_project_root)"
  change_to_project_root "$project_root"

  ensure_nix_shell "${files[this_script]}" "$ci_mode"
  require_file files "$project_root"

  # --- Run all tools ---
  run_all_tools "$ci_mode" "$project_root" files exit_codes

  # --- Summarize results ---
  local status=0
  print_summary "$ci_mode" files exit_codes || status="$?"

  return "$status"
}

main "$@"
