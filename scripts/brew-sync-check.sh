#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

# Exit immediately if any command fails, or if any variables are unset.
set -euo pipefail

# Commands Stubs
# ———————————————
brewfile_formulas_command() {
  # grep "^brew \"" "$BREWFILE" | sed -E "s/brew \"(.*)\"/\1/" | sort
  grep -E '^\s*brew ['\'']' "$BREWFILE" | sed -E "s/brew ['\"]([^'\"]+)['\"].*/\1/" | sort
}

system_leaves_command() {
  brew leaves | sort
}

system_formulas_command() {
  brew list --formula | tr -s " " "\n" | sort
}

promoted_system_leaves_command() {
  printf '%s\n' "${system_leaves[@]}" "${brewfile_dependencies[@]}" | sort -u
}

# Wrapper functions
# ——————————————————
comm_wrapper() {
  local suppressed_columns="$1"
  local -n array1="$2"
  local -n array2="$3"

  comm "$suppressed_columns" <(printf "%s\n" "${array1[@]}") <(printf "%s\n" "${array2[@]}")
}

mapfile_wrapper() {
  # General helper: either calls comm_wrapper or a Bash command.

  local -n target_array="$1"
  local runner="$2"
  shift 2 # Remove the first two args: the target_array (name) and the runner.

  if [[ $runner == "comm_wrapper" ]]; then
    mapfile -t target_array < <(comm_wrapper "$@")
  else
    mapfile -t target_array < <("$@")
  fi
}

# Helper functions
# ——————————————————
set_and_verify_brewfile() {
  BREWFILE="${1:-$HOME/.Brewfile}"

  if [[ ! -f $BREWFILE ]]; then
    printf "Brewfile not found: %s\n" "$BREWFILE" >&2
    exit 1
  fi
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
    if ! verify_tool "$tool"; then
      missing_tool=true
    fi
  done

  if $missing_tool; then
    exit 1
  fi
}

max_array_length() {
  # Find the maximum length of two arrays.

  local -n array1="$1"
  local -n array2="$2"

  local length=${#array1[@]}
  if [ ${#array2[@]} -gt "$length" ]; then
    length=${#array2[@]}
  fi

  echo "$length"
}

print_row() {
  # Uniformly print column rows.

  local c1="$1" c2="$2"

  printf "%-35s %-35s\n" "$c1" "$c2"
}

print_diff_columns() {
  # Form and print columns.

  local -n c1="$1"
  local -n c2="$2"
  local max_length

  if [[ ${#c1[@]} -eq 0 && ${#c2[@]} -eq 0 ]]; then
    printf "No differences found.\n"
    return 0
  fi

  # Find the maximum column length.
  max_length="$(max_array_length c1 c2)"

  # Print headers
  print_row "Only in Brewfile" "Only on System"
  print_row "----------------" "--------------"

  # Print each row
  for ((i = 0; i < max_length; i++)); do
    print_row "${c1[i]:-}" "${c2[i]:-}"
  done

  return 1
}

# Script Execution
# —————————————————
main() {
  # Setup:
  verify_required_tools "brew"
  set_and_verify_brewfile "$@"

  # Homebrew package dumps:
  mapfile_wrapper brewfile_formulas brewfile_formulas_command
  mapfile_wrapper system_leaves system_leaves_command
  mapfile_wrapper system_formulas system_formulas_command

  # Brewfile dependencies: non-leaves that are listed in the Brewfile.
  mapfile_wrapper brewfile_dependencies comm_wrapper "-12" brewfile_formulas system_formulas

  # Combine leaves + promoted dependencies & remove duplicates.
  mapfile_wrapper promoted_system_leaves promoted_system_leaves_command

  # Columns:
  mapfile_wrapper only_in_brewfile comm_wrapper "-23" brewfile_formulas promoted_system_leaves
  mapfile_wrapper only_on_system comm_wrapper "-13" brewfile_formulas promoted_system_leaves

  # Print the side-by-side differences.
  print_diff_columns only_in_brewfile only_on_system || exit 1
}

main "$@"
