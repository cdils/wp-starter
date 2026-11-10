# new: build a site from nothing.

ask_theme() {
    ask_choice THEME_KIND "What's the theme setup?" \
        child "A child of a wordpress.org theme" \
        standalone "A custom theme with no parent" \
        none "No theme yet"

    case "$THEME_KIND" in
        child)
            ask_choice PARENT_CHOICE "Which parent theme?" \
                ollie "Ollie" \
                astra "Astra" \
                other "Another wordpress.org theme"
            if [ "$PARENT_CHOICE" = other ]; then
                ask PARENT_THEME "Parent theme slug" "" valid_parent_theme
            else
                PARENT_THEME="$PARENT_CHOICE"
                ask PARENT_THEME "Parent theme slug" "$PARENT_CHOICE" valid_parent_theme
            fi
            ask_theme_source
            ;;
        standalone)
            ask_theme_source
            ;;
        none)
            export THEME_NAME="" PARENT_THEME=""
            ;;
    esac
}

valid_parent_theme() {
    valid_slug "$1" || return 1
    local url="https://api.wordpress.org/themes/info/1.2/?action=theme_information&request%5Bslug%5D=$1"
    curl -fsS -L --max-time 15 "$url" 2>/dev/null | grep -q '"slug"' && return 0
    warn "'$1' wasn't found on wordpress.org."
    return 1
}

# Zip, folder or URL. Blank scaffolds a minimal theme.
ask_theme_source() {
    while true; do
        ask THEME_SOURCE "Theme starter: zip, folder or URL (blank to scaffold one)" "-"
        THEME_SOURCE=$(abs_path "$THEME_SOURCE")
        if [ -z "$THEME_SOURCE" ] || [[ "$THEME_SOURCE" =~ ^https?:// ]] || [ -e "$THEME_SOURCE" ]; then
            break
        elif [ -e "${THEME_SOURCE}.zip" ]; then
            THEME_SOURCE="${THEME_SOURCE}.zip"
            break
        fi
        [ "$NONINTERACTIVE" = false ] || die "Not found: $THEME_SOURCE"
        warn "Not found: $THEME_SOURCE"
        unset THEME_SOURCE
    done
    export THEME_SOURCE

    local default="$PROJECT_NAME" base
    if [ -n "$THEME_SOURCE" ]; then
        base=$(basename "$THEME_SOURCE")
        base="${base%%\?*}"
        default=$(slugify "${base%.zip}")
        default="${default:-$PROJECT_NAME}"
    fi
    # Never collide with the Composer-managed parent folder.
    [ "$default" = "${PARENT_THEME:-}" ] && default="${default}-child"
    ask THEME_NAME "Theme folder name" "$default" valid_slug
}

run_new() {
    heading "New project"
    preflight lando docker git composer php perl openssl curl

    ask PROJECT_NAME "Project name (e.g. acme-widgets)" "" valid_slug
    PROJECT_DIR="${PROJECTS_DIR:-$PWD}/$PROJECT_NAME"
    if [ -e "$PROJECT_DIR" ] && [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null | grep -v '^\.DS_Store$')" ]; then
        die "$PROJECT_DIR already exists and isn't empty."
    fi

    ask PHP_VERSION "PHP version (match the host)" "$PHP_DEFAULT" valid_php
    ask_theme
    if [ "$THEME_KIND" = none ]; then
        ASSETS=false
        export ASSETS
        remember ASSETS
    else
        ask_yn ASSETS "Add a webpack + pnpm build for the theme's SCSS and JS (assets/)?" n
    fi
    ask_production
    ask_premium
    ask_deploy
    ask ADMIN_USER "WordPress admin username" "admin"
    ask SITE_TITLE "Site title" "$(title_case "$PROJECT_NAME")"
    ask_common

    derive_tokens
    MODE=new
    remember MODE

    heading "Summary"
    info "Project:      $PROJECT_DIR"
    info "PHP:          $PHP_VERSION"
    case "$THEME_KIND" in
        child) info "Theme:        $THEME_NAME (child of $PARENT_THEME)" ;;
        standalone) info "Theme:        $THEME_NAME (no parent)" ;;
        none) info "Theme:        none yet" ;;
    esac
    info "Asset build:  $ASSETS"
    info "Production:   ${PRODUCTION_URL:-none yet}"
    if [ "$DEPLOY" = true ]; then
        info "Deploy:       $HOST_LABEL ($TRANSPORT)"
    else
        info "Deploy:       none (CI only)"
    fi
    info "GitHub:       $GITHUB_OWNER/$GITHUB_REPO"
    printf "\n"

    if [ "$NONINTERACTIVE" = false ] && ! confirm "Build it?"; then
        info "Aborted."
        exit 1
    fi

    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    save_answers
    trap on_stage_exit EXIT
    stages_new
}

stages_new() {
    add_stage "Writing project files" stage_files
    add_stage "Configuring Composer" composer_config_project
    add_stage "Setting up the theme" stage_theme
    add_stage "Creating .env" write_env
    add_stage "Setting up auth.json" require_auth_json '[ "$HAS_AUTH" = true ]'
    add_stage "Starting Lando" lando_start
    add_stage "Installing Composer packages" composer_install
    add_stage "Building assets" js_install_and_build '[ "$ASSETS" = true ]'
    add_stage "Installing WordPress" stage_install_wp
    add_stage "First commit" first_commit
    add_stage "GitHub" create_github_repo
    run_stages
    trap - EXIT
    finish_new
}

stage_files() {
    render_overlay "$STARTER_ROOT/templates/base" . overwrite
    if [ "$ASSETS" = true ]; then
        render_overlay "$STARTER_ROOT/templates/assets" . overwrite
    fi
    render_ci_and_deploy
    write_auth_example
}

stage_theme() {
    [ "$THEME_KIND" != none ] || return 0
    local dest="wp-content/themes/$THEME_NAME"
    mkdir -p "$dest"

    if [ -n "$THEME_SOURCE" ]; then
        install_theme_source "$dest"
    else
        render_overlay "$STARTER_ROOT/templates/theme/$THEME_KIND" "$dest" overwrite
    fi

    if [ "$THEME_KIND" = child ] && [ -f "$dest/style.css" ]; then
        if grep -qE '^[[:space:]]*Template:' "$dest/style.css"; then
            PARENT_THEME="$PARENT_THEME" perl -pi -e \
                's/^(\s*Template:).*/$1 $ENV{PARENT_THEME}/' "$dest/style.css"
        else
            warn "style.css has no Template: header. Add 'Template: $PARENT_THEME'."
        fi
    fi

    if [ "$ASSETS" = true ]; then
        local had_functions=false
        [ -f "$dest/functions.php" ] && had_functions=true
        render_overlay "$STARTER_ROOT/templates/theme/assets" "$dest" keep
        if [ "$had_functions" = true ]; then
            warn "Your theme kept its own functions.php. Check it enqueues assets/css/main.css and assets/js/main.min.js."
        fi
    fi
}

install_theme_source() {
    local dest="$1" tmp src=""
    tmp=$(mktemp -d)

    if [[ "$THEME_SOURCE" =~ ^https?:// ]]; then
        info "Downloading $THEME_SOURCE"
        curl -fsSL "$THEME_SOURCE" -o "$tmp/theme.zip"
        unzip -q "$tmp/theme.zip" -d "$tmp/extracted"
        src="$tmp/extracted"
    elif [ -d "$THEME_SOURCE" ]; then
        src="$THEME_SOURCE"
    else
        unzip -q "$THEME_SOURCE" -d "$tmp/extracted"
        src="$tmp/extracted"
    fi

    # If everything sits in one top-level folder, descend into it.
    local -a entries=()
    local entry
    while IFS= read -r entry; do
        case "$(basename "$entry")" in
            __MACOSX|.DS_Store) ;;
            *) entries+=("$entry") ;;
        esac
    done < <(find "$src" -mindepth 1 -maxdepth 1)
    if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
        src="${entries[0]}"
    fi

    cp -R "$src"/. "$dest"/
    rm -rf "$tmp"
    info "Installed theme into $dest"
}

stage_install_wp() {
    local password
    password=$(openssl rand -base64 18 | tr -d '/+=')

    if lando wp core is-installed >/dev/null 2>&1; then
        # A resumed run: core install would keep the old password, never shown, so reset it.
        lando wp user update "$ADMIN_USER" --user_pass="$password" --skip-email
    else
        lando wp core install \
            --url="$DEV_URL" \
            --title="$SITE_TITLE" \
            --admin_user="$ADMIN_USER" \
            --admin_password="$password" \
            --admin_email="$AUTHOR_EMAIL" \
            --skip-email
    fi
    lando wp rewrite structure '/%postname%/'
    if [ "$THEME_KIND" != none ]; then
        lando wp theme activate "$THEME_NAME"
    fi
    if [ "$WP_MIGRATE" = true ]; then
        lando wp plugin activate wp-migrate-db-pro
    fi

    # Shown once and never stored. Reset with: lando wp user update <user> --prompt=user_pass
    printf "\n${YELLOW}Admin login (shown once):${NC}\n"
    info "  User:     $ADMIN_USER"
    info "  Password: $password"
}

finish_new() {
    heading "Ready"
    ok "Site:  $DEV_URL"
    ok "Admin: $DEV_URL/cms/wp-admin/"
    ok "Mail:  https://mail.${PROJECT_NAME}.lndo.site"
    [ "$THEME_KIND" = none ] && warn "No theme is installed yet, so the front end will be blank."
    print_deploy_checklist
    print_skipped_premium
    if [ "${PARENT_THEME:-}" = ollie ]; then
        printf "\nTo connect Ollie's MCP server to Claude Code, install Ollie Pro, then run:\n"
        info "  $STARTER_ROOT/bin/ollie-mcp.sh"
    fi
    rm -f "$STATE_FILE" "$ANSWERS_FILE"
}
