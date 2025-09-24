#!/usr/bin/env bash
declare -A ERRORS

read -r -d '' E_NO_TOKEN <<EOF
==============================[ ERROR ]===============================

[!] GITHUB_TOKEN environment variable is not set.

------------------------------[ SOLUTION ]------------------------------

You must create a GitHub Personal Access Token and export it as an
environment variable.

  > Go here to create a new token:
    https://github.com/settings/personal-access-tokens/new

  > Required Settings:
    • Repository access:  All repositories
    • Permissions:        Contents -> Read-only

------------------------------------------------------------------------
EOF

read -r -d '' E_API_FAIL <<EOF
Failed to fetch version from GitHub API for repo
EOF

read -r -d '' E_NO_REPOS <<EOF
Repository file not found at
EOF

ERRORS[E_NO_TOKEN]="$E_NO_TOKEN"
ERRORS[E_API_FAIL]="$E_API_FAIL"
ERRORS[E_NO_REPOS]="$E_NO_REPOS"

declare -A FETCH_STRATEGIES
FETCH_STRATEGIES=(
  ["git/git"]="_fetch_strategy_git_ls_remote"
  ["python/cpython"]="_fetch_strategy_git_ls_remote"
)
