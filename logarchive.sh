#!/bin/bash
# =====================================================================
# Automated Log Archival + Safe-Delete System (extended version)
# Usage: ./logarchive.sh [-n] [-c] [-h] [config_file]
#   -n  dry run (no changes)     -c  gzip archived files     -h  help
# =====================================================================

archived=0; kept=0; skipped=0; collisions=0
declare -A cat_count          # archived files per category
declare -A reason_count       # kept files per reason
total_bytes=0
LOCKFILE="/tmp/logarchive.$USER.lock"

usage() {
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------- logging ----------
log() {
    local msg="[$(date '+%F %T')] $*"
    echo "$msg"
    [ -n "$LOG_FILE" ] && [ "$DRY_RUN" != 1 ] && echo "$msg" >> "$LOG_FILE"
}

# ---------- argument parsing ----------
CLI_DRY=""; CLI_COMP=""
while getopts "nch" opt; do
    case $opt in
        n) CLI_DRY=1 ;;
        c) CLI_COMP=1 ;;
        h) usage ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

CONFIG="${1:-logarchive.conf}"
[ -f "$CONFIG" ] || { echo "Config file not found: $CONFIG"; exit 1; }
source "$CONFIG"
[ -n "$CLI_DRY" ] && DRY_RUN=1
[ -n "$CLI_COMP" ] && COMPRESS=1
DRY_RUN="${DRY_RUN:-0}"; COMPRESS="${COMPRESS:-0}"

# ---------- validation ----------
validate_config() {
    local v
    for v in ACTIVE_DIR ARCHIVE_DIR BACKUP_DIR AGE_DAYS PATTERNS; do
        [ -n "${!v}" ] || { echo "Config error: $v is not set"; exit 1; }
    done
    [[ "$AGE_DAYS" =~ ^[0-9]+$ ]] || { echo "Config error: AGE_DAYS must be a number"; exit 1; }
    [ -d "$ACTIVE_DIR" ] || { echo "Active directory missing: $ACTIVE_DIR"; exit 1; }
}

# ---------- lock (prevents two runs at once) ----------
acquire_lock() {
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE" 2>/dev/null)" 2>/dev/null; then
        echo "Another instance is running (PID $(cat "$LOCKFILE"))"; exit 1
    fi
    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT
}

create_dirs() {
    [ "$DRY_RUN" = 1 ] && return
    mkdir -p "$ACTIVE_DIR" "$ARCHIVE_DIR" "$BACKUP_DIR"
}

get_inode() { stat -c %i "$1"; }
get_size()  { stat -c %s "$1"; }

human() {   # bytes -> human readable
    local b=$1
    if   [ "$b" -ge 1048576 ]; then echo "$((b / 1048576)) MB"
    elif [ "$b" -ge 1024 ];    then echo "$((b / 1024)) KB"
    else echo "$b B"; fi
}

# Returns 0 = safe; 1 = no backup; 2 = same inode; 3 = content differs
backup_ok() {
    local orig="$1" bak="$2"
    [ -f "$bak" ] || return 1
    [ "$(get_inode "$orig")" != "$(get_inode "$bak")" ] || return 2
    cmp -s "$orig" "$bak" || return 3
    return 0
}

# ---------- helpers for archive step ----------
unique_dest() {   # sets global DEST; if name exists in archive, append timestamp
    local dir="$1" name="$2"
    DEST="$dir/$name"
    if [ -e "$DEST" ] || [ -e "$DEST.gz" ]; then
        DEST="$dir/${name}.$(date +%Y%m%d%H%M%S).dup"
        collisions=$((collisions + 1))
        log "[COLLISION] $name already in $dir -> saved as $(basename "$DEST")"
    fi
}

archive_file() {
    local f="$1" category="$2" name size dest
    name=$(basename "$f"); size=$(get_size "$f")
    if [ "$DRY_RUN" = 1 ]; then
        log "[DRY-RUN] would archive $name -> $ARCHIVE_DIR/$category/"
    else
        mkdir -p "$ARCHIVE_DIR/$category"
        unique_dest "$ARCHIVE_DIR/$category" "$name"; dest="$DEST"
        mv -- "$f" "$dest" || { log "[ERROR] move failed for $name"; return 1; }
        [ "$COMPRESS" = 1 ] && gzip -f "$dest" && log "[COMPRESSED] $(basename "$dest").gz"
        log "[ARCHIVED] $name -> $ARCHIVE_DIR/$category/"
    fi
    archived=$((archived + 1))
    total_bytes=$((total_bytes + size))
    cat_count[$category]=$(( ${cat_count[$category]:-0} + 1 ))
}

keep_file() {
    local name="$1" reason="$2"
    log "[KEPT] $name : $reason"
    kept=$((kept + 1))
    reason_count["$reason"]=$(( ${reason_count["$reason"]:-0} + 1 ))
}

process_file() {
    local f="$1" pat="$2"
    local name category bak rc
    name=$(basename "$f")
    category="${pat##*.}"
    bak="$BACKUP_DIR/$name"

    if [ ! -r "$f" ]; then
        keep_file "$name" "file not readable"; return
    fi

    if [ ! -e "$bak" ] && [ "$DRY_RUN" != 1 ]; then
        cp -p -- "$f" "$bak" 2>/dev/null || log "[WARN] could not create backup for $name"
    fi

    if [ "$DRY_RUN" = 1 ] && [ ! -e "$bak" ]; then
        log "[DRY-RUN] would create backup of $name"
        archive_file "$f" "$category"; return
    fi

    backup_ok "$f" "$bak"; rc=$?
    case $rc in
        0) archive_file "$f" "$category" ;;
        1) keep_file "$name" "backup missing" ;;
        2) keep_file "$name" "backup has SAME inode (hard link)" ;;
        3) keep_file "$name" "backup content differs" ;;
    esac
}

report_ignored() {   # files in Active that did not match any rule
    local f
    while IFS= read -r -d '' f; do
        skipped=$((skipped + 1))
    done < <(find "$ACTIVE_DIR" -maxdepth 1 -type f -mtime -"$AGE_DAYS" -print0)
}

print_summary() {
    echo "================ SUMMARY ================"
    echo "Archived       : $archived ($(human "$total_bytes"))"
    echo "Kept           : $kept"
    echo "Recent (<${AGE_DAYS}d)  : $skipped"
    echo "Name collisions: $collisions"
    local k
    for k in "${!cat_count[@]}"; do echo "  archived [$k] : ${cat_count[$k]}"; done
    for k in "${!reason_count[@]}"; do echo "  kept ($k) : ${reason_count[$k]}"; done
    [ "$DRY_RUN" = 1 ] && echo "(dry run - nothing was changed)"
    echo "========================================="
}

main() {
    validate_config
    acquire_lock
    create_dirs
    log "Run started (age>${AGE_DAYS}d, dry=$DRY_RUN, compress=$COMPRESS)"
    read -ra pats <<< "$PATTERNS"
    for pat in "${pats[@]}"; do
        while IFS= read -r -d '' f; do
            process_file "$f" "$pat"
        done < <(find "$ACTIVE_DIR" -maxdepth 1 -type f -name "$pat" -mtime +"$AGE_DAYS" -print0)
    done
    report_ignored
    print_summary
    log "---- Done: $archived archived, $kept kept ----"
}

main

