#!/usr/bin/env bash
#
# wpmigration.sh — WordPress Full Migration Script
# Run this on the SOURCE server from the WordPress root directory.
#
# Usage:
#   bash wpmigration.sh              # Full migration
#   bash wpmigration.sh --dry-run    # Preview what would happen without making changes
#
# What it does:
#   1. Pre-flight checks (required tools on source)
#   2. Locates wp-config.php and extracts DB credentials + table prefix
#   3. Dumps the full WordPress database to ./db/<dbname>.sql
#   4. Prompts for new server SSH credentials, web path, and web server user
#   5. Pre-flight checks on the remote server
#   6. Rsyncs ALL files (including .htaccess) to the new server
#   7. Prompts for new database credentials
#   8. Updates wp-config.php on the new server with new DB credentials
#   9. Imports the database on the new server
#  10. Runs WP-CLI search-replace if the web path changed
#  11. Sets file ownership and permissions on the new server
#  12. Cleans up and prints summary
#
set -euo pipefail

# ─── Globals ──────────────────────────────────────────────────────────────────
DRY_RUN=false
LOG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
MIGRATION_START=""
TOTAL_STEPS=12
CURRENT_STEP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# ─── Argument Parsing ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            head -25 "$0" | tail -22
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}"
            echo "Usage: bash wpmigration.sh [--dry-run]"
            exit 1
            ;;
    esac
done

# ─── Load .env if present ────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    # Source .env but only export non-empty values (won't overwrite existing env vars)
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# ─── Helper Functions ─────────────────────────────────────────────────────────

# Timestamps (seconds since epoch)
now_ts() { date +%s; }

# Format elapsed seconds → "1m 23s" or "45s"
fmt_elapsed() {
    local secs="$1"
    if [ "$secs" -ge 60 ]; then
        printf '%dm %ds' $((secs / 60)) $((secs % 60))
    else
        printf '%ds' "$secs"
    fi
}

# Format bytes → human readable
fmt_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        printf '%.1f GB' "$(echo "$bytes / 1073741824" | bc -l)"
    elif [ "$bytes" -ge 1048576 ]; then
        printf '%.1f MB' "$(echo "$bytes / 1048576" | bc -l)"
    elif [ "$bytes" -ge 1024 ]; then
        printf '%.1f KB' "$(echo "$bytes / 1024" | bc -l)"
    else
        printf '%d B' "$bytes"
    fi
}

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ─── Progress Bar ─────────────────────────────────────────────────────────────
# Draws: ████████░░░░░░░░  Step 3/12 (25%) — Dumping database  [elapsed 1m 23s]
progress_bar() {
    local current="$1"
    local total="$2"
    local label="$3"
    local bar_width=30
    local filled=$((current * bar_width / total))
    local empty=$((bar_width - filled))
    local pct=$((current * 100 / total))

    local elapsed=""
    if [ -n "$MIGRATION_START" ]; then
        elapsed="$(fmt_elapsed $(( $(now_ts) - MIGRATION_START )))"
    fi

    local bar=""
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done

    echo -e "${DIM}  ${bar}  Step ${current}/${total} (${pct}%) — ${label}  [elapsed ${elapsed}]${NC}"
}

# ─── Step Header ──────────────────────────────────────────────────────────────
STEP_START_TS=""

step() {
    # Print elapsed time for previous step (if any)
    if [ -n "$STEP_START_TS" ] && [ "$CURRENT_STEP" -gt 0 ]; then
        local prev_elapsed=$(( $(now_ts) - STEP_START_TS ))
        echo -e "${DIM}  ⏱  Step $CURRENT_STEP completed in $(fmt_elapsed $prev_elapsed)${NC}"
    fi

    CURRENT_STEP="$1"
    STEP_START_TS="$(now_ts)"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  STEP $1: $2${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    progress_bar "$1" "$TOTAL_STEPS" "$2"
}

# ─── Spinner ──────────────────────────────────────────────────────────────────
# Usage: start_spinner "message" → run command → stop_spinner
SPINNER_PID=""

start_spinner() {
    local msg="$1"
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        local start_ts
        start_ts=$(date +%s)
        while true; do
            local elapsed=$(( $(date +%s) - start_ts ))
            local elapsed_fmt
            if [ "$elapsed" -ge 60 ]; then
                elapsed_fmt="$(printf '%dm %ds' $((elapsed / 60)) $((elapsed % 60)))"
            else
                elapsed_fmt="$(printf '%ds' "$elapsed")"
            fi
            printf '\r  %s %s %s[%s]%s ' "${frames[$i]}" "$msg" $'\033[2m' "$elapsed_fmt" $'\033[0m'
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.12
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        printf '\r\033[K'  # Clear the spinner line
    fi
    SPINNER_PID=""
}

# Ensure spinner is cleaned up on exit
trap 'stop_spinner' EXIT

dry_run_notice() {
    if $DRY_RUN; then
        echo -e "${YELLOW}  [DRY-RUN] Would execute: $*${NC}"
        return 0
    fi
    return 1
}

prompt_password() {
    local varname="$1"
    local prompt_text="$2"
    local password=""
    echo -ne "${CYAN}$prompt_text${NC}"
    read -rs password
    echo ""
    eval "$varname='$password'"
}

confirm() {
    local prompt_text="$1"
    local response=""
    echo -ne "${YELLOW}$prompt_text [y/N]: ${NC}"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          WordPress Full Migration Tool v1.0                 ║${NC}"
echo -e "${BOLD}║          Run from SOURCE server WordPress root              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if $DRY_RUN; then
    echo -e "${YELLOW}*** DRY-RUN MODE — No changes will be made ***${NC}"
    echo ""
fi

MIGRATION_START="$(now_ts)"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Pre-flight checks (source server)
# ═══════════════════════════════════════════════════════════════════════════════
step 1 "Pre-flight checks (source server)"

REQUIRED_TOOLS=(mysql mysqldump rsync ssh)
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        success "$tool found: $(command -v "$tool")"
    else
        MISSING_TOOLS+=("$tool")
        warn "$tool NOT found"
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    fail "Missing required tools: ${MISSING_TOOLS[*]}. Please install them before running this script."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Locate wp-config.php and extract DB credentials
# ═══════════════════════════════════════════════════════════════════════════════
step 2 "Locating wp-config.php and extracting database credentials"

WP_ROOT="$(pwd)"

# Search for wp-config.php in current directory, then one level up (WordPress standard)
if [ -f "$WP_ROOT/wp-config.php" ]; then
    WP_CONFIG="$WP_ROOT/wp-config.php"
elif [ -f "$WP_ROOT/../wp-config.php" ]; then
    WP_CONFIG="$(cd "$WP_ROOT/.." && pwd)/wp-config.php"
else
    fail "wp-config.php not found in $WP_ROOT or its parent directory. Are you in the WordPress root?"
fi

success "Found wp-config.php at: $WP_CONFIG"

# Extract database credentials using grep + sed (handles spaces, quotes, etc.)
extract_wp_define() {
    local key="$1"
    grep -oP "define\s*\(\s*['\"]${key}['\"]\s*,\s*['\"]?\K[^'\"]+(?=['\"])" "$WP_CONFIG" || echo ""
}

SRC_DB_NAME="$(extract_wp_define DB_NAME)"
SRC_DB_USER="$(extract_wp_define DB_USER)"
SRC_DB_PASS="$(extract_wp_define DB_PASSWORD)"
SRC_DB_HOST="$(extract_wp_define DB_HOST)"

# Extract table prefix (uses $table_prefix variable, not define())
SRC_TABLE_PREFIX="$(grep -oP '^\s*\$table_prefix\s*=\s*['\''\"]\K[^'\''\"]+' "$WP_CONFIG" || echo "wp_")"

# Validate we got credentials
if [ -z "$SRC_DB_NAME" ] || [ -z "$SRC_DB_USER" ]; then
    fail "Could not extract database credentials from wp-config.php"
fi

info "Database Name:   $SRC_DB_NAME"
info "Database User:   $SRC_DB_USER"
info "Database Host:   $SRC_DB_HOST"
info "Table Prefix:    $SRC_TABLE_PREFIX"
info "Database Pass:   ****"
echo ""

# Extract site URL from the database for reference
SRC_SITE_URL=""
if ! $DRY_RUN; then
    SRC_SITE_URL=$(mysql -h "$SRC_DB_HOST" -u "$SRC_DB_USER" -p"$SRC_DB_PASS" "$SRC_DB_NAME" \
        -sNe "SELECT option_value FROM ${SRC_TABLE_PREFIX}options WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null || echo "")
    if [ -n "$SRC_SITE_URL" ]; then
        info "Current Site URL: $SRC_SITE_URL"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Dump the WordPress database
# ═══════════════════════════════════════════════════════════════════════════════
step 3 "Dumping WordPress database"

DB_DUMP_DIR="$WP_ROOT/db"
DB_DUMP_FILE="$DB_DUMP_DIR/${SRC_DB_NAME}.sql"

if dry_run_notice "mysqldump → $DB_DUMP_FILE"; then
    : # no-op, dry_run_notice already printed
else
    mkdir -p "$DB_DUMP_DIR"

    info "Dumping database '$SRC_DB_NAME' to $DB_DUMP_FILE ..."

    start_spinner "Dumping database..."
    mysqldump \
        -h "$SRC_DB_HOST" \
        -u "$SRC_DB_USER" \
        -p"$SRC_DB_PASS" \
        --single-transaction \
        --routines \
        --triggers \
        --add-drop-table \
        "$SRC_DB_NAME" > "$DB_DUMP_FILE"
    stop_spinner

    DUMP_SIZE_BYTES=$(stat -c%s "$DB_DUMP_FILE" 2>/dev/null || stat -f%z "$DB_DUMP_FILE" 2>/dev/null)
    DUMP_SIZE_HUMAN=$(fmt_bytes "$DUMP_SIZE_BYTES")
    DUMP_LINES=$(wc -l < "$DB_DUMP_FILE")
    DUMP_TABLES=$(grep -c '^CREATE TABLE' "$DB_DUMP_FILE" || echo "?")

    if [ "$DUMP_LINES" -lt 10 ]; then
        fail "Database dump appears empty or corrupt ($DUMP_LINES lines). Aborting."
    fi

    success "Database dumped successfully"
    info "  Size:   $DUMP_SIZE_HUMAN ($DUMP_LINES lines)"
    info "  Tables: $DUMP_TABLES"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Collect new server credentials
# ═══════════════════════════════════════════════════════════════════════════════
step 4 "New server SSH credentials"

# Use .env values if set, otherwise prompt interactively
if [ -n "${NEW_SSH_HOST:-}" ]; then
    info "Loaded from .env: SSH Host = $NEW_SSH_HOST"
else
    read -rp "  SSH Host (IP or hostname): " NEW_SSH_HOST
fi

NEW_SSH_PORT="${NEW_SSH_PORT:-22}"
info "SSH Port: $NEW_SSH_PORT"

if [ -n "${NEW_SSH_USER:-}" ]; then
    info "Loaded from .env: SSH User = $NEW_SSH_USER"
else
    read -rp "  SSH Username: " NEW_SSH_USER
fi

# Determine auth method — .env can set AUTH_METHOD to "key" or "password"
if [ -z "${AUTH_METHOD:-}" ]; then
    echo ""
    echo -e "${CYAN}  Authentication method:${NC}"
    echo "    1) SSH key (recommended)"
    echo "    2) Password"
    read -rp "  Choose [1]: " AUTH_METHOD
    AUTH_METHOD="${AUTH_METHOD:-key}"
fi

# Normalize: "1" → "key", "2" → "password"
case "$AUTH_METHOD" in
    1|key|Key|KEY) AUTH_METHOD="key" ;;
    2|password|Password|PASSWORD) AUTH_METHOD="password" ;;
esac

SSH_KEY_FLAG=""
if [ "$AUTH_METHOD" = "password" ]; then
    if [ -z "${SSH_PASS:-}" ]; then
        prompt_password SSH_PASS "  SSH Password: "
    else
        info "Loaded from .env: SSH Password = ****"
    fi
    if ! command -v sshpass &>/dev/null; then
        fail "sshpass is required for password-based SSH. Install it with: apt install sshpass"
    fi
    SSH_CMD="sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -p $NEW_SSH_PORT $NEW_SSH_USER@$NEW_SSH_HOST"
    RSYNC_SSH="sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -p $NEW_SSH_PORT"
else
    if [ -z "${SSH_KEY_PATH:-}" ]; then
        read -rp "  SSH Key path [~/.ssh/id_rsa]: " SSH_KEY_PATH
    else
        info "Loaded from .env: SSH Key = $SSH_KEY_PATH"
    fi
    SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
    if [ ! -f "$SSH_KEY_PATH" ]; then
        fail "SSH key not found at $SSH_KEY_PATH"
    fi
    SSH_CMD="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -p $NEW_SSH_PORT $NEW_SSH_USER@$NEW_SSH_HOST"
    RSYNC_SSH="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -p $NEW_SSH_PORT"
fi

if [ -n "${NEW_WEB_PATH:-}" ]; then
    info "Loaded from .env: Web path = $NEW_WEB_PATH"
else
    echo ""
    read -rp "  WordPress path on NEW server (e.g., /var/www/html): " NEW_WEB_PATH
fi
# Remove trailing slash
NEW_WEB_PATH="${NEW_WEB_PATH%/}"

NEW_WEB_USER="${NEW_WEB_USER:-www-data}"
NEW_WEB_GROUP="${NEW_WEB_GROUP:-$NEW_WEB_USER}"

echo ""
success "SSH target: ${NEW_SSH_USER}@${NEW_SSH_HOST}:${NEW_SSH_PORT}"
info "Web path:   $NEW_WEB_PATH"
info "Web user:   $NEW_WEB_USER:$NEW_WEB_GROUP"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Pre-flight checks on remote server
# ═══════════════════════════════════════════════════════════════════════════════
step 5 "Pre-flight checks (destination server)"

if dry_run_notice "SSH connectivity test → $NEW_SSH_HOST"; then
    :
else
    start_spinner "Testing SSH connection to $NEW_SSH_HOST..."
    if eval "$SSH_CMD 'echo connected'" &>/dev/null; then
        stop_spinner
        success "SSH connection successful"
    else
        stop_spinner
        fail "Cannot connect to $NEW_SSH_HOST via SSH. Check credentials."
    fi

    info "Checking required tools on remote server..."
    REMOTE_TOOLS_CHECK=$(eval "$SSH_CMD 'for t in mysql wp; do command -v \$t 2>/dev/null && echo \"FOUND:\$t\" || echo \"MISSING:\$t\"; done'" 2>/dev/null)

    echo "$REMOTE_TOOLS_CHECK" | while IFS= read -r line; do
        case "$line" in
            FOUND:*)  success "Remote: ${line#FOUND:} found" ;;
            MISSING:mysql) warn "Remote: mysql not found — DB import will fail" ;;
            MISSING:wp)    warn "Remote: WP-CLI (wp) not found — search-replace will be skipped" ;;
        esac
    done

    # Create destination directory if it doesn't exist
    info "Ensuring destination path exists..."
    eval "$SSH_CMD 'sudo mkdir -p $NEW_WEB_PATH'" 2>/dev/null || true
    success "Destination path ready"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Rsync files to new server
# ═══════════════════════════════════════════════════════════════════════════════
step 6 "Syncing files to new server"

info "Source:      $WP_ROOT/"
info "Destination: ${NEW_SSH_USER}@${NEW_SSH_HOST}:${NEW_WEB_PATH}/"
echo ""

if dry_run_notice "rsync -avz (all files including .htaccess) → remote"; then
    :
else
    # Pre-transfer stats
    SRC_FILE_COUNT=$(find "$WP_ROOT" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/db/*.sql' | wc -l)
    SRC_DIR_SIZE_BYTES=$(du -sb "$WP_ROOT" --exclude='.git' --exclude='node_modules' 2>/dev/null | cut -f1 || echo "0")
    SRC_DIR_SIZE_HUMAN=$(fmt_bytes "$SRC_DIR_SIZE_BYTES")

    info "Files to sync:  $SRC_FILE_COUNT files ($SRC_DIR_SIZE_HUMAN)"

    if ! confirm "Ready to start file transfer?"; then
        fail "Migration cancelled by user."
    fi

    info "Starting rsync..."
    echo ""
    RSYNC_START=$(now_ts)

    rsync -avz \
        --progress \
        --stats \
        --human-readable \
        --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='db/*.sql' \
        -e "$RSYNC_SSH" \
        "$WP_ROOT/" \
        "${NEW_SSH_USER}@${NEW_SSH_HOST}:${NEW_WEB_PATH}/"

    RSYNC_ELAPSED=$(( $(now_ts) - RSYNC_START ))
    echo ""
    success "Files synced successfully in $(fmt_elapsed $RSYNC_ELAPSED)"

    # Also transfer the DB dump separately (it was excluded above)
    info "Transferring database dump..."
    start_spinner "Uploading ${SRC_DB_NAME}.sql..."
    rsync -avz \
        -e "$RSYNC_SSH" \
        "$DB_DUMP_FILE" \
        "${NEW_SSH_USER}@${NEW_SSH_HOST}:${NEW_WEB_PATH}/db/"
    stop_spinner

    success "Database dump transferred"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: Collect new database credentials
# ═══════════════════════════════════════════════════════════════════════════════
step 7 "New database credentials"

# Use .env values if set, otherwise prompt
NEW_DB_HOST="${NEW_DB_HOST:-}"
if [ -z "$NEW_DB_HOST" ]; then
    read -rp "  Database Host [localhost]: " NEW_DB_HOST
    NEW_DB_HOST="${NEW_DB_HOST:-localhost}"
else
    info "Loaded from .env: DB Host = $NEW_DB_HOST"
fi

if [ -n "${NEW_DB_NAME:-}" ]; then
    info "Loaded from .env: DB Name = $NEW_DB_NAME"
else
    read -rp "  Database Name: " NEW_DB_NAME
fi

if [ -n "${NEW_DB_USER:-}" ]; then
    info "Loaded from .env: DB User = $NEW_DB_USER"
else
    read -rp "  Database User: " NEW_DB_USER
fi

if [ -n "${NEW_DB_PASS:-}" ]; then
    info "Loaded from .env: DB Password = ****"
else
    prompt_password NEW_DB_PASS "  Database Password: "
fi
echo ""

NEW_TABLE_PREFIX="${NEW_TABLE_PREFIX:-$SRC_TABLE_PREFIX}"

info "New DB Host:      $NEW_DB_HOST"
info "New DB Name:      $NEW_DB_NAME"
info "New DB User:      $NEW_DB_USER"
info "New DB Pass:      ****"
info "New Table Prefix: $NEW_TABLE_PREFIX"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Update wp-config.php on the new server
# ═══════════════════════════════════════════════════════════════════════════════
step 8 "Updating wp-config.php on new server"

# Build sed commands to replace DB credentials in wp-config.php
REMOTE_WP_CONFIG="${NEW_WEB_PATH}/wp-config.php"

# Escape special characters for sed
escape_sed() {
    printf '%s\n' "$1" | sed 's/[&/\]/\\&/g'
}

NEW_DB_NAME_ESC=$(escape_sed "$NEW_DB_NAME")
NEW_DB_USER_ESC=$(escape_sed "$NEW_DB_USER")
NEW_DB_PASS_ESC=$(escape_sed "$NEW_DB_PASS")
NEW_DB_HOST_ESC=$(escape_sed "$NEW_DB_HOST")

SED_CMDS="
s/define\s*(\s*['\"]DB_NAME['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_NAME', '${NEW_DB_NAME_ESC}')/;
s/define\s*(\s*['\"]DB_USER['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_USER', '${NEW_DB_USER_ESC}')/;
s/define\s*(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_PASSWORD', '${NEW_DB_PASS_ESC}')/;
s/define\s*(\s*['\"]DB_HOST['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_HOST', '${NEW_DB_HOST_ESC}')/;
"

# Update table prefix if changed
if [ "$NEW_TABLE_PREFIX" != "$SRC_TABLE_PREFIX" ]; then
    SRC_PREFIX_ESC=$(escape_sed "$SRC_TABLE_PREFIX")
    NEW_PREFIX_ESC=$(escape_sed "$NEW_TABLE_PREFIX")
    SED_CMDS+="s/\\\$table_prefix\s*=\s*['\"]${SRC_PREFIX_ESC}['\"]/\\\$table_prefix = '${NEW_PREFIX_ESC}'/;"
fi

if dry_run_notice "sed wp-config.php → update DB_NAME, DB_USER, DB_PASSWORD, DB_HOST"; then
    :
else
    info "Updating database credentials in wp-config.php..."

    eval "$SSH_CMD \"sudo cp ${REMOTE_WP_CONFIG} ${REMOTE_WP_CONFIG}.bak.${TIMESTAMP}\""
    success "Backed up wp-config.php → wp-config.php.bak.${TIMESTAMP}"

    eval "$SSH_CMD \"sudo sed -i -E '${SED_CMDS}' ${REMOTE_WP_CONFIG}\""
    success "wp-config.php updated with new database credentials"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 9: Import database on new server
# ═══════════════════════════════════════════════════════════════════════════════
step 9 "Importing database on new server"

REMOTE_DUMP_FILE="${NEW_WEB_PATH}/db/${SRC_DB_NAME}.sql"

if dry_run_notice "mysql import $REMOTE_DUMP_FILE → $NEW_DB_NAME"; then
    :
else
    info "Importing database '${NEW_DB_NAME}' from dump (${DUMP_SIZE_HUMAN:-unknown size})..."

    start_spinner "Importing database (large DBs may take several minutes)..."
    eval "$SSH_CMD \"mysql -h '${NEW_DB_HOST}' -u '${NEW_DB_USER}' -p'${NEW_DB_PASS}' '${NEW_DB_NAME}' < '${REMOTE_DUMP_FILE}'\""
    stop_spinner

    success "Database imported successfully"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 10: WP-CLI search-replace (if applicable)
# ═══════════════════════════════════════════════════════════════════════════════
step 10 "URL search-replace (WP-CLI)"

echo ""
echo -e "${CYAN}Even for same-domain migrations, it's good practice to verify URLs are correct.${NC}"
echo ""
if [ -n "${OLD_URL:-}" ]; then
    info "Loaded from .env: Old URL = $OLD_URL"
else
    read -rp "  Old URL (e.g., https://example.com) [skip]: " OLD_URL
fi
if [ -n "${NEW_URL:-}" ]; then
    info "Loaded from .env: New URL = $NEW_URL"
else
    read -rp "  New URL (e.g., https://example.com) [skip]: " NEW_URL
fi

if [ -n "$OLD_URL" ] && [ -n "$NEW_URL" ] && [ "$OLD_URL" != "$NEW_URL" ]; then
    if dry_run_notice "wp search-replace '$OLD_URL' '$NEW_URL'"; then
        :
    else
        info "Running WP-CLI search-replace..."
        info "  Old: $OLD_URL"
        info "  New: $NEW_URL"

        start_spinner "Running search-replace across all tables..."
        WPCLI_OUTPUT=$(eval "$SSH_CMD \"cd ${NEW_WEB_PATH} && sudo -u ${NEW_WEB_USER} wp search-replace '${OLD_URL}' '${NEW_URL}' --all-tables --precise --recurse-objects --skip-columns=guid 2>&1\"" || true)
        stop_spinner
        echo "$WPCLI_OUTPUT"

        success "Search-replace completed"
    fi
else
    info "Skipping URL search-replace (same domain or user skipped)"
fi

# Also update table prefix in DB if it changed
if [ "$NEW_TABLE_PREFIX" != "$SRC_TABLE_PREFIX" ]; then
    warn "Table prefix changed from '$SRC_TABLE_PREFIX' to '$NEW_TABLE_PREFIX'."
    warn "You may need to manually rename tables and update usermeta/options prefix references."
    warn "Consider: wp db query \"RENAME TABLE ${SRC_TABLE_PREFIX}xxx TO ${NEW_TABLE_PREFIX}xxx\" for each table."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 11: Set file permissions on new server
# ═══════════════════════════════════════════════════════════════════════════════
step 11 "Setting file permissions on new server"

if dry_run_notice "chown/chmod on $NEW_WEB_PATH"; then
    :
else
    start_spinner "Setting ownership to ${NEW_WEB_USER}:${NEW_WEB_GROUP}..."
    eval "$SSH_CMD \"sudo chown -R ${NEW_WEB_USER}:${NEW_WEB_GROUP} ${NEW_WEB_PATH}\""
    stop_spinner
    success "Ownership set"

    start_spinner "Setting directory permissions to 755..."
    eval "$SSH_CMD \"sudo find ${NEW_WEB_PATH} -type d -exec chmod 755 {} \;\""
    stop_spinner
    success "Directory permissions set"

    start_spinner "Setting file permissions to 644..."
    eval "$SSH_CMD \"sudo find ${NEW_WEB_PATH} -type f -exec chmod 644 {} \;\""
    stop_spinner
    success "File permissions set"

    info "Securing wp-config.php to 600..."
    eval "$SSH_CMD \"sudo chmod 600 ${REMOTE_WP_CONFIG}\""
    success "wp-config.php secured"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 12: Cleanup and summary
# ═══════════════════════════════════════════════════════════════════════════════
step 12 "Cleanup and summary"

# Offer to remove the DB dump from the remote server (security)
if ! $DRY_RUN; then
    echo ""
    if confirm "Remove database dump from the NEW server? (recommended for security)"; then
        eval "$SSH_CMD \"rm -f '${REMOTE_DUMP_FILE}'\""
        success "Remote database dump removed"
    else
        warn "Database dump left at: ${REMOTE_DUMP_FILE}"
        warn "Remember to delete it manually — it contains your full database!"
    fi
fi

# Final flush — clear caches if WP-CLI is available
if ! $DRY_RUN; then
    info "Flushing caches and rewrite rules..."
    eval "$SSH_CMD \"cd ${NEW_WEB_PATH} && sudo -u ${NEW_WEB_USER} wp cache flush 2>/dev/null && sudo -u ${NEW_WEB_USER} wp rewrite flush 2>/dev/null\"" || true
    success "Caches flushed"
fi

# Print elapsed for last step
if [ -n "$STEP_START_TS" ]; then
    local_last_elapsed=$(( $(now_ts) - STEP_START_TS ))
    echo -e "${DIM}  ⏱  Step $CURRENT_STEP completed in $(fmt_elapsed $local_last_elapsed)${NC}"
fi

TOTAL_ELAPSED=$(( $(now_ts) - MIGRATION_START ))

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              Migration Complete!                            ║${NC}"
echo -e "${BOLD}║              Total time: $(printf '%-35s' "$(fmt_elapsed $TOTAL_ELAPSED)")║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Summary:${NC}"
echo "  Source:      $WP_ROOT"
echo "  Destination: ${NEW_SSH_USER}@${NEW_SSH_HOST}:${NEW_WEB_PATH}"
echo "  Database:    ${SRC_DB_NAME} → ${NEW_DB_NAME}"
if [ -n "${OLD_URL:-}" ] && [ -n "${NEW_URL:-}" ] && [ "$OLD_URL" != "$NEW_URL" ]; then
    echo "  URL:         ${OLD_URL} → ${NEW_URL}"
fi
echo "  Duration:    $(fmt_elapsed $TOTAL_ELAPSED)"
echo ""
echo -e "${YELLOW}Post-migration checklist:${NC}"
echo "  1. Visit the site in a browser and verify it loads correctly"
echo "  2. Check wp-admin login works"
echo "  3. Verify media uploads display properly"
echo "  4. Test internal links and navigation"
echo "  5. Check permalink settings (Settings → Permalinks → Save)"
echo "  6. Verify SSL certificate if using HTTPS"
echo "  7. Update DNS if needed"
echo "  8. Deactivate and reactivate plugins if any misbehave"
echo "  9. Clear any CDN or caching plugin caches"
echo " 10. Delete the /db/ folder from both servers when confirmed working"
echo ""
echo -e "${GREEN}Done! $(date)${NC}"
