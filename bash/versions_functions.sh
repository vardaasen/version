#!/usr/bin/env bash

fetch_live_version() {
  local repo=$1
  local raw_version=""
  local strategy_func="_fetch_strategy_github_api"

  if [[ -v FETCH_STRATEGIES[$repo] ]]; then
    strategy_func=${FETCH_STRATEGIES[$repo]}
  fi

  raw_version=$("$strategy_func" "$repo")

  if [[ -z "$raw_version" ]]; then
    die "E_API_FAIL" "for repo '$repo'"
  fi

  # Clean the raw version string
  echo "$raw_version" | sed -e 's/^v//' -e 's/^jq-//' -e 's/^v[iv]m-//'
}

determine_repo_status() {
  if is_cache_valid "$cached_version" "$last_checked" "$current_time"; then
    handle_cached_hit
  else
    handle_cache_miss
  fi
}

is_cache_valid() {
  local version=$1
  local last_check_time=$2
  local current_check_time=$3

  if [[ ! "$current_check_time" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local duration=${CACHE_DURATION:-3600}

  # Require version to be non-empty
  if [[ -z "$version" ]]; then
    return 1
  fi
  # Ensure last_check_time is numeric
  if [[ ! "$last_check_time" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  (( current_check_time - last_check_time < duration ))
}

handle_cache_miss() {
  local live_version
  live_version=$(fetch_live_version "$repo")

  if [[ -n "$live_version" && "$live_version" != "null" ]]; then
    handle_live_success "$live_version"
  else
    handle_live_failure
  fi
}

handle_cached_hit() {
  version_to_print="$cached_version"
  status="OK (Cached)"
  color=${colors[GREEN]}
  if [[ "$last_status" == "FAILED" ]]; then
    status="Stale (Failed Last)"
    color=${colors[YELLOW]}
  fi
}

handle_live_success() {
  local live_version=$1
  version_to_print="$live_version"
  status="OK (Live)"
  color=${colors[GREEN]}
  update_db_record "$repo" "$version_to_print" "OK"
  last_checked=$current_time
}

handle_live_failure() {
  version_to_print="$cached_version"
  if [[ "$last_status" == "FAILED" ]]; then
    status="FAILED (Again)"
    color=${colors[RED]}
  else
    status="FAILED (Once)"
    color=${colors[YELLOW]}
  fi
  update_db_record "$repo" "" "FAILED"
}

get_repo_line() {
  local human_date
  human_date=$(date -r "${last_checked:-$current_time}" "+%Y-%m-%d %H:%M")
  # Use printf with -v to save the output to a variable instead of printing
  printf -v line "%-30s %-15s ${color}%-20s${colors[NC]} %s" "$repo:" "$version_to_print" "$status" "$human_date"
  echo "$line"
}

# Layout templates
print_check_status() {
  printf "🔎 Checking upstream versions %s...\n" "$TIME_STR"
}

print_separator() {
  echo "----------------------------------------------------------------"
}

print_header() {
  printf "%-25s %-15s %s\n" "Repository:" "Version:" "Status:"
}

print_template() {
  print_check_status
  print_separator
  print_header
  print_separator
}

# Helpers
# Strategy 1: Use git ls-remote for special cases
_fetch_strategy_git_ls_remote() {
  local repo=$1
  GIT_TERMINAL_PROMPT=0 \
    git ls-remote --tags --sort="v:refname" "https://github.com/$repo" 2>/dev/null \
    | grep -v -E '(rc|a|b)[0-9]*$' \
    | tail -n 1 \
    | sed 's/.*\///; s/\^{}//'
}

# Strategy 2 (Default): Use the GitHub API
_fetch_strategy_github_api() {
  local repo=$1

  if [[ -z "$GITHUB_TOKEN" ]]; then
    die "E_NO_TOKEN"
  fi

  curl -s -S -H "Authorization: Bearer $GITHUB_TOKEN" 2>/dev/null \
    "https://api.github.com/repos/$repo/releases/latest" \
    | jq -r .tag_name
}


# error
die() {
  local error_code=$1
  local extra_info=$2
  local error_message
  local extra_info_formatted
  
  if [[ -v ERRORS[$error_code] ]]; then
    error_message=${ERRORS[$error_code]}
  else
    error_message="An unknown error occured"
    extra_info="(code: $error_code)"
  fi
  
  extra_info_formatted="${extra_info:+ $extra_info}"

  printf "${colors[RED]}Error: %s%s${colors[NC]}\n" \
    "$error_message" \
    "$extra_info_formatted" >&2
  
  exit 1
}
