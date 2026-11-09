#!/usr/bin/env bats
#
# Cache tests: path cache creation, cached runs, incremental discovery, flags.

load test_helper

# =============================================================================
# First run — cache creation
# =============================================================================

@test "first run creates cache file" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
  [[ -f "${HOME}/.cache/asimov/paths" ]]
  assert_cached "${HOME}/Code/My-Project/node_modules"
}

@test "first run with no matches creates cache with only header" {
  run_asimov
  [[ "$status" -eq 0 ]]
  [[ -f "${HOME}/.cache/asimov/paths" ]]
  # Cache should exist but contain no paths (just the header comment)
  local path_count
  path_count="$(read_path_cache | wc -l | tr -d ' ')"
  [[ "$path_count" -eq 0 ]]
}

# =============================================================================
# Cached run — uses cache, skips find
# =============================================================================

@test "cached run uses cache and excludes paths" {
  create_project "Code/My-Project" "package.json" "node_modules"
  # First run: full scan, creates cache
  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
  assert_cached "${HOME}/Code/My-Project/node_modules"

  # Second run: should use cache (output says "Using cached paths")
  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Using cached paths"* ]]
}

@test "stale paths are removed from cache" {
  create_project "Code/My-Project" "package.json" "node_modules"
  create_project "Code/Stale-Project" "Cargo.toml" "target"

  # First run: both projects get cached
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"
  assert_cached "${HOME}/Code/Stale-Project/target"

  # Remove the stale project directory
  rm -rf "${HOME}/Code/Stale-Project"

  # Second run: stale path should be removed from cache
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"
  refute_cached "${HOME}/Code/Stale-Project/target"
}

# =============================================================================
# Incremental discovery via mdfind
# =============================================================================

@test "incremental discovery finds new projects via mdfind" {
  create_project "Code/Existing-Project" "package.json" "node_modules"

  # First run: creates cache with existing project
  run_asimov
  assert_excluded "${HOME}/Code/Existing-Project/node_modules"
  assert_cached "${HOME}/Code/Existing-Project/node_modules"

  # Create a new project that wasn't there during the first scan
  create_project "Code/New-Project" "Cargo.toml" "target"

  # Set up mdfind to report the new project's directory
  ASIMOV_TEST_MDFIND_SENTINEL_RESULTS="${TEST_TEMP_DIR}/.mdfind_sentinel_results"
  export ASIMOV_TEST_MDFIND_SENTINEL_RESULTS
  echo "${HOME}/Code/New-Project/target" > "$ASIMOV_TEST_MDFIND_SENTINEL_RESULTS"

  # Second run: should discover the new project via mdfind
  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/New-Project/target"
  assert_cached "${HOME}/Code/New-Project/target"
}

@test "mdfind candidates without sentinel are skipped on second run" {
  create_project "Code/Existing-Project" "package.json" "node_modules"

  # First run: creates cache
  run_asimov
  assert_cached "${HOME}/Code/Existing-Project/node_modules"

  # Create a directory with no sentinel (false positive from mdfind)
  mkdir -p "${HOME}/Code/No-Sentinel/target"

  ASIMOV_TEST_MDFIND_SENTINEL_RESULTS="${TEST_TEMP_DIR}/.mdfind_sentinel_results"
  export ASIMOV_TEST_MDFIND_SENTINEL_RESULTS
  echo "${HOME}/Code/No-Sentinel/target" > "$ASIMOV_TEST_MDFIND_SENTINEL_RESULTS"

  # First cached run: checks the candidate, finds no sentinel, records it as seen
  run_asimov
  refute_excluded "${HOME}/Code/No-Sentinel/target"
  [[ -f "${HOME}/.cache/asimov/mdfind_seen" ]]
  grep -Fxq "${HOME}/Code/No-Sentinel/target" "${HOME}/.cache/asimov/mdfind_seen"

  # Second cached run: candidate should be filtered by mdfind_seen cache
  run_asimov --verbose
  [[ "$status" -eq 0 ]]
  # The candidate should not appear in "candidates to check" (filtered out)
  [[ "$output" != *"candidates to check"* ]] || [[ "$output" == *"0 new candidates"* ]] || [[ "$output" == *"All"*"already cached"* ]]
}

@test "mdfind candidate without sentinel is not cached" {
  create_project "Code/Existing-Project" "package.json" "node_modules"

  # First run: creates cache
  run_asimov
  assert_cached "${HOME}/Code/Existing-Project/node_modules"

  # Create a directory with no sentinel (false positive from mdfind)
  mkdir -p "${HOME}/Code/No-Sentinel/target"

  ASIMOV_TEST_MDFIND_SENTINEL_RESULTS="${TEST_TEMP_DIR}/.mdfind_sentinel_results"
  export ASIMOV_TEST_MDFIND_SENTINEL_RESULTS
  echo "${HOME}/Code/No-Sentinel/target" > "$ASIMOV_TEST_MDFIND_SENTINEL_RESULTS"

  # Second run: target without sentinel should not be cached or excluded
  run_asimov
  refute_excluded "${HOME}/Code/No-Sentinel/target"
  refute_cached "${HOME}/Code/No-Sentinel/target"
}

# =============================================================================
# Nested path deduplication
# =============================================================================

@test "nested paths in cache are deduped (only outermost excluded)" {
  create_project "Code/My-Project" "package.json" "node_modules"

  # Manually seed the cache with a nested node_modules (as mdfind might discover)
  write_path_cache \
    "${HOME}/Code/My-Project/node_modules" \
    "${HOME}/Code/My-Project/node_modules/dep/node_modules"
  # Create the nested directory so it passes the "exists" check
  mkdir -p "${HOME}/Code/My-Project/node_modules/dep/node_modules"
  echo "sentinel" > "${HOME}/Code/My-Project/node_modules/dep/package.json"

  # Cached run: only the outermost should be excluded (TM exclusions are recursive)
  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
  refute_excluded "${HOME}/Code/My-Project/node_modules/dep/node_modules"
  [[ "$(count_exclusions)" -eq 1 ]]
}

@test "finalize removes nested paths from cache file" {
  create_project "Code/My-Project" "package.json" "node_modules"

  # Seed cache with nested paths
  write_path_cache \
    "${HOME}/Code/My-Project/node_modules" \
    "${HOME}/Code/My-Project/node_modules/dep/node_modules"
  mkdir -p "${HOME}/Code/My-Project/node_modules/dep/node_modules"
  echo "sentinel" > "${HOME}/Code/My-Project/node_modules/dep/package.json"

  run_asimov
  [[ "$status" -eq 0 ]]

  # After finalize, nested path should be removed from cache
  assert_cached "${HOME}/Code/My-Project/node_modules"
  refute_cached "${HOME}/Code/My-Project/node_modules/dep/node_modules"
}

# =============================================================================
# --full-scan
# =============================================================================

@test "--full-scan ignores cache and rebuilds it" {
  create_project "Code/My-Project" "package.json" "node_modules"

  # First run: creates cache
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"

  # Add a new project
  create_project "Code/New-Project" "Cargo.toml" "target"

  # Run with --full-scan: should find the new project via find (not mdfind)
  run_asimov --full-scan
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Scanning for dependency"* ]]
  [[ "$output" != *"Using cached paths"* ]]
  assert_excluded "${HOME}/Code/New-Project/target"
  assert_cached "${HOME}/Code/New-Project/target"
}

# =============================================================================
# --no-cache
# =============================================================================

@test "--no-cache does full scan and does not write cache" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov --no-cache
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
  [[ "$output" == *"Scanning for dependency"* ]]
  # Cache file should not exist
  [[ ! -f "${HOME}/.cache/asimov/paths" ]]
}

@test "--no-cache ignores existing cache" {
  create_project "Code/My-Project" "package.json" "node_modules"

  # First run: creates cache
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"

  # Run with --no-cache: should do full scan, not use cache
  run_asimov --no-cache
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Scanning for dependency"* ]]
  [[ "$output" != *"Using cached paths"* ]]
}

# =============================================================================
# --dry-run with cache
# =============================================================================

@test "--dry-run reads cache but does not write it" {
  create_project "Code/My-Project" "package.json" "node_modules"

  # First run: creates cache (non-dry-run)
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"
  local original_cache
  original_cache="$(cat "${HOME}/.cache/asimov/paths")"

  # Create a new project
  create_project "Code/New-Project" "Cargo.toml" "target"

  ASIMOV_TEST_MDFIND_SENTINEL_RESULTS="${TEST_TEMP_DIR}/.mdfind_sentinel_results"
  export ASIMOV_TEST_MDFIND_SENTINEL_RESULTS
  echo "${HOME}/Code/New-Project/target" > "$ASIMOV_TEST_MDFIND_SENTINEL_RESULTS"

  # Dry run: should read cache but not update it
  run_asimov --dry-run
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Using cached paths"* ]]
  # Cache should not have been updated (new project not added)
  refute_cached "${HOME}/Code/New-Project/target"
}

@test "--dry-run without cache does full scan and does not create cache" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov --dry-run
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Would exclude"* ]]
  # Cache file should not exist
  [[ ! -f "${HOME}/.cache/asimov/paths" ]]
}

# =============================================================================
# Cache read/write axis flags (--no-read-cache / --no-write-cache)
# --full-scan and --no-cache are back-compat aliases.
# =============================================================================

@test "--full-scan and --no-cache together is allowed (both resolve to no read + no write)" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov --full-scan --no-cache
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
  [[ "$output" == *"Scanning for dependency"* ]]
  [[ ! -f "${HOME}/.cache/asimov/paths" ]]
}

@test "--full-scan is an alias for --no-read-cache (ignores cache, rebuilds it)" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"

  run_asimov --no-read-cache
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Scanning for dependency"* ]]
  [[ "$output" != *"Using cached paths"* ]]
  # Rebuilds the cache (write still enabled)
  assert_cached "${HOME}/Code/My-Project/node_modules"
}

@test "--no-write-cache reads the cache but does not update it" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"
  local original_cache
  original_cache="$(cat "${HOME}/.cache/asimov/paths")"

  # A new project discovered via Spotlight on the cached run
  create_project "Code/New-Project" "Cargo.toml" "target"
  ASIMOV_TEST_MDFIND_SENTINEL_RESULTS="${TEST_TEMP_DIR}/.mdfind_sentinel_results"
  export ASIMOV_TEST_MDFIND_SENTINEL_RESULTS
  echo "${HOME}/Code/New-Project/target" > "$ASIMOV_TEST_MDFIND_SENTINEL_RESULTS"

  run_asimov --no-write-cache
  [[ "$status" -eq 0 ]]
  # Reads the cache (fast path), so it is NOT a full scan
  [[ "$output" == *"Using cached paths"* ]]
  # But persists nothing: the newly found project is not added to the cache
  refute_cached "${HOME}/Code/New-Project/target"
  [[ "$(cat "${HOME}/.cache/asimov/paths")" == "$original_cache" ]]
}

@test "--no-cache equals --no-read-cache + --no-write-cache" {
  create_project "Code/My-Project" "package.json" "node_modules"
  # Seed a cache so we can prove reads are ignored
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"

  run_asimov --no-read-cache --no-write-cache
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Scanning for dependency"* ]]   # reads ignored → full scan
  [[ "$output" != *"Using cached paths"* ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

# =============================================================================
# Failed-path persistence
# =============================================================================

@test "tmutil failure is recorded in failed state" {
  create_project "Code/My-Project" "go.mod" "vendor"

  # Configure mock tmutil to fail on this path
  ASIMOV_TEST_TMUTIL_FAIL_PATHS="$(mktemp)"
  export ASIMOV_TEST_TMUTIL_FAIL_PATHS
  echo "${HOME}/Code/My-Project/vendor" > "$ASIMOV_TEST_TMUTIL_FAIL_PATHS"

  run_asimov
  [[ "$status" -eq 0 ]]
  refute_excluded "${HOME}/Code/My-Project/vendor"
  assert_failed "${HOME}/Code/My-Project/vendor"
}

@test "failed read-only paths are skipped on subsequent runs" {
  create_project "Code/Good-Project" "package.json" "node_modules"
  create_project "Code/Bad-Project" "go.mod" "vendor"
  chmod 555 "${HOME}/Code/Bad-Project/vendor"

  # First run: Bad-Project is read-only, so it fails
  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/Good-Project/node_modules"
  refute_excluded "${HOME}/Code/Bad-Project/vendor"
  assert_failed "${HOME}/Code/Bad-Project/vendor"

  # Second run: Bad-Project is still read-only, so it's skipped without a retry
  run_asimov
  local status_copy="$status" output_copy="$output"
  chmod 755 "${HOME}/Code/Bad-Project/vendor"
  [[ "$status_copy" -eq 0 ]]
  [[ "$output_copy" != *"read-only"* ]]
  refute_excluded "${HOME}/Code/Bad-Project/vendor"
  assert_failed "${HOME}/Code/Bad-Project/vendor"
}

@test "failed read-only path is retried once it becomes writable" {
  create_project "Code/Go-Project" "go.mod" "vendor"
  chmod 555 "${HOME}/Code/Go-Project/vendor"
  run_asimov
  assert_failed "${HOME}/Code/Go-Project/vendor"

  # Recreated by the tool (or chmod u+w): writable now
  chmod 755 "${HOME}/Code/Go-Project/vendor"

  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/Go-Project/vendor"
  refute_failed "${HOME}/Code/Go-Project/vendor"
}

@test "path that failed with a tmutil error stays skipped on later runs" {
  create_project "Code/My-Project" "package.json" "node_modules"
  ASIMOV_TEST_TMUTIL_FAIL_PATHS="${TEST_TEMP_DIR}/.tmutil_fail_paths"
  export ASIMOV_TEST_TMUTIL_FAIL_PATHS
  echo "${HOME}/Code/My-Project/node_modules" > "$ASIMOV_TEST_TMUTIL_FAIL_PATHS"
  run_asimov
  assert_failed "${HOME}/Code/My-Project/node_modules"

  log_tmutil_calls
  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"failed to exclude"* ]]
  [[ -z "$(tmutil_calls addexclusion)" ]]
  assert_failed "${HOME}/Code/My-Project/node_modules"
}

@test "failed-state entry whose directory is gone is dropped" {
  mkdir -p "${HOME}/.cache/asimov"
  printf '%s\n' "${HOME}/gone-a" "ro	${HOME}/gone-b" > "${HOME}/.cache/asimov/failed"

  run_asimov
  [[ "$status" -eq 0 ]]
  [[ ! -s "${HOME}/.cache/asimov/failed" ]]
}

@test "--full-scan clears failed state and retries" {
  create_project "Code/My-Project" "go.mod" "vendor"

  # First run: fails
  ASIMOV_TEST_TMUTIL_FAIL_PATHS="$(mktemp)"
  export ASIMOV_TEST_TMUTIL_FAIL_PATHS
  echo "${HOME}/Code/My-Project/vendor" > "$ASIMOV_TEST_TMUTIL_FAIL_PATHS"

  run_asimov
  assert_failed "${HOME}/Code/My-Project/vendor"

  # Remove the failure condition
  rm -f "$ASIMOV_TEST_TMUTIL_FAIL_PATHS"
  unset ASIMOV_TEST_TMUTIL_FAIL_PATHS

  # Full scan should clear failed state and retry successfully
  run_asimov --full-scan
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/vendor"
  refute_failed "${HOME}/Code/My-Project/vendor"
}

# =============================================================================
# Scoped runs
# =============================================================================

@test "cached run with directory argument filters to scoped paths" {
  create_project "Code/My-Project" "package.json" "node_modules"
  create_project "Other/My-Project" "Cargo.toml" "target"

  # First run: full scan, caches both
  run_asimov
  assert_cached "${HOME}/Code/My-Project/node_modules"
  assert_cached "${HOME}/Other/My-Project/target"

  # Second run scoped to Code/: should only process Code/ paths from cache
  run_asimov "${HOME}/Code"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Using cached paths"* ]]
}

# =============================================================================
# Excluded state (issue #139)
#
# ~/.cache/asimov/excluded lets a run skip paths it excluded before, even when
# Spotlight doesn't report them. Each run re-verifies it with one batched
# `tmutil isexcluded` call, so a directory that lost its exclusion is excluded
# again.
# =============================================================================

@test "recreated dependency directory is excluded again" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov
  assert_excluded "${HOME}/Code/My-Project/node_modules"

  recreate_dir "${HOME}/Code/My-Project/node_modules"

  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Using cached paths"* ]]
  [[ "$output" == *"node_modules has been excluded"* ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

@test "recreated extra fixed directory is excluded again" {
  mkdir -p "${HOME}/.custom-cache"
  write_config "[fixed_dirs]
extra = ~/.custom-cache"
  run_asimov
  assert_excluded "${HOME}/.custom-cache"

  recreate_dir "${HOME}/.custom-cache"

  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" == *".custom-cache has been excluded"* ]]
  assert_excluded "${HOME}/.custom-cache"
}

@test "exclusion removed without recreating the directory is applied again" {
  mkdir -p "${HOME}/.custom-cache"
  write_config "[fixed_dirs]
extra = ~/.custom-cache"
  run_asimov
  assert_excluded "${HOME}/.custom-cache"

  # tmutil removeexclusion: the directory stays, its exclusion goes
  : > "$ASIMOV_TEST_EXCLUSIONS"

  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" == *".custom-cache has been excluded"* ]]
  assert_excluded "${HOME}/.custom-cache"
}

@test "excluded state is verified with one batched isexcluded call" {
  mkdir -p "${HOME}/.cache-a" "${HOME}/.cache-b" "${HOME}/.cache-c"
  write_config "[fixed_dirs]
extra = ~/.cache-a
extra = ~/.cache-b
extra = ~/.cache-c"
  run_asimov
  [[ "$(count_exclusions)" -eq 3 ]]

  log_tmutil_calls
  run_asimov --verbose
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Excluded state verified: kept 3 of 3 entries"* ]]
  [[ "$output" == *"3 paths already excluded, skipping."* ]]
  [[ "$(tmutil_calls isexcluded | wc -l | tr -d ' ')" -eq 1 ]]
  [[ "$(tmutil_calls isexcluded)" == *"${HOME}/.cache-a"*"${HOME}/.cache-b"*"${HOME}/.cache-c"* ]]
  [[ -z "$(tmutil_calls addexclusion)" ]]
}

@test "excluded state is trusted as is when tmutil can't read exclusions" {
  mkdir -p "${HOME}/.custom-cache"
  write_config "[fixed_dirs]
extra = ~/.custom-cache"
  run_asimov
  local before
  before="$(read_excluded_state)"

  log_tmutil_calls
  ASIMOV_TEST_TMUTIL_ISEXCLUDED_FAIL=1 run_asimov --quiet
  [[ "$status" -eq 0 ]]
  # A warning on stderr, even under --quiet
  [[ "$output" == *"Could not check ${HOME}/.cache/asimov/excluded"*"trusting it as is"* ]]
  [[ -z "$(tmutil_calls addexclusion)" ]]
  [[ "$(read_excluded_state)" == "$before" ]]
}

# A scheduled run can't read exclusions inside privacy-protected folders such as
# ~/Documents: tmutil says [UNKNOWN] and addexclusion fails. What a terminal run
# excluded there must stay trusted rather than be retried every run.
@test "excluded-state entry tmutil reports as unknown is kept" {
  create_project "Documents/My-Project" "package.json" "node_modules"
  run_asimov
  assert_excluded "${HOME}/Documents/My-Project/node_modules"

  ASIMOV_TEST_TMUTIL_UNKNOWN_PATHS="${TEST_TEMP_DIR}/.tmutil_unknown_paths"
  ASIMOV_TEST_TMUTIL_FAIL_PATHS="$ASIMOV_TEST_TMUTIL_UNKNOWN_PATHS"
  export ASIMOV_TEST_TMUTIL_UNKNOWN_PATHS ASIMOV_TEST_TMUTIL_FAIL_PATHS
  echo "${HOME}/Documents/My-Project/node_modules" > "$ASIMOV_TEST_TMUTIL_UNKNOWN_PATHS"

  log_tmutil_calls
  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"failed to exclude"* ]]
  [[ -z "$(tmutil_calls addexclusion)" ]]
  [[ "$(read_excluded_state)" == "${HOME}/Documents/My-Project/node_modules" ]]
  refute_failed "${HOME}/Documents/My-Project/node_modules"
}

@test "symlinked extra fixed directory stays on the fast path" {
  mkdir -p "${HOME}/real-cache"
  ln -s "${HOME}/real-cache" "${HOME}/.linked-cache"
  write_config "[fixed_dirs]
extra = ~/.linked-cache"
  run_asimov
  assert_excluded "${HOME}/.linked-cache"

  log_tmutil_calls
  run_asimov --verbose
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Excluded state verified: kept 1 of 1 entries"* ]]
  [[ -z "$(tmutil_calls addexclusion)" ]]
}

@test "excluded state is still verified when tmutil prints extra lines" {
  mkdir -p "${HOME}/.custom-cache"
  write_config "[fixed_dirs]
extra = ~/.custom-cache"
  run_asimov
  recreate_dir "${HOME}/.custom-cache"

  ASIMOV_TEST_TMUTIL_ISEXCLUDED_NOISE=1 run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"trusting it as is"* ]]
  [[ "$output" == *".custom-cache has been excluded"* ]]
}

@test "deleted directory is dropped from the excluded state" {
  mkdir -p "${HOME}/.cache-a" "${HOME}/.cache-b"
  write_config "[fixed_dirs]
extra = ~/.cache-a
extra = ~/.cache-b"
  run_asimov
  rm -rf "${HOME}/.cache-b"

  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$(read_excluded_state)" == "${HOME}/.cache-a" ]]
}

@test "excluded state handles paths with spaces" {
  create_project "Code/My Project" "package.json" "node_modules"
  run_asimov
  assert_excluded "${HOME}/Code/My Project/node_modules"

  log_tmutil_calls
  run_asimov
  [[ "$status" -eq 0 ]]
  [[ -z "$(tmutil_calls addexclusion)" ]]
  [[ "$(read_excluded_state)" == "${HOME}/Code/My Project/node_modules" ]]
}

@test "excluded state keeps one line per directory" {
  mkdir -p "${HOME}/.custom-cache"
  write_config "[fixed_dirs]
extra = ~/.custom-cache"
  run_asimov
  [[ "$(read_excluded_state)" == "${HOME}/.custom-cache" ]]

  recreate_dir "${HOME}/.custom-cache"
  run_asimov
  [[ "$(read_excluded_state)" == "${HOME}/.custom-cache" ]]

  run_asimov
  [[ "$status" -eq 0 ]]
  [[ "$(read_excluded_state)" == "${HOME}/.custom-cache" ]]
}

@test "--dry-run and --no-write-cache leave the excluded state untouched" {
  mkdir -p "${HOME}/.cache-a" "${HOME}/.cache-b"
  write_config "[fixed_dirs]
extra = ~/.cache-a
extra = ~/.cache-b"
  run_asimov
  rm -rf "${HOME}/.cache-b"
  recreate_dir "${HOME}/.cache-a"
  local before
  before="$(read_excluded_state)"

  run_asimov --dry-run
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Would exclude: ${HOME}/.cache-a"* ]]
  [[ "$(read_excluded_state)" == "$before" ]]

  run_asimov --no-write-cache
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/.cache-a"
  [[ "$(read_excluded_state)" == "$before" ]]
}

# Spotlight is trusted as reported. Right after a directory is recreated it can
# still list the old exclusion; once it catches up, the next run excludes it.
@test "recreated directory still reported by Spotlight is excluded once Spotlight catches up" {
  create_project "Code/My-Project" "package.json" "node_modules"
  run_asimov
  recreate_dir "${HOME}/Code/My-Project/node_modules"

  ASIMOV_TEST_MDFIND_RESULTS="${TEST_TEMP_DIR}/.mdfind_results"
  export ASIMOV_TEST_MDFIND_RESULTS
  echo "${HOME}/Code/My-Project/node_modules" > "$ASIMOV_TEST_MDFIND_RESULTS"
  run_asimov
  refute_excluded "${HOME}/Code/My-Project/node_modules"

  : > "$ASIMOV_TEST_MDFIND_RESULTS"
  run_asimov
  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

# =============================================================================
# Unusable cache files (issue #122)
#
# A cache is an optimisation. An unreadable or unwritable state file — the state
# a run as root leaves behind — must degrade the run, never abort it.
# =============================================================================

# These tests make files unreadable/unwritable, which has no effect as root.
require_non_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    skip "chmod-based tests are meaningless as root"
  fi
}

@test "run survives an unreadable excluded-state file" {
  require_non_root
  create_project "Code/My-Project" "package.json" "node_modules"
  mkdir -p "${HOME}/.cache/asimov"
  echo "/some/old/path" > "${HOME}/.cache/asimov/excluded"
  chmod 000 "${HOME}/.cache/asimov/excluded"

  run_asimov
  chmod 644 "${HOME}/.cache/asimov/excluded"

  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

@test "unreadable cache prints a warning naming the reset command" {
  require_non_root
  create_project "Code/My-Project" "package.json" "node_modules"
  mkdir -p "${HOME}/.cache/asimov"
  echo "/some/old/path" > "${HOME}/.cache/asimov/excluded"
  chmod 000 "${HOME}/.cache/asimov/excluded"

  run_asimov
  chmod 644 "${HOME}/.cache/asimov/excluded"

  [[ "$output" == *"is not readable"* ]]
  [[ "$output" == *"rm -rf ${HOME}/.cache/asimov"* ]]
}

@test "unreadable cache warns once, not once per file" {
  require_non_root
  create_project "Code/My-Project" "package.json" "node_modules"
  mkdir -p "${HOME}/.cache/asimov"
  echo "/some/old/path" > "${HOME}/.cache/asimov/excluded"
  echo "/some/old/path" > "${HOME}/.cache/asimov/failed"
  chmod 000 "${HOME}/.cache/asimov/excluded" "${HOME}/.cache/asimov/failed"

  run_asimov
  chmod 644 "${HOME}/.cache/asimov/excluded" "${HOME}/.cache/asimov/failed"

  local warnings
  warnings="$(printf '%s\n' "$output" | grep -c "continuing without the cache" || true)"
  [[ "$warnings" -eq 1 ]]
}

@test "run survives an unwritable cache directory" {
  require_non_root
  create_project "Code/My-Project" "package.json" "node_modules"
  mkdir -p "${HOME}/.cache/asimov"
  chmod 500 "${HOME}/.cache/asimov"

  run_asimov
  chmod 700 "${HOME}/.cache/asimov"

  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

@test "full scan survives an unwritable path cache file" {
  require_non_root
  create_project "Code/My-Project" "package.json" "node_modules"
  write_path_cache
  chmod 400 "${HOME}/.cache/asimov/paths"

  # --full-scan has to rewrite the cache, so this exercises the tee'd pipeline
  # that a read-only run never reaches.
  run_asimov --full-scan
  chmod 644 "${HOME}/.cache/asimov/paths"

  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

@test "cached run with an unwritable path cache still excludes what it cached" {
  require_non_root
  create_project "Code/My-Project" "package.json" "node_modules"
  write_path_cache "${HOME}/Code/My-Project/node_modules"
  chmod 400 "${HOME}/.cache/asimov/paths"

  run_asimov
  chmod 644 "${HOME}/.cache/asimov/paths"

  [[ "$status" -eq 0 ]]
  assert_excluded "${HOME}/Code/My-Project/node_modules"
}

@test "prune survives an unreadable path cache" {
  require_non_root
  write_path_cache "${HOME}/gone"
  chmod 000 "${HOME}/.cache/asimov/paths"

  run_asimov prune
  chmod 644 "${HOME}/.cache/asimov/paths"

  [[ "$status" -eq 0 ]]
}
