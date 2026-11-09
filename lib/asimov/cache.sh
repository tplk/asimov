#!/usr/bin/env bash
# shellcheck shell=bash
#
# Asimov's own state under ~/.cache/asimov: the discovered-path cache, the
# excluded/failed state files, and the mdfind_seen list.
#
# Every cache file is an optimisation: a run must survive one being unreadable
# or unwritable rather than aborting. Without the guards below a bare `cat` on an
# unreadable state file fails under `set -Eeu -o pipefail` and kills the whole
# run, printing nothing but "Permission denied" (see issue #122).
#
# The usual cause is a run as root — `sudo asimov`, or a schedule installed as
# root — leaving root-owned files behind for the next run as the user.

ASIMOV_CACHE_WARNED=

# Warn once per run that the cache is unusable, and name the fix. Always goes to
# stderr, including under --quiet: this is a degraded run, not routine chatter.
warn_unusable_cache() {
    [[ -n "$ASIMOV_CACHE_WARNED" ]] && return 0
    ASIMOV_CACHE_WARNED=1
    printf '! %s is not %s — continuing without the cache.\n' "$1" "$2" >&2
    printf '  This usually means a previous run as root left root-owned files behind.\n' >&2
    printf '  To reset it:\n\n    rm -rf %s\n\n' "$ASIMOV_CACHE_DIR" >&2
    return 0
}

# True when a state file exists and can be read. A missing file is not an error
# (there is simply nothing cached yet), so it returns false without warning.
cache_readable() {
    [[ -f "$1" ]] || return 1
    [[ -r "$1" ]] && return 0
    warn_unusable_cache "$1" "readable"
    return 1
}

# True when a state file can be written to, creating it if necessary. An absent
# file is writable when its directory is.
cache_writable() {
    if [[ -e "$1" ]]; then
        [[ -w "$1" ]] && return 0
        warn_unusable_cache "$1" "writable"
        return 1
    fi
    [[ -d "$ASIMOV_CACHE_DIR" && -w "$ASIMOV_CACHE_DIR" ]] && return 0
    [[ -d "$ASIMOV_CACHE_DIR" ]] || return 1   # not created yet; ensure_cache_dir reports
    warn_unusable_cache "$ASIMOV_CACHE_DIR" "writable"
    return 1
}

# Append a line to a state file, skipping silently when it isn't writable.
# Always returns 0 so callers can use it as the tail of an && list under set -e.
append_state() {
    cache_writable "$2" || return 0
    printf '%s\n' "$1" >> "$2" 2>/dev/null || true
    return 0
}

# Print the console user when running as root, so cache files a root run creates
# can be handed back to them (issue #122). Fails when not running as root, or when
# root is the console user.
console_user_for_root_run() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 1
    local console_user
    console_user="$(stat -f '%Su' /dev/console 2>/dev/null || echo '')"
    [[ -n "$console_user" && "$console_user" != "root" ]] || return 1
    printf '%s\n' "$console_user"
}

# Replace a state file with the contents of stdin. The new contents go to a temp
# file in the cache directory first and are moved into place, so an interrupted
# run never leaves a half-written file, and an unchanged file isn't touched. After
# a root run the file is handed back to the console user (issue #122).
# Discards stdin under --dry-run / --no-write-cache, or when the file isn't
# writable. Always returns 0.
#
# Two runs at once (a scheduled one and a manual one) can lose lines the other
# appended in between. That costs the next run a re-check or a retry, never a
# wrong skip.
rewrite_state() {
    local file="$1" console_user
    if [[ -n "$ASIMOV_DRY_RUN" || -n "$ASIMOV_NO_WRITE_CACHE" ]] || ! cache_writable "$file"; then
        cat > /dev/null
        return 0
    fi
    ASIMOV_STATE_TMP="${file}.tmp.$$"
    if { cat > "$ASIMOV_STATE_TMP"; } 2>/dev/null \
        && ! cmp -s "$ASIMOV_STATE_TMP" "$file" \
        && mv -f "$ASIMOV_STATE_TMP" "$file" 2>/dev/null; then
        if console_user="$(console_user_for_root_run)"; then
            chown "$console_user" "$file" 2>/dev/null || true
        fi
    fi
    rm -f "$ASIMOV_STATE_TMP"
    ASIMOV_STATE_TMP=""
    return 0
}

# Print the excluded-state paths that Time Machine hasn't stopped excluding.
# A directory that was deleted and recreated (`rm -rf node_modules && npm install`)
# has lost its exclusion xattr, as has one whose exclusion was removed by hand, so
# tmutil reports it [Included]; it drops out here and goes back through
# exclude_paths_from_stdin (issue #139). [UNKNOWN] means tmutil couldn't read the
# setting: the path is gone, or a scheduled run is kept out of a privacy-protected
# folder such as ~/Documents. Only a gone path is dropped, so a scheduled run never
# tries (and fails) to re-exclude what a terminal run excluded.
#
# All paths go to one batched `tmutil isexcluded` call: a few milliseconds per
# path, against ~120ms for a call per path. tmutil prints one "[Status]  path"
# line per argument, in order, with symlinks resolved, so lines are matched to
# paths by position and checked with -ef. Returns 1 when the output doesn't line
# up (e.g. tmutil can't read exclusions at all), so the caller can fall back.
verified_excluded_state() {
    local paths line path printed kept="" count=0 total
    paths="$(grep -v '^$' "$ASIMOV_EXCLUDED_STATE" | sort -u || true)"
    [[ -n "$paths" ]] || return 0
    total="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
    while IFS= read -r line <&3; do
        IFS= read -r path <&4 || return 1
        count=$((count + 1))
        printed="${line#*]}"
        printed="${printed#"${printed%%[![:space:]]*}"}"
        [[ "$printed" == "$path" || "$printed" -ef "$path" ]] || return 1
        case "${line%%]*}" in
            '[Included') continue ;;
            '[UNKNOWN') [[ -e "$path" ]] || continue ;;
        esac
        kept+="${path}"$'\n'
    done 3< <(printf '%s\n' "$paths" | tr '\n' '\0' \
                | { xargs -0 tmutil isexcluded 2>/dev/null || true; } | { grep '^\[' || true; }) \
         4< <(printf '%s\n' "$paths")
    [[ "$count" -eq "$total" ]] || return 1
    printf '%s' "$kept"
}

# Print the failed-state lines still worth honoring. A read-only directory
# ("ro<TAB>path", see exclude_paths_from_stdin) is honored only while it is still
# read-only: one that became writable, or was recreated, is retried. Any other
# failure ("path") is honored while the path exists; use --no-read-cache to retry.
honored_failed_state() {
    local line path ro_prefix=$'ro\t'
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        path="${line#"$ro_prefix"}"
        [[ -e "$path" ]] || continue
        if [[ "$path" != "$line" ]] && [[ ! -d "$path" || -w "$path" ]]; then
            continue
        fi
        printf '%s\n' "$line"
    done < "$ASIMOV_FAILED_STATE"
}

# Create the cache directory, chown to console user when running as root.
ensure_cache_dir() {
    if [[ ! -d "$ASIMOV_CACHE_DIR" ]]; then
        mkdir -p "$ASIMOV_CACHE_DIR" 2>/dev/null || {
            warn_unusable_cache "$ASIMOV_CACHE_DIR" "writable"
            return 0
        }
    fi
    local console_user
    if console_user="$(console_user_for_root_run)"; then
        # Create the state files *before* the chown. Appending to an existing
        # file never changes its owner, so every write later in this root run
        # lands in a file the console user can still read next time. Chowning
        # only the directory (as this did before) left root-owned files behind
        # that broke the following user run outright — issue #122.
        touch "$ASIMOV_EXCLUDED_STATE" "$ASIMOV_FAILED_STATE" \
              "$ASIMOV_MDFIND_SEEN" "$ASIMOV_PATH_CACHE" 2>/dev/null || true
        chown -R "$console_user" "$ASIMOV_CACHE_DIR" 2>/dev/null || true
    fi
    return 0
}

# Read cached paths, filtering to those that still exist as directories
# and fall under one of the scan dirs. Outputs valid paths to stdout.
read_path_cache() {
    cache_readable "$ASIMOV_PATH_CACHE" || return 0
    local line d in_scope
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^#  ]] && continue
        [[ -z "$line" ]] && continue
        # Must still exist as a directory
        [[ -d "$line" ]] || continue
        # Must be under one of the scan dirs
        in_scope=false
        for d in "${ASIMOV_SCAN_DIRS[@]}"; do
            if [[ "$line" == "${d}"/* || "$line" == "${d}" ]]; then in_scope=true; break; fi
        done
        [[ "$in_scope" == true ]] || continue
        printf '%s\n' "$line"
    done < "$ASIMOV_PATH_CACHE"
}

# Initialize the path cache file with a header, truncating any old contents.
# No-op if --dry-run or writes are disabled (--no-write-cache / --no-cache).
init_path_cache() {
    [[ -n "$ASIMOV_DRY_RUN" || -n "$ASIMOV_NO_WRITE_CACHE" ]] && return 0
    ensure_cache_dir
    cache_writable "$ASIMOV_PATH_CACHE" || return 0
    printf '# asimov path cache — updated %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$ASIMOV_PATH_CACHE"
}

# Append a single path to the cache file. No-op if --dry-run or writes are disabled (--no-write-cache / --no-cache).
append_path_to_cache() {
    [[ -n "$ASIMOV_DRY_RUN" || -n "$ASIMOV_NO_WRITE_CACHE" ]] && return 0
    append_state "$1" "$ASIMOV_PATH_CACHE"
}

# Remove paths that are descendants of other paths in the list.
# Expects sorted input. Outputs only outermost (non-nested) paths.
# Example: /a/node_modules and /a/node_modules/foo/node_modules → keeps only /a/node_modules
# (Time Machine exclusions are recursive, so the descendant is already covered.)
dedup_nested_paths() {
    local last_kept="" path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if [[ -n "$last_kept" && "$path" == "${last_kept}/"* ]]; then
            continue
        fi
        printf '%s\n' "$path"
        last_kept="$path"
    done
}

# Sort, deduplicate, and prune stale entries from the cache file.
# Writes atomically via temp file + mv. No-op if --dry-run or writes are disabled (--no-write-cache / --no-cache).
finalize_path_cache() {
    [[ -n "$ASIMOV_DRY_RUN" || -n "$ASIMOV_NO_WRITE_CACHE" ]] && return 0
    cache_readable "$ASIMOV_PATH_CACHE" || return 0
    cache_writable "$ASIMOV_PATH_CACHE" || return 0

    ASIMOV_PATH_CACHE_TMP="${ASIMOV_PATH_CACHE}.tmp.$$"
    {
        printf '# asimov path cache — updated %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        # Keep only lines that are existing directories, sorted and deduplicated
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ -d "$line" ]]; then
                printf '%s\n' "$line"
            fi
        done < "$ASIMOV_PATH_CACHE" | sort -u | dedup_nested_paths
    } > "$ASIMOV_PATH_CACHE_TMP"
    mv -f "$ASIMOV_PATH_CACHE_TMP" "$ASIMOV_PATH_CACHE"
    ASIMOV_PATH_CACHE_TMP=""

    # Dedup the mdfind_seen file (grows with appends each run). The excluded and
    # failed state are compacted by build_excluded_cache instead.
    if cache_readable "$ASIMOV_MDFIND_SEEN"; then
        sort -u "$ASIMOV_MDFIND_SEEN" | rewrite_state "$ASIMOV_MDFIND_SEEN"
    fi

    local console_user
    if console_user="$(console_user_for_root_run)"; then
        chown "$console_user" "$ASIMOV_PATH_CACHE" 2>/dev/null || true
    fi
}

# Drop entries whose directory no longer exists from Asimov's path cache.
# Echoes the number of entries removed. This only ever touches Asimov's own
# file under ~/.cache/asimov.
prune_path_cache() {
    cache_readable "$ASIMOV_PATH_CACHE" || { echo 0; return 0; }
    cache_writable "$ASIMOV_PATH_CACHE" || { echo 0; return 0; }

    # A brace group with a redirect runs in the current shell, so the counters
    # below survive the loop.
    local tmp line dropped=0
    tmp="${ASIMOV_PATH_CACHE}.tmp.$$"
    {
        printf '# asimov path cache — updated %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ -d "$line" ]]; then
                printf '%s\n' "$line"
            else
                dropped=$((dropped + 1))
            fi
        done < "$ASIMOV_PATH_CACHE"
    } > "$tmp"

    mv -f "$tmp" "$ASIMOV_PATH_CACHE"
    echo "$dropped"
}

# Build the cache of paths already excluded from Time Machine, in
# $ASIMOV_EXCLUDED_CACHE. Merges the Spotlight index (what macOS reports) with
# Asimov's own persistent state (written after each successful tmutil call).
# The persistent state covers:
#   - Interrupted runs (Ctrl+C before all tmutil calls complete)
#   - Spotlight indexing delays (tmutil set the xattr but Spotlight hasn't indexed it)
#   - Directories Spotlight never reports, such as ~/.cache and other dot-dirs
build_excluded_cache() {
    verbose_timing "Building excluded-path cache via Spotlight…"
    : > "$ASIMOV_EXCLUDED_CACHE"

    local scan_dir spotlight_count
    for scan_dir in "${ASIMOV_SCAN_DIRS[@]}"; do
        mdfind -onlyin "$scan_dir" "com_apple_backup_excludeItem = 'com.apple.backupd'" 2>/dev/null \
            >> "$ASIMOV_EXCLUDED_CACHE" || true
    done
    sort -u -o "$ASIMOV_EXCLUDED_CACHE" "$ASIMOV_EXCLUDED_CACHE"
    spotlight_count="$(wc -l < "$ASIMOV_EXCLUDED_CACHE" | tr -d ' ')"

    # Merge in Asimov's own state, keeping only the entries that still hold, and
    # compact each file to them:
    #   - excluded: what Time Machine hasn't stopped excluding (see
    #     verified_excluded_state). When tmutil can't answer, the state is trusted
    #     as is rather than sending every entry to a ~11s addexclusion.
    #   - failed: see honored_failed_state, so the bulk filter skips these
    #     instantly instead of retrying tmutil.
    # Skipped under --no-read-cache (--full-scan / --no-cache): every path is then
    # re-verified against the tmutil isexcluded ground truth instead.
    if [[ -z "$ASIMOV_NO_READ_CACHE" ]] && { cache_readable "$ASIMOV_EXCLUDED_STATE" || cache_readable "$ASIMOV_FAILED_STATE"; }; then
        ASIMOV_VERIFIED_TMP="$(mktemp)"
        if cache_readable "$ASIMOV_EXCLUDED_STATE"; then
            local state_count
            state_count="$(grep -v '^$' "$ASIMOV_EXCLUDED_STATE" | sort -u | wc -l | tr -d ' ' || true)"
            if verified_excluded_state > "$ASIMOV_VERIFIED_TMP"; then
                verbose_timing "Excluded state verified: kept $(wc -l < "$ASIMOV_VERIFIED_TMP" | tr -d ' ') of ${state_count} entries"
                rewrite_state "$ASIMOV_EXCLUDED_STATE" < "$ASIMOV_VERIFIED_TMP"
            else
                # Always on stderr, like warn_unusable_cache: without the check, a
                # recreated directory stays included (issue #139).
                printf '! Could not check %s with tmutil isexcluded — trusting it as is.\n' \
                    "$ASIMOV_EXCLUDED_STATE" >&2
                sort -u "$ASIMOV_EXCLUDED_STATE" > "$ASIMOV_VERIFIED_TMP"
            fi
        fi
        if cache_readable "$ASIMOV_FAILED_STATE"; then
            local failed_lines
            failed_lines="$(honored_failed_state | sort -u)"
            printf '%s' "${failed_lines:+${failed_lines}$'\n'}" | rewrite_state "$ASIMOV_FAILED_STATE"
            if [[ -n "$failed_lines" ]]; then
                printf '%s\n' "$failed_lines" | sed "s/^ro$(printf '\t')//" >> "$ASIMOV_VERIFIED_TMP"
            fi
        fi
        sort -u "$ASIMOV_EXCLUDED_CACHE" "$ASIMOV_VERIFIED_TMP" > "${ASIMOV_EXCLUDED_CACHE}.merged"
        mv -f "${ASIMOV_EXCLUDED_CACHE}.merged" "$ASIMOV_EXCLUDED_CACHE"
        rm -f "$ASIMOV_VERIFIED_TMP"
        ASIMOV_VERIFIED_TMP=""
    fi
    verbose_timing "Excluded-path cache ready ($(wc -l < "$ASIMOV_EXCLUDED_CACHE" | tr -d ' ') entries, ${spotlight_count} from Spotlight)"
}
