#!/usr/bin/env bash

# Helpful references for this script:
#
# GitHub Action Workflow Commands:
#
#   - When run with the --ci command flag, this script implements GitHub Action workflow
#     commands to make workflow logs easier to parse (e.g., ::error <args>::). Information on
#     workflow commands can be found here:
#     https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands
#
# Formatting/Linting Tools and their wiki's:
#
#   - Nixfmt (specifically nixfmt-tree): https://github.com/NixOS/nixfmt
#   - RuboCop: https://docs.rubocop.org/rubocop/1.81/index.html
#   - Mdformat: https://mdformat.readthedocs.io/en/stable/
#   - Shellcheck: https://github.com/koalaman/shellcheck/wiki
#   - shfmt: https://github.com/patrickvane/shfmt

# Exit immediately if any variables are unset.
set -u

# Global arrays used to hold script metadata:
declare -A FILES
declare -A EXIT_CODES
declare -a TOOL_STATUSES

# Global array used to hold temporary snapshot files for pre- and post-lint/format comparisons.
# These snapshots are automatically removed up when this script exits via cleanup().
declare -a SNAPSHOTS

set_project_files() {
  FILES=(
    [nix_flake]="flake.nix"
    [brewfile]="dot_Brewfile"
    [readme]="README.md"
    [this_script]="$(get_script_path)"
    [brew_sync_check]="scripts/brew-sync-check.sh"
  )
}

set_tool_exit_codes() {
  EXIT_CODES=(
    [nixfmt]=0
    [rubocop]=0
    [mdformat]=0
    [shellcheck_this_script]=0
    [shellcheck_brew_sync_check]=0
    [shfmt_this_script]=0
    [shfmt_brew_sync_check]=0
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
    [[ -f $s ]] && rm -- "$s"
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
    *) return 1 ;;
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
  local missing_tool=0

  for tool in "${required_tools[@]}"; do
    if [[ $tool == "rubocop" ]]; then
      verify_rubocop || missing_tool=1
    else
      verify_tool "$tool" || missing_tool=1
    fi
  done

  ((missing_tool)) && exit 1
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
  read -r error_prefix ci_suffix <<<"$(generate_error_mode_metadata "$file" "$ci_mode")"

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

  if [[ -z ${project_root:-} ]]; then
    echo "Error: could not determine project root directory (are you in a Git repository?)" >&2
    exit 1
  fi

  if ! cd "$project_root"; then
    echo "Error: could not change into project root directory (${project_root##*/})" >&2
    exit 1
  fi
}

require_file() {
  local project_root="$1"

  local missing_files=()

  local file
  for file in "${FILES[@]}"; do
    if [[ ! -f $file ]]; then
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

    prefix="${red}Error:"
    suffix="${reset}"
    message="📝 [Diff] → '${file}'\n"
    message+="─────────────────────────────\n"
    message+="$(git_diff "$snapshot" "$file")"
  fi

  printf "%b\n\n" "${prefix} ${tool} detected formatting/linting issues in ${file}. See diff below ↓${suffix}" >&2
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
  local total_width=$((title_length + padding * 2))

  local top bottom middle
  top="┏$(repeat "━" "$total_width")┓"
  middle="┃$(repeat " " "$padding")${title}$(repeat " " "$padding")┃"
  bottom="┗$(repeat "━" "$total_width")┛"

  echo "$top"
  echo "$middle"
  echo "$bottom"
  echo
}

print_tool_info() {
  local tool="$1"

  echo "📌 [Info]"
  echo "───────────"

  if [[ $tool == "rubocop" ]]; then
    echo "${tool} path: $(bundle exec command -v rubocop)"
    echo "${tool} version: $(bundle exec "$tool" --version)"
  else
    echo "${tool} path: $(command -v "${tool}")"
    echo "${tool} version: $("${tool}" --version)"
  fi

  echo
}

print_execution_header() {
  echo "🛠️ [Execution]"
  echo "────────────────"
}

run_tool() {
  local ci_mode="$1"
  local file="$2"
  local project_root="$3"
  local title="$4"
  local tool="$5"
  shift 5
  local -a command=("$@")

  print_section_title "$title"
  print_tool_info "$tool"

  local snapshot=""
  snapshot="$(file_snapshot "$file" ".${file##*/}" "$project_root")"
  SNAPSHOTS+=("$snapshot")

  print_execution_header
  printf 'Running %s on %s...\n' "${tool}" "${file}"

  local status=0

  "${command[@]}" "$file" || status=$?

  echo

  [[ $status -eq 0 ]] || git_diff_section "$snapshot" "$file" "$tool" "$ci_mode"

  return "$status"
}

nixfmt_runner() {
  local file="$1"
  local status=0
  nix fmt -- --ci --quiet "$file" || status="$?"
  return "$status"
}

rubocop_runner() {
  local file="$1"
  local status=0
  bundle exec rubocop --display-time --autocorrect --fail-level autocorrect -- "$file" || status="$?"
  return "$status"
}

mdformat_runner() {
  local file="$1"
  local status=0
  mdformat --check "$file" || status="$?"
  mdformat "$file"
  return "$status"
}

shellcheck_runner() {
  local ci_mode="$1"
  local file="$2"

  local status=0
  if $ci_mode; then
    local f line column severity message
    shellcheck --format=gcc "$file" 2>&1 | while IFS=: read -r f line column severity message; do
      f=$(trim "$f")
      line=$(trim "$line")
      column=$(trim "$column")
      severity=$(trim "$severity")
      message=$(trim "$message")
      [[ $severity != error ]] && severity="warning"
      echo "::${severity} file=${f},line=${line},col=${column}::${f}:${line}:${column}: ${severity}: ${message}"
    done
    status="${PIPESTATUS[0]}"
  else
    shellcheck "$file" || status=$?
  fi

  return "$status"
}

shfmt_runner() {
  local file="$1"
  local status=0

  shfmt -i 2 -ci -s --diff "$file" >/dev/null 2>&1 || status=$?
  shfmt -i 2 -ci -s --write "$file"

  return "$status"
}

run_all_tools() {
  local ci_mode="$1"
  local project_root="$2"

  verify_required_tools "treefmt" "rubocop" "mdformat" "shellcheck" "shfmt"

  local runners=(
    "${FILES[nix_flake]}|NIXFMT (FORMATTING)|treefmt|nix_flake|nixfmt_runner"
    "${FILES[brewfile]}|RUBOCOP (LINTING & FORMATTING)|rubocop|rubocop|rubocop_runner"
    "${FILES[readme]}|MDFORMAT (FORMATTING)|mdformat|mdformat|mdformat_runner"
    "${FILES[this_script]}|SHELLCHECK (LINTING)|shellcheck|shellcheck_this_script|shellcheck_runner|$ci_mode|${FILES[this_script]}"
    "${FILES[brew_sync_check]}|SHELLCHECK (LINTING)|shellcheck|shellcheck_brew_sync_check|shellcheck_runner|$ci_mode|${FILES[brew_sync_check]}"
    "${FILES[this_script]}|SHFMT (FORMATTING)|shfmt|shfmt_this_script|shfmt_runner"
    "${FILES[brew_sync_check]}|SHFMT (FORMATTING)|shfmt|shfmt_brew_sync_check|shfmt_runner"
  )

  local entry file title tool exit_code runner arg1 arg2
  for entry in "${runners[@]}"; do
    IFS='|' read -r file title tool exit_code runner arg1 arg2 <<<"$entry"

    cmd=("$runner")
    [[ -n $arg1 ]] && cmd+=("$arg1")
    [[ -n $arg2 ]] && cmd+=("$arg2")

    run_tool "$ci_mode" "$file" "$project_root" "$title" "$tool" "${cmd[@]}" || {
      EXIT_CODES[$exit_code]="$?"
    }
  done
}

build_tool_statuses() {
  # Map of tools -> file keys:
  local -A tool_file_map=(
    [nixfmt]=nix_flake
    [rubocop]=brewfile
    [mdformat]=readme
    [shellcheck_this_script]=this_script
    [shellcheck_brew_sync_check]=brew_sync_check
    [shfmt_this_script]=this_script
    [shfmt_brew_sync_check]=brew_sync_check
  )

  local ordered_tools=(
    nixfmt
    rubocop
    mdformat
    shellcheck_this_script
    shellcheck_brew_sync_check
    shfmt_this_script
    shfmt_brew_sync_check
  )

  local key tool file
  for key in "${ordered_tools[@]}"; do
    tool="$key"
    file="${FILES[${tool_file_map[$key]}]##*/}"
    TOOL_STATUSES+=("${tool}:${file}:${EXIT_CODES[$key]}")
  done
}

get_rows() {
  local format="$1"
  shift 1
  local output=("$@")

  local entry tool file checkmark rows=""

  for entry in "${output[@]}"; do
    IFS=":" read -r tool file checkmark <<<"$entry"

    # shellcheck disable=SC2059
    rows+="$(printf "$format" "$tool" "$file" "$checkmark")"$'\n'
  done

  printf "%b" "$rows"
}

generate_output() {
  local status=0

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

    printf '%s\n' "${tool}:${file}:${checkmark}"
  done

  return "$status"
}

get_console_divider() {
  local array=("$@")

  local tool_length file_length
  tool_length=$(max_field_length 0 ":" "${output[@]}")
  file_length=$(max_field_length 1 ":" "${output[@]}")

  local tool_separator file_separator
  tool_separator="$(printf '%*s' "$tool_length" '' | tr ' ' '-')"
  file_separator="$(printf '%*s' "$file_length" '' | tr ' ' '-')"

  printf "%b" "$tool_separator\t$file_separator\t-------"
}

build_summary() {
  local -n gs_fields="$1"
  local -n gs_output="$2"
  local format="$3"
  local divider="$4"

  # shellcheck disable=SC2059
  printf "%b" \
    "$(printf "$format" "${gs_fields[@]}")" \
    $'\n' \
    "${divider}" \
    $'\n' \
    "$(get_rows "$format" "${gs_output[@]}")"
}

print_to_console() {
  local summary="$1"
  printf "%b\n" "$summary" | column -t -s $'\t' -c 200
}

write_to_github_step_summary() {
  local summary="$1"
  {
    echo "### 📝 Lint／Format Summary"
    echo ""
    printf "%b" "$summary"
  } >>"$GITHUB_STEP_SUMMARY"
}

summarize_results() {
  local ci_mode="$1"

  print_section_title "SUMMARY"

  build_tool_statuses

  local -a fields=("Tool" "File" "Result")
  local -a output

  local status=0
  mapfile -t output < <(generate_output) || status="$?"

  local console_format="%s\t%s\t%s"
  local console_divider
  console_divider="$(get_console_divider "${output[@]}")"
  print_to_console "$(build_summary "fields" "output" "$console_format" "$console_divider")"

  if $ci_mode; then
    local markdown_format="| %s | %s | %s |"
    local markdown_divider="| --- | --- | --- |"
    write_to_github_step_summary "$(build_summary "fields" "output" "$markdown_format" "$markdown_divider")"
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
  set_project_files

  set_tool_exit_codes

  local project_root
  project_root="$(get_project_root)"
  change_to_project_root "$project_root"

  ensure_nix_shell "${FILES[this_script]}" "$ci_mode"
  require_file "$project_root"

  # --- Run all tools ---
  run_all_tools "$ci_mode" "$project_root"

  # --- Summarize results ---
  local status=0
  summarize_results "$ci_mode" || status="$?"

  return "$status"
}

main "$@"
