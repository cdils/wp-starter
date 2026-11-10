# Shared answers, token derivation, template rendering, and the setup steps every mode uses.

title_case() {
    echo "$1" | tr '-' ' ' | awk '{ for (i=1; i<=NF; i++) $i=toupper(substr($i,1,1)) substr($i,2) } 1'
}

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' \
        | sed -E 's/[^a-z0-9-]//g; s/-+/-/g; s/^-//; s/-$//'
}

ask_common() {
    local git_name git_email gh_login=""
    git_name=$(git config user.name 2>/dev/null || true)
    git_email=$(git config user.email 2>/dev/null || true)

    ask AUTHOR_NAME "Author name" "${git_name:--}"
    # Required: WordPress needs it for the admin user, and composer.json for the author.
    ask AUTHOR_EMAIL "Author email" "$git_email"
    if ! is_set GITHUB_OWNER; then
        info "GitHub owner and repo name the composer.json package and README, and create the repo at the end if you choose to."
        # Only a logged-in gh knows who you are; otherwise the answer is required.
        if command -v gh >/dev/null 2>&1; then
            gh_login=$(gh api user -q .login 2>/dev/null || true)
        fi
    fi
    ask GITHUB_OWNER "GitHub username or organization" "$gh_login"
    ask GITHUB_REPO "GitHub repository name" "$PROJECT_NAME"
}

ask_premium() {
    ask_yn WP_MIGRATE "Use WP Migrate DB Pro (needs auth.json)?" n
    ask_yn GRAVITY_FORMS "Use Gravity Forms from its Composer repo (needs auth.json)?" n
    ask_yn YOAST_PREMIUM "Use Yoast SEO Premium from its Composer repo (needs auth.json)?" n
}

ask_production() {
    ask PRODUCTION_URL "Production URL (optional)" "-" valid_url
    if [ -n "$PRODUCTION_URL" ]; then
        ask_yn PROD_INTEGRATION "Load missing media from production? (Uploads aren't copied locally.)" n
    else
        PROD_INTEGRATION=false
        export PROD_INTEGRATION
        remember PROD_INTEGRATION
    fi
}

# Everything templates can reference. Called again on resume, so it must only derive.
derive_tokens() {
    export PROJECT_NAME PHP_VERSION="${PHP_VERSION:-$PHP_DEFAULT}" GITHUB_OWNER="${GITHUB_OWNER:-}"
    export GITHUB_REPO="${GITHUB_REPO:-$PROJECT_NAME}" AUTHOR_NAME="${AUTHOR_NAME:-}" AUTHOR_EMAIL="${AUTHOR_EMAIL:-}"
    export THEME_KIND="${THEME_KIND:-none}" THEME_NAME="${THEME_NAME:-}" PARENT_THEME="${PARENT_THEME:-}"
    export ASSETS="${ASSETS:-false}" PRODUCTION_URL="${PRODUCTION_URL:-}"
    export PROD_INTEGRATION="${PROD_INTEGRATION:-false}" DB_TABLE_PREFIX="${DB_TABLE_PREFIX:-wp_}"
    export WP_MIGRATE="${WP_MIGRATE:-false}" GRAVITY_FORMS="${GRAVITY_FORMS:-false}"
    export YOAST_PREMIUM="${YOAST_PREMIUM:-false}"

    export PHP_PLATFORM="$PHP_VERSION"
    COMPOSER_NAME=$(echo "${GITHUB_OWNER}/${GITHUB_REPO}" | tr '[:upper:]' '[:lower:]')
    export COMPOSER_NAME
    export HOMEPAGE_URL="${PRODUCTION_URL:-https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}}"
    export PRODUCTION_URL_OR_REPO="$HOMEPAGE_URL"
    export DEV_URL="https://${PROJECT_NAME}.lndo.site"

    HAS_THEME=false
    [ "$THEME_KIND" != "none" ] && HAS_THEME=true
    export HAS_THEME
    THEME_TITLE=$(title_case "$THEME_NAME")
    export THEME_TITLE
    case "$THEME_KIND" in
        child) THEME_SUMMARY="\`wp-content/themes/${THEME_NAME}\` is a committed child of **${PARENT_THEME}**, which Composer installs (update it with \`lando composer update wpackagist-theme/${PARENT_THEME}\`; never edit it directly)." ;;
        standalone) THEME_SUMMARY="\`wp-content/themes/${THEME_NAME}\` is a committed custom theme with no parent." ;;
        *) THEME_SUMMARY="" ;;
    esac
    export THEME_SUMMARY

    HAS_AUTH=false
    if [ "$WP_MIGRATE" = true ] || [ "$GRAVITY_FORMS" = true ] || [ "$YOAST_PREMIUM" = true ]; then
        HAS_AUTH=true
    fi
    export HAS_AUTH

    derive_deploy_tokens
}

# render_overlay SOURCE_DIR DEST_DIR overwrite|keep
render_overlay() {
    local src="$1" dest="$2" policy="$3" file rel target
    while IFS= read -r file; do
        rel="${file#"$src"/}"
        case "$rel" in
            gitignore.tmpl) rel=".gitignore" ;;
            *.tmpl) rel="${rel%.tmpl}" ;;
        esac
        if [ "$HAS_STAGING" != true ] && [ "$(basename "$rel")" = "deploy-staging.yml" ]; then
            continue
        fi
        target="$dest/$rel"
        if [ -e "$target" ] && [ "$policy" = keep ]; then
            info "Kept existing: $rel"
            continue
        fi
        mkdir -p "$(dirname "$target")"
        perl "$STARTER_ROOT/lib/render.pl" "$rel" < "$file" > "$target"
    done < <(find "$src" -type f ! -name .DS_Store | sort)
}

write_auth_example() {
    [ "$HAS_AUTH" = true ] || return 0
    local -a entries=()
    [ "$WP_MIGRATE" = true ] && entries+=('composer.deliciousbrains.com|{WP_MIGRATE_USERNAME}|{WP_MIGRATE_PASSWORD}')
    [ "$GRAVITY_FORMS" = true ] && entries+=('composer.gravity.io|{GRAVITY_LICENSE_KEY}|{GRAVITY_SITE_URL}')
    [ "$YOAST_PREMIUM" = true ] && entries+=('my.yoast.com|{MYYOAST_TOKEN_ID}|{MYYOAST_TOKEN_SECRET}')

    local entry host user pass i=0 last=$((${#entries[@]} - 1))
    {
        printf '{\n    "http-basic": {\n'
        for entry in "${entries[@]}"; do
            IFS='|' read -r host user pass <<< "$entry"
            printf '        "%s": {\n            "username": "%s",\n            "password": "%s"\n        }' "$host" "$user" "$pass"
            [ "$i" -lt "$last" ] && printf ','
            printf '\n'
            i=$((i + 1))
        done
        printf '    }\n}\n'
    } > auth.json.example
}

composer_config_project() {
    local -a require=() require_dev=()

    if [ "$WP_MIGRATE" = true ]; then
        composer config --no-interaction repositories.wp-migrate composer https://composer.deliciousbrains.com
        require+=("deliciousbrains-plugin/wp-migrate-db-pro:^2.7")
    fi
    if [ "$GRAVITY_FORMS" = true ]; then
        composer config --no-interaction repositories.gravity composer https://composer.gravity.io
        require+=("gravity/gravityforms:*")
    fi
    if [ "$YOAST_PREMIUM" = true ]; then
        composer config --no-interaction repositories.my-yoast composer https://my.yoast.com/packages/
        require+=("yoast/wordpress-seo-premium:*")
    fi
    if [ "$PROD_INTEGRATION" = true ]; then
        composer config --no-interaction repositories.mgratch vcs https://github.com/mgratch/mg-media-management
        require_dev+=("mgratch/mg-media-management:1.1.0")
    fi
    if [ "$THEME_KIND" = child ] && [ "$MODE" != adopt ]; then
        require+=("wpackagist-theme/${PARENT_THEME}:*")
    fi

    if [ "${#require[@]}" -gt 0 ]; then
        composer require --no-interaction --no-update "${require[@]}"
    fi
    if [ "${#require_dev[@]}" -gt 0 ]; then
        composer require --no-interaction --no-update --dev "${require_dev[@]}"
    fi
}

# Salts are generated locally, so they never pass through a network service.
write_env() {
    if [ -e .env ]; then
        info "Kept existing .env"
        return 0
    fi
    [ -f .env.example ] || die "No .env.example to build .env from."

    local key
    cp .env.example .env
    chmod 600 .env
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        WP_SALT=$(openssl rand -hex 32) perl -pi -e \
            "s/^${key}=.*/${key}=\"\$ENV{WP_SALT}\"/" .env
    done
}

require_auth_json() {
    [ -e auth.json ] && { chmod 600 auth.json; return 0; }

    local source=""
    warn "This project needs auth.json for its premium Composer repositories."
    [ -f auth.json.example ] && info "See auth.json.example for the format."
    if [ "$NONINTERACTIVE" = false ]; then
        read_line source "Path to an auth.json to copy (Enter to stop and add it yourself): "
    fi
    source=$(abs_path "$source")
    [ -n "$source" ] || die "Add auth.json to this folder, then resume."
    [ -f "$source" ] || die "Not found: $source"
    cp "$source" auth.json
    chmod 600 auth.json
}

# Lando names containers and volumes after the app, not the folder. A second checkout
# with the same name would run every command against the first project and its database.
guard_lando_app() {
    command -v docker >/dev/null 2>&1 || return 0
    local name owner
    name=$(sed -nE 's/^name:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' .lando.yml | head -n1 | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    owner=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app"}}{{.Source}}{{end}}{{end}}' "${name}_appserver_1" 2>/dev/null || true)
    owner="${owner#/host_mnt}"
    if [ -n "$owner" ] && [ "$owner" != "$(pwd -P)" ]; then
        die "Lando app '$name' already belongs to $owner. Change 'name:' in .lando.yml or remove this copy. Nothing was started."
    fi
}

lando_start() {
    guard_lando_app
    lando start
}

composer_install() { lando composer install --no-interaction; }

# Keeps whichever package manager the repo already uses.
js_install_and_build() {
    if [ -f pnpm-lock.yaml ] || grep -q '"packageManager": *"pnpm' package.json 2>/dev/null; then
        lando pnpm install
        if grep -q '"build"' package.json; then lando pnpm build; fi
    elif [ -f package-lock.json ]; then
        lando npm ci
        if grep -q '"build"' package.json; then lando npm run build; fi
    elif [ -f package.json ]; then
        lando npm install
        if grep -q '"build"' package.json; then lando npm run build; fi
    fi
}

# The first commit is reviewed by a person: it is where personal data or premium code
# would enter history. A --config run stops short of committing.
first_commit() {
    local initial="${PROD_BRANCH:-main}"
    if [ ! -d .git ]; then
        git init -q -b "$initial"
    fi
    git add -A
    # Global gitignores often exclude CLAUDE.md, but cloners need its AGENTS.md import.
    if [ -f CLAUDE.md ]; then git add -f CLAUDE.md; fi

    local tracked
    tracked=$(git diff --cached --name-only)
    info "$(printf '%s\n' "$tracked" | wc -l | tr -d ' ') files staged. Top-level summary:"
    printf '%s\n' "$tracked" | awk -F/ '{ print ($2 == "" ? $1 : $1 "/" $2) }' | sort | uniq -c | sort -rn | head -25

    if printf '%s\n' "$tracked" | grep -qE '(^|/)(\.env|auth\.json)$|\.sql(\.gz)?$'; then
        die "A credentials file or database dump is staged. Fix .gitignore before committing."
    fi

    warn "composer.json includes the author name and email."
    if [ "${AUTO_COMMIT:-false}" = true ] || confirm "Create the first commit?"; then
        git commit -q -m "Initial project scaffold"
        if [ "${HAS_STAGING:-false}" = true ] && ! git show-ref --verify --quiet "refs/heads/$STAGING_BRANCH"; then
            git branch "$STAGING_BRANCH"
        fi
        ok "Committed."
    else
        info "Left staged and uncommitted."
    fi
}

# Publishing is always an explicit yes, and the repo is private unless you change it.
create_github_repo() {
    command -v gh >/dev/null 2>&1 || { info "gh isn't installed; skipping."; return 0; }
    git rev-parse --verify -q HEAD >/dev/null || { info "No commit yet; skipping GitHub."; return 0; }
    git remote get-url origin >/dev/null 2>&1 && { info "Remote 'origin' already set."; return 0; }

    confirm "Create a private GitHub repo ${GITHUB_OWNER}/${GITHUB_REPO} and push?" || return 0
    gh repo create "${GITHUB_OWNER}/${GITHUB_REPO}" --private --source=. --remote=origin
    git push -u origin --all
}

print_deploy_checklist() {
    [ "$DEPLOY" = true ] || return 0
    printf "\n${YELLOW}Before the first deploy:${NC}\n"
    info "  1. Create the environments, and add a required reviewer to production."
    info "  2. Add the secrets: $SECRET_NAMES"
    if [ "$TRANSPORT" = rsync ]; then
        info "  3. Run the deploy workflow by hand with dry_run on, and read the file list."
    else
        info "  3. List what's on the server first: anything host-managed that the repo lacks needs an exclude."
    fi
    info "  4. Check the docroot has its own wp-config.php. Deploys never ship one."
    info "  5. Then set the repository variable DEPLOY_ENABLED to true. Until then, pushes don't deploy."
}
