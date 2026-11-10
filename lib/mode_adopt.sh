# adopt: bring a live site with no repo into a new composerized project.

run_adopt() {
    heading "Adopt a live site"
    preflight lando docker git composer php perl openssl curl rsync

    ask PROJECT_NAME "Project name (e.g. acme-widgets)" "" valid_slug
    PROJECT_DIR="${PROJECTS_DIR:-$PWD}/$PROJECT_NAME"
    if [ -e "$PROJECT_DIR" ] && [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null | grep -v '^\.DS_Store$')" ]; then
        die "$PROJECT_DIR already exists and isn't empty."
    fi

    ask_choice PULL_SOURCE "How do we get the site?" \
        ssh "Over SSH (needs rsync, and WP-CLI on the server)" \
        backup "From a backup you already have"
    if [ "$PULL_SOURCE" = ssh ]; then
        ask_ssh_source "Connect to the production site you're adopting. Its URL becomes the production URL for media and deploys."
    else
        is_set BACKUP_PATH || info "Any folder or .zip with wp-content and a .sql inside, such as a hosting panel backup. .wpress files and UpdraftPlus's split zips won't work."
        ask BACKUP_PATH "Backup folder or .zip containing wp-content" "" valid_backup
        BACKUP_PATH=$(abs_path "$BACKUP_PATH")
        ask SQL_PATH "Path to the .sql or .sql.gz (blank to find it in the backup)" "-" valid_sql_file
        SQL_PATH=$(abs_path "$SQL_PATH")
    fi

    MODE=adopt
    remember MODE
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    save_answers
    trap on_stage_exit EXIT
    stages_adopt
}

stage_pull() {
    # rsync and the export print nothing until they finish, which looks like a hang.
    warn "This can take several minutes on a large site, with no output while it runs."
    if [ "$PULL_SOURCE" = ssh ]; then
        pull_files_ssh
        pull_db_ssh
    else
        pull_files_backup
    fi
    save_answers
}

valid_pulled_theme() {
    [ -f "wp-content/themes/$1/style.css" ] && return 0
    warn "No theme named $1 in wp-content/themes."
    return 1
}

# Asked after the pull, so defaults can come from the real site.
stage_adopt_questions() {
    local php_default="$PHP_DEFAULT" wp_version="" active="" theme_default="-" detected_prefix detected_url

    detected_url=$(dump_home_url)
    detected_prefix=$(dump_table_prefix)
    if [ "$PULL_SOURCE" = ssh ]; then
        local detected
        detected=$(remote_wp "eval 'echo PHP_MAJOR_VERSION . \".\" . PHP_MINOR_VERSION;'" || true)
        [[ "$detected" =~ ^[0-9]+\.[0-9]+$ ]] && php_default="$detected"
        wp_version=$(remote_wp core version || true)
        active=$(remote_wp option get stylesheet || true)
    fi

    ask PHP_VERSION "PHP version (match the host)" "$php_default" valid_php
    ask OLD_URL "URL of the live site" "$detected_url" valid_url
    ask DB_TABLE_PREFIX "Database table prefix" "${detected_prefix:-wp_}"
    if [[ "$wp_version" =~ ^[0-9]+\.[0-9]+ ]]; then
        WP_CORE_CONSTRAINT="~${BASH_REMATCH[0]}.0"
        export WP_CORE_CONSTRAINT
        remember WP_CORE_CONSTRAINT
    fi

    if [ -n "$active" ] && [ -f "wp-content/themes/$active/style.css" ] \
        && grep -qiE '^[[:space:]]*\*?[[:space:]]*Template:' "wp-content/themes/$active/style.css"; then
        theme_default="$active"
    fi
    info "Themes found: $(find wp-content/themes -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')"
    ask THEME_NAME "Custom theme to track in git (blank if none)" "$theme_default" valid_pulled_theme

    THEME_KIND=none
    if [ -n "$THEME_NAME" ]; then
        THEME_KIND=standalone
        PARENT_THEME=$(sed -nE 's/^[[:space:]]*\*?[[:space:]]*Template:[[:space:]]*([^[:space:]]+).*/\1/p' \
            "wp-content/themes/$THEME_NAME/style.css" | head -n1)
        [ -n "$PARENT_THEME" ] && THEME_KIND=child
    fi
    export THEME_KIND PARENT_THEME THEME_NAME
    remember THEME_KIND
    remember PARENT_THEME

    if [ -n "$THEME_NAME" ]; then
        local assets_default=n
        [ -f "wp-content/themes/$THEME_NAME/assets/scss/main.scss" ] && assets_default=y
        ask_yn ASSETS "Add a webpack + pnpm build for the theme's SCSS and JS (assets/)?" "$assets_default"
    fi

    PRODUCTION_URL="${PRODUCTION_URL:-$OLD_URL}"
    export PRODUCTION_URL
    remember PRODUCTION_URL
    ask_yn PROD_INTEGRATION "Load missing media from production? (Uploads aren't copied locally.)" y
    ask_premium
    ask_deploy
    ask_common

    derive_tokens
    save_answers
}

stage_adopt_files() {
    render_overlay "$STARTER_ROOT/templates/base" . keep
    if [ "$ASSETS" = true ]; then
        render_overlay "$STARTER_ROOT/templates/assets" . keep
        render_overlay "$STARTER_ROOT/templates/theme/assets" "wp-content/themes/$THEME_NAME" keep
    fi
    render_ci_and_deploy keep
    write_auth_example
}

stage_composerize() {
    if [ "$NONINTERACTIVE" = true ]; then
        "$STARTER_ROOT/bin/wp-composerize.sh" --auto-require
    else
        "$STARTER_ROOT/bin/wp-composerize.sh"
    fi
}

# Composer can only install over a clean path, but anything composer.json doesn't
# require has no other copy, so only confirmed Composer-managed entries are removed.
# Matched against require and require-dev only: the project's own name can share a slug.
stage_remove_managed() {
    local -a managed=()
    local path slug required
    required=$(php -r '
        $j = json_decode( file_get_contents( "composer.json" ), true );
        foreach ( array_merge( $j["require"] ?? array(), $j["require-dev"] ?? array() ) as $name => $c ) {
            echo $name, "\n";
        }')
    while IFS= read -r path; do
        slug=$(basename "$path" .php)
        [ "$path" = "wp-content/themes/${THEME_NAME:-}" ] && continue
        [ "$slug" = index ] && continue
        if printf '%s\n' "$required" | grep -qxF -e "wpackagist-plugin/$slug" -e "wpackagist-theme/$slug" \
            || printf '%s\n' "$required" | grep -qE "^[^/]+/${slug}\$"; then
            managed+=("$path")
        fi
    done < <(find wp-content/plugins wp-content/mu-plugins wp-content/themes -mindepth 1 -maxdepth 1 2>/dev/null | sort)

    [ "${#managed[@]}" -gt 0 ] || return 0
    info "Composer will reinstall these, so the pulled copies can go:"
    printf '  %s\n' "${managed[@]}"
    if [ "${AUTO_REMOVE:-false}" = true ] || confirm "Remove them?"; then
        rm -rf "${managed[@]}"
    else
        die "Composer can't install over them. Remove them, then resume."
    fi
}

stage_adopt_db() {
    import_dump
    replace_urls
    disable_outbound_email
}

stages_adopt() {
    # HAS_AUTH and ASSETS are unset until the questions stage answers them.
    add_stage "Pulling the site" stage_pull
    add_stage "Project questions" stage_adopt_questions
    add_stage "Writing project files" stage_adopt_files
    add_stage "Configuring Composer" composer_config_project
    add_stage "Sorting plugins and themes" stage_composerize
    add_stage "Removing Composer-managed copies" stage_remove_managed
    add_stage "Creating .env" write_env
    add_stage "Setting up auth.json" require_auth_json '[ "${HAS_AUTH-true}" = true ]'
    add_stage "Starting Lando" lando_start
    add_stage "Installing Composer packages" composer_install
    add_stage "Building assets" js_install_and_build '[ "${ASSETS-true}" = true ]'
    add_stage "Importing the database" stage_adopt_db
    add_stage "First commit" first_commit
    add_stage "GitHub" create_github_repo
    run_stages
    trap - EXIT

    remove_dump_dir
    close_ssh
    heading "Ready"
    ok "Site:  $DEV_URL"
    ok "Admin: $DEV_URL/cms/wp-admin/ (use your live login)"
    warn "Outbound email is disabled by the disable-emails plugin."
    warn "The local database is a copy of production. Treat it as personal data."
    print_deploy_checklist
    print_skipped_premium
    rm -f "$STATE_FILE" "$ANSWERS_FILE"
}
