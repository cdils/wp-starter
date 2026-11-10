# clone: set up local development for a repo that already exists.

run_clone() {
    heading "Existing repo"
    preflight lando docker git composer php perl openssl

    ask REPO_URL "Repository URL (SSH or HTTPS)"
    local base
    base=$(basename "$REPO_URL" .git)
    ask PROJECT_FOLDER "Local folder name" "$(slugify "$base")" valid_slug
    ask CLONE_BRANCH "Branch (blank for the default)" "-"

    PROJECT_DIR="${PROJECTS_DIR:-$PWD}/$PROJECT_FOLDER"
    [ ! -e "$PROJECT_DIR" ] || die "$PROJECT_DIR already exists."

    local -a args=()
    [ -n "$CLONE_BRANCH" ] && args+=(-b "$CLONE_BRANCH")
    git clone ${args[@]+"${args[@]}"} "$REPO_URL" "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    # Local state stays out of git even if the repo's .gitignore doesn't cover it.
    echo '.wp-project-*' >> .git/info/exclude

    NEEDS_SCAFFOLD=false
    if [ ! -f .lando.yml ] || [ ! -f composer.json ]; then
        NEEDS_SCAFFOLD=true
        warn "This repo isn't fully set up for Lando + Composer. Missing files will be added; existing ones are kept."
        ask PHP_VERSION "PHP version (match the host)" "$PHP_DEFAULT" valid_php
    fi
    export NEEDS_SCAFFOLD
    remember NEEDS_SCAFFOLD

    if [ -f .lando.yml ]; then
        PROJECT_NAME=$(sed -nE 's/^name:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' .lando.yml | head -n1)
    fi
    PROJECT_NAME="${PROJECT_NAME:-$PROJECT_FOLDER}"
    export PROJECT_NAME
    remember PROJECT_NAME
    # A generated composer.json needs a valid package name and author.
    if [ "$NEEDS_SCAFFOLD" = true ]; then ask_common; fi

    ask_choice DB_SOURCE "Where should the database come from?" \
        fresh "A fresh install" \
        dump "A dump file" \
        ssh "A server, over SSH" \
        skip "Skip for now"
    case "$DB_SOURCE" in
        dump)
            ask SQL_PATH "Path to the .sql or .sql.gz file" "" valid_sql_file
            SQL_PATH=$(abs_path "$SQL_PATH")
            ;;
        ssh) ask_ssh_source "Connect to the server to copy the database from. Staging is safer when its content is realistic: production holds real people's data." ;;
        fresh)
            ask ADMIN_USER "WordPress admin username" "admin"
            ask SITE_TITLE "Site title" "$(title_case "$PROJECT_NAME")"
            ask AUTHOR_EMAIL "Admin email" "$(git config user.email 2>/dev/null || echo admin@example.test)"
            ;;
    esac

    MODE=clone
    remember MODE
    THEME_KIND=none
    derive_tokens
    save_answers
    trap on_stage_exit EXIT
    stages_clone
}

needs_auth_json() { [ -n "$(premium_hosts)" ]; }

stage_fill_gaps() {
    render_overlay "$STARTER_ROOT/templates/base" . keep
    if [ -d wp-content/plugins ] || [ -d wp-content/themes ]; then
        if [ "$NONINTERACTIVE" = true ] || confirm "Run wp-composerize now?"; then
            stage_composerize
        fi
    fi
}

clone_js() {
    [ -f package.json ] || return 0
    if ! grep -qE '^[[:space:]]+(pnpm|npm):' .lando.yml; then
        warn "package.json exists but .lando.yml has no pnpm or npm tooling. Skipping the JS build."
        return 0
    fi
    # A broken build is the repo's problem to fix, not a reason to stop local setup.
    if ! js_install_and_build; then
        warn "The JS build failed. Setup will continue; fix the build separately."
    fi
}

stage_clone_db() {
    case "$DB_SOURCE" in
        skip) return 0 ;;
        fresh)
            THEME_KIND=none
            stage_install_wp
            ;;
        ssh)
            pull_db_ssh
            sync_table_prefix
            import_dump
            OLD_URL=$(dump_home_url)
            replace_urls
            disable_outbound_email
            ;;
        dump)
            sync_table_prefix
            import_dump
            OLD_URL=$(dump_home_url)
            replace_urls
            disable_outbound_email
            ;;
    esac
}

stages_clone() {
    add_stage "Adding missing files" stage_fill_gaps '[ "$NEEDS_SCAFFOLD" = true ]'
    add_stage "Creating .env" write_env
    add_stage "Setting up auth.json" require_auth_json needs_auth_json
    add_stage "Starting Lando" lando_start
    add_stage "Installing Composer packages" composer_install
    add_stage "Installing JS packages" clone_js
    add_stage "Setting up the database" stage_clone_db
    run_stages
    trap - EXIT

    remove_dump_dir
    close_ssh
    heading "Ready"
    local url
    url=$(sed -nE 's/^WP_HOME="?([^"]+)"?.*/\1/p' .env.example 2>/dev/null | head -n1)
    ok "Site: ${url:-$DEV_URL}"
    if [ "$DB_SOURCE" = fresh ]; then
        warn "Fresh database: no theme is active yet. Run: lando wp theme activate <theme>"
    fi
    rm -f "$STATE_FILE" "$ANSWERS_FILE"
    [ -z "$(git status --porcelain)" ] || warn "Setup changed tracked files. Check 'git status' before committing."
}
