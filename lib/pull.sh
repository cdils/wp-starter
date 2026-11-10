# Getting files and databases from somewhere else. Dumps can hold personal data, so they
# stay in a private temp directory outside the project and are removed when setup ends.

# Anchored to wp-content: plugins and themes have their own cache/ and uploads/ folders.
# Also left behind: backup folders, which can hold wp-config copies; drop-ins, which only
# work on the server they came from; and hosts' platform mu-plugins, which call home.
PULL_EXCLUDES=(--exclude=/uploads/ --exclude=/cache/ --exclude=/upgrade/ --exclude=/upgrade-temp-backup/
    --exclude=/ai1wm-backups/ --exclude=/updraft/ --exclude='/*backup*/' --exclude=debug.log --exclude=error_log
    --exclude=/object-cache.php --exclude=/advanced-cache.php --exclude=/db.php
    --exclude=/mu-plugins/mu-plugin.php --exclude=/mu-plugins/wpengine-common/ --exclude='/mu-plugins/wpe-*'
    --exclude=/mu-plugins/wpengine-security-auditor.php --exclude=/mu-plugins/slt-force-strong-passwords.php
    --exclude=/mu-plugins/force-strong-passwords/ --exclude='/mu-plugins/kinsta-mu-plugins*'
    --exclude='/mu-plugins/gd-system-plugin*' --exclude=/mu-plugins/0-worker.php)

# ask_ssh_source "Which server, and why": modes differ on whether staging will do.
ask_ssh_source() {
    is_set SSH_TARGET || info "$1"
    while true; do
        ask SSH_TARGET "SSH target (user@host, or an alias from ~/.ssh/config)"
        ask REMOTE_PORT "SSH port (SiteGround uses 18765)" "22" valid_port
        remote_ssh true && break
        [ "$NONINTERACTIVE" = false ] || die "Couldn't connect to $SSH_TARGET on port $REMOTE_PORT."
        warn "Couldn't connect to $SSH_TARGET on port $REMOTE_PORT. Check both and try again."
        unset SSH_TARGET REMOTE_PORT
    done

    is_set REMOTE_DOCROOT || info "The folder holding wp-content, e.g. ~/sites/acme (WP Engine) or /home/acme/public_html."
    ask REMOTE_DOCROOT "Remote WordPress root" "" valid_remote_docroot
    REMOTE_DOCROOT=$(remote_path "$REMOTE_DOCROOT")
}

# A leading ~/ becomes home-relative: ssh and rsync both start in home, and a quoted ~
# isn't expanded by the remote shell. Trailing slashes are dropped.
remote_path() {
    local path="$1"
    case "$path" in
        "~"|"~/") path="." ;;
        "~/"*) path="${path#\~/}" ;;
    esac
    while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
        path="${path%/}"
    done
    printf '%s' "$path"
}

# Checked now, because remote wp errors are discarded and would only surface as an empty pull.
valid_remote_docroot() {
    local path status=0
    path=$(printf '%q' "$(remote_path "$1")")
    remote_ssh "cd $path 2>/dev/null || exit 3; [ -d wp-content ] || exit 4; command -v wp >/dev/null || exit 5" \
        || status=$?
    case "$status" in
        0) return 0 ;;
        3) warn "No such folder on the server: $1" ;;
        4) warn "$1 has no wp-content folder. Use the folder WordPress is installed in." ;;
        5) warn "WP-CLI (wp) isn't available on the server, so the database can't be exported over SSH." ;;
        *) warn "Couldn't check $1 over SSH." ;;
    esac
    return 1
}

# WP-CLI loads the copied site's plugins, and older ones flood newer PHP with deprecation
# notices. Those are hidden; everything else, including real errors, still shows.
lando_wp() {
    lando wp "$@" 2>&1 | { grep -vE '^(PHP )?Deprecated:' || true; }
}

# One shared connection per run, so a password-only login is typed once, not per call.
# The socket path is derived from the connection, not stored, because remote_wp runs in
# subshells. It lives in ~/.ssh, and without that folder each call connects on its own.
ssh_opts() {
    printf -- '-p %s' "$REMOTE_PORT"
    if [ -d "$HOME/.ssh" ]; then
        printf -- ' -o ControlMaster=auto -o ControlPersist=15m -o ControlPath=%s' "$HOME/.ssh/wp-project-%C"
    fi
}

# shellcheck disable=SC2046 # ssh_opts is split on purpose; none of its words hold spaces.
remote_ssh() { ssh $(ssh_opts) "$SSH_TARGET" "$@" </dev/null; }

# shellcheck disable=SC2046
close_ssh() {
    [ -n "${SSH_TARGET:-}" ] && [ -d "$HOME/.ssh" ] || return 0
    ssh $(ssh_opts) -O exit "$SSH_TARGET" 2>/dev/null || true
}

remote_wp() {
    remote_ssh "cd $(printf '%q' "$REMOTE_DOCROOT") && wp $*" 2>/dev/null | tail -1 | tr -d '\r'
}

make_dump_dir() {
    if [ -z "${DUMP_DIR:-}" ] || [ ! -d "$DUMP_DIR" ]; then
        DUMP_DIR=$(mktemp -d)
        chmod 700 "$DUMP_DIR"
        export DUMP_DIR
        remember DUMP_DIR
        # Saved now, so a resume reuses and later removes this folder instead of orphaning it.
        save_answers
    fi
}

remove_dump_dir() {
    if [ -n "${DUMP_DIR:-}" ] && [ -d "$DUMP_DIR" ]; then
        rm -rf "$DUMP_DIR"
    fi
}

pull_db_ssh() {
    make_dump_dir
    local target="$DUMP_DIR/db.sql.gz"
    info "Exporting the database over SSH..."
    remote_ssh "cd $(printf '%q' "$REMOTE_DOCROOT") && wp db export - --single-transaction" \
        2>/dev/null | gzip > "$target"
    gzip -t "$target" || die "The database export was incomplete."
    [ "$(gzip -cd "$target" | head -c 200 | wc -c)" -gt 0 ] || die "The database export was empty."
    SQL_PATH="$target"
    export SQL_PATH
    remember SQL_PATH
}

pull_files_ssh() {
    info "Copying wp-content (without uploads)..."
    mkdir -p wp-content
    rsync -az -e "ssh $(ssh_opts)" "${PULL_EXCLUDES[@]}" \
        "$SSH_TARGET:$REMOTE_DOCROOT/wp-content/" wp-content/
    make_writable
}

# Servers can hand out read-only folders, which block later cleanup. Done after the copy,
# because macOS's rsync ignores --chmod on folders.
make_writable() { chmod -R u+w wp-content; }

pull_files_backup() {
    local root="$BACKUP_PATH" found
    if [ -f "$BACKUP_PATH" ]; then
        make_dump_dir
        root="$DUMP_DIR/backup"
        unzip -q "$BACKUP_PATH" -d "$root"
    fi
    [ -d "$root" ] || die "Not found: $BACKUP_PATH"

    found=$(find "$root" -maxdepth 4 -type d -name wp-content | head -n1)
    [ -n "$found" ] || die "No wp-content folder in $BACKUP_PATH."
    mkdir -p wp-content
    rsync -a "${PULL_EXCLUDES[@]}" "$found/" wp-content/
    make_writable

    if [ -z "${SQL_PATH:-}" ]; then
        SQL_PATH=$(find "$root" -maxdepth 4 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | head -n1)
        export SQL_PATH
        remember SQL_PATH
    fi
    [ -n "$SQL_PATH" ] || die "No .sql file found. Set the SQL dump path and resume."
}

# Read from the dump itself: wp-config's WP_HOME overrides the home option once imported.
# usermeta, not options: plugins add tables like wp_aioseo_options, and multisite adds wp_2_options.
dump_table_prefix() {
    gzip -cdf "$SQL_PATH" | perl -ne 'if (/CREATE TABLE `?(\w*?)usermeta`?/) { print $1; exit }' || true
}

# A repo's .env.example can assume a different prefix than the dump uses.
sync_table_prefix() {
    local prefix
    prefix=$(dump_table_prefix)
    [ -n "$prefix" ] || return 0
    if grep -q '^DB_TABLE_PREFIX=' .env; then
        PREFIX="$prefix" perl -pi -e 's/^DB_TABLE_PREFIX=.*/DB_TABLE_PREFIX="$ENV{PREFIX}"/' .env
    elif [ "$prefix" != wp_ ]; then
        warn "The dump uses the table prefix '$prefix'. Set it wherever this repo's wp-config.php reads it."
    fi
}

dump_home_url() {
    gzip -cdf "$SQL_PATH" | perl -ne "if (/'home',\s*'(https?:[^']+)'/) { print \$1; exit }" || true
}

# lando db-import only reads inside the app, so the dump is copied in for the import alone.
# .wp-project-* is ignored by git.
import_dump() {
    [ -f "$SQL_PATH" ] || die "Dump not found: $SQL_PATH"
    local ext="sql" inside status=0
    case "$SQL_PATH" in *.gz) ext="sql.gz" ;; esac
    inside=".wp-project-dump.$ext"
    (umask 077 && cp "$SQL_PATH" "$inside")
    lando db-import "$inside" || status=$?
    rm -f "$inside"
    return "$status"
}

replace_urls() {
    [ -n "${OLD_URL:-}" ] || { warn "No source URL known, skipping search-replace."; return 0; }
    local bare="${OLD_URL#*://}"
    bare="${bare%/}"
    lando_wp search-replace "https://$bare" "$DEV_URL" --all-tables-with-prefix --skip-columns=guid
    lando_wp search-replace "http://$bare" "$DEV_URL" --all-tables-with-prefix --skip-columns=guid
    # A copied object cache or host plugin can fail this; the import itself is done.
    lando_wp cache flush || warn "Couldn't flush the object cache. Run 'lando wp cache flush' if pages look stale."
}

# A copied production database must not be able to email real people.
disable_outbound_email() {
    if ! lando_wp plugin activate disable-emails; then
        warn "Couldn't activate disable-emails. Check SMTP plugins before testing anything that sends mail."
    fi
}
