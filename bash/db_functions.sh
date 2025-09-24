#!/usr/bin/env bash

# --- CONFIGURATION ---
DB_FILE="versions.db"

# --- SQL QUERIES ---
declare -A SQL_QUERIES
SQL_QUERIES=(
  [CREATE_TABLE]="CREATE TABLE IF NOT EXISTS versions (
      repo TEXT PRIMARY KEY,
      version TEXT,
      last_checked INTEGER,
      status TEXT
    );"
  [UPDATE_RECORD]="INSERT OR REPLACE INTO versions (repo, version, last_checked, status) VALUES (?, ?, ?, ?);"
  [SELECT_REPO_DETAILS]="SELECT version, last_checked, status FROM versions WHERE repo=?;"
  [SELECT_LAST_SUCCESS]="SELECT MAX(last_checked) FROM versions WHERE status='OK';"
)

# --- CORE DATABASE FUNCTIONS ---

# Generic function to execute any query
run_query() {
  local query_key=$1
  shift
  local query_template="${SQL_QUERIES[$query_key]}"

  case "$query_key" in
    SELECT_REPO_DETAILS)
      sqlite3 "$DB_FILE" <<EOF
.param set 1 '$1'
$query_template
EOF
      ;;
    UPDATE_RECORD)
      sqlite3 "$DB_FILE" <<EOF
.param set 1 '$1'
.param set 2 '$2'
.param set 3 $3
.param set 4 '$4'
$query_template
EOF
      ;;
    *)
      echo "DEBUG: Executing query: [$query]" >&2
      sqlite3 "$DB_FILE" "$query_template"
      ;;
  esac
}  

# Initializes the database
init_db() {
  run_query "CREATE_TABLE"
}

# --- PUBLIC API FUNCTIONS ---

# Updates a record in the database
update_db_record() {
  local repo=$1
  local version=$2
  local status=$3
  local check_time
  check_time=$(date +%s)
  run_query "UPDATE_RECORD" "$repo" "$version" "$check_time" "$status"
}

# Gets cached data for a specific repository
#get_cached_repo_data() {
#  local repo_name=$1
#  run_query "SELECT_REPO_DETAILS" "$repo_name" | tr '|' ' '
#}

get_cached_repo_data() {
  local repo_name=$1
  echo "DEBUG: Querying for repo: [$repo_name]" >&2
  
  # Test with a simple direct query first
  local direct_result
  direct_result=$(sqlite3 "$DB_FILE" "SELECT version, last_checked, status FROM versions WHERE repo='$repo_name';" | tr '|' ' ')
  echo "DEBUG: Direct query result: [$direct_result]" >&2
  
  # Now test through run_query
  local run_query_result
  run_query_result=$(run_query "SELECT_REPO_DETAILS" "$repo_name")
  echo "DEBUG: run_query result: [$run_query_result]" >&2
  
  echo "$run_query_result" | tr '|' ' '
}

# Calculates time since the last successful check
calculate_last_success() {
  local last_success
  last_success=$(run_query "SELECT_LAST_SUCCESS" 2>/dev/null)

  if [[ -n "$last_success" ]]; then
    local hours_ago=$(( ($(date +%s) - last_success) / 3600 ))
    printf "(last success: %sh ago)" "$hours_ago"
  fi
}

