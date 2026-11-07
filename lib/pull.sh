# Getting files and databases from somewhere else. Dumps can hold personal data, so they
# stay in a private temp directory outside the project and are removed when setup ends.

# Anchored to wp-content: plugins and themes have their own cache/ and uploads/ folders.
PULL_EXCLUDES=(--exclude=/uploads/ --exclude=/cache/ --exclude=/upgrade/ --exclude=/upgrade-temp-backup/
    --exclude=/ai1wm-backups/ --exclude=/updraft/ --exclude=debug.log --exclude=error_log)

ask_ssh_source() {
    ask SSH_TARGET "SSH target (user@host, or an alias from ~/.ssh/config)"
    ask REMOTE_PORT "SSH port" "22"
    ask REMOTE_DOCROOT "Remote WordPress root"
}

remote_ssh() { ssh -p "$REMOTE_PORT" "$SSH_TARGET" "$@" </dev/null; }

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
    rsync -az -e "ssh -p $REMOTE_PORT" "${PULL_EXCLUDES[@]}" \
        "$SSH_TARGET:$REMOTE_DOCROOT/wp-content/" wp-content/
}

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
    lando wp search-replace "https://$bare" "$DEV_URL" --all-tables-with-prefix --skip-columns=guid
    lando wp search-replace "http://$bare" "$DEV_URL" --all-tables-with-prefix --skip-columns=guid
    lando wp cache flush
}

# A copied production database must not be able to email real people.
disable_outbound_email() {
    if ! lando wp plugin activate disable-emails; then
        warn "Couldn't activate disable-emails. Check SMTP plugins before testing anything that sends mail."
    fi
}
