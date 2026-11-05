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
        ask_ssh_source
    else
        ask BACKUP_PATH "Backup folder or .zip containing wp-content"
        ask SQL_PATH "Path to the .sql or .sql.gz (blank to find it in the backup)" "-"
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
    if [ "$PULL_SOURCE" = ssh ]; then
        pull_files_ssh
        pull_db_ssh
    else
        pull_files_backup
    fi
    save_answers
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
    ask THEME_NAME "Custom theme to track in git (blank if none)" "$theme_default"

    THEME_KIND=none
    if [ -n "$THEME_NAME" ]; then
        [ -f "wp-content/themes/$THEME_NAME/style.css" ] || die "No such theme: $THEME_NAME"
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
        ask_yn ASSETS "Use the webpack + pnpm asset build?" "$assets_default"
    fi

    PRODUCTION_URL="${PRODUCTION_URL:-$OLD_URL}"
    export PRODUCTION_URL
    remember PRODUCTION_URL
    ask_yn PROD_INTEGRATION "Proxy missing media from production?" y
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
stage_remove_managed() {
    local -a managed=()
    local path slug
    while IFS= read -r path; do
        slug=$(basename "$path" .php)
        [ "$path" = "wp-content/themes/${THEME_NAME:-}" ] && continue
        [ "$slug" = index ] && continue
        if grep -qE "\"[^\"]+/${slug}\"" composer.json; then
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
    run_stage "Pulling the site" stage_pull
    run_stage "Project questions" stage_adopt_questions
    # shellcheck disable=SC1090
    . "./$ANSWERS_FILE"
    derive_tokens
    run_stage "Writing project files" stage_adopt_files
    run_stage "Configuring Composer" composer_config_project
    run_stage "Sorting plugins and themes" stage_composerize
    run_stage "Removing Composer-managed copies" stage_remove_managed
    run_stage "Creating .env" write_env
    if [ "$HAS_AUTH" = true ]; then run_stage "Checking auth.json" require_auth_json; fi
    run_stage "Starting Lando" lando_start
    run_stage "Installing Composer packages" composer_install
    if [ "$ASSETS" = true ]; then run_stage "Building assets" js_install_and_build; fi
    run_stage "Importing the database" stage_adopt_db
    run_stage "First commit" first_commit
    run_stage "GitHub" create_github_repo
    trap - EXIT

    remove_dump_dir
    heading "Ready"
    ok "Site:  $DEV_URL"
    ok "Admin: $DEV_URL/cms/wp-admin/ (use your live login)"
    warn "Outbound email is disabled by the disable-emails plugin."
    warn "The local database is a copy of production. Treat it as personal data."
    print_deploy_checklist
    rm -f "$STATE_FILE" "$ANSWERS_FILE"
}
