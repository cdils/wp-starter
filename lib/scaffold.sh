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

# Every premium vendor the wizard knows, as
# label|repository name|repository URL|package|answer variable|username|password.
# Username and password are auth.json placeholders, except where the vendor fixes one.
PREMIUM_VENDOR_HOSTS="composer.deliciousbrains.com composer.gravity.io my.yoast.com"
premium_vendor() {
    case "$1" in
        composer.deliciousbrains.com)
            echo "WP Migrate DB Pro|wp-migrate|https://composer.deliciousbrains.com|deliciousbrains-plugin/wp-migrate-db-pro:^2.7|WP_MIGRATE|{WP_MIGRATE_USERNAME}|{WP_MIGRATE_PASSWORD}" ;;
        composer.gravity.io)
            echo "Gravity Forms|gravity|https://composer.gravity.io|gravity/gravityforms:*|GRAVITY_FORMS|{GRAVITY_LICENSE_KEY}|{THIS_SITE_URL}" ;;
        my.yoast.com)
            # Yoast's username is the literal word "token".
            echo "Yoast SEO Premium|my-yoast|https://my.yoast.com/packages/|yoast/wordpress-seo-premium:*|YOAST_PREMIUM|token|{MYYOAST_TOKEN}" ;;
        *)
            echo "$1|||||{USERNAME}|{PASSWORD}" ;;
    esac
}

write_auth_example() {
    local host flag user pass
    rm -f auth.json.example
    [ "$HAS_AUTH" = true ] || return 0
    for host in $PREMIUM_VENDOR_HOSTS; do
        IFS='|' read -r _ _ _ _ flag user pass <<< "$(premium_vendor "$host")"
        if [ "${!flag:-false}" = true ]; then auth_put auth.json.example "$host" "$user" "$pass"; fi
    done
    chmod 644 auth.json.example
}

composer_config_project() {
    local -a require=() require_dev=()

    local host repo url package flag
    for host in $PREMIUM_VENDOR_HOSTS; do
        IFS='|' read -r _ repo url package flag _ <<< "$(premium_vendor "$host")"
        [ "${!flag:-false}" = true ] || continue
        composer config --no-interaction "repositories.$repo" composer "$url"
        require+=("$package")
    done
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

# Premium repository hosts, one per line. Read from composer.json rather than the
# answers, so a cloned repo's repositories count too.
premium_hosts() {
    [ -f composer.json ] || return 0
    php -r '
        $j = json_decode( file_get_contents( "composer.json" ), true );
        foreach ( $j["repositories"] ?? array() as $r ) {
            $url = $r["url"] ?? "";
            if ( ( $r["type"] ?? "" ) === "composer" && false === strpos( $url, "wpackagist" ) ) {
                echo parse_url( $url, PHP_URL_HOST ), "\n";
            }
        }'
}

auth_label() {
    local label
    IFS='|' read -r label _ <<< "$(premium_vendor "$1")"
    echo "$label"
}

auth_json_ok() {
    php -r 'exit( is_array( json_decode( file_get_contents( "auth.json" ), true ) ) ? 0 : 1 );'
}

# auth_status host: ok, missing, or placeholder (still holds a {LIKE_THIS} value).
auth_status() {
    AUTH_HOST="$1" php -r '
        $j = is_file( "auth.json" ) ? json_decode( file_get_contents( "auth.json" ), true ) : array();
        $e = $j["http-basic"][ getenv( "AUTH_HOST" ) ] ?? null;
        if ( ! is_array( $e ) || empty( $e["username"] ) || empty( $e["password"] ) ) {
            echo "missing";
            exit;
        }
        foreach ( $e as $v ) {
            if ( preg_match( "/^\{[A-Z_]+\}$/", (string) $v ) ) {
                echo "placeholder";
                exit;
            }
        }
        echo "ok";'
}

# auth_get host username|password
auth_get() {
    AUTH_HOST="$1" AUTH_FIELD="$2" php -r '
        $j = json_decode( file_get_contents( "auth.json" ), true );
        echo $j["http-basic"][ getenv( "AUTH_HOST" ) ][ getenv( "AUTH_FIELD" ) ] ?? "";'
}

# auth_put file host username password: an empty username removes the entry, and a
# file left with no entries is deleted. Values travel in the environment, not argv.
auth_put() {
    (umask 077 && AUTH_FILE="$1" AUTH_HOST="$2" AUTH_USER="$3" AUTH_PASS="$4" php -r '
        $f = getenv( "AUTH_FILE" );
        $j = is_file( $f ) ? json_decode( file_get_contents( $f ), true ) : array();
        if ( "" === getenv( "AUTH_USER" ) ) {
            unset( $j["http-basic"][ getenv( "AUTH_HOST" ) ] );
        } else {
            $j["http-basic"][ getenv( "AUTH_HOST" ) ] = array(
                "username" => getenv( "AUTH_USER" ),
                "password" => getenv( "AUTH_PASS" ),
            );
        }
        if ( empty( $j["http-basic"] ) ) {
            unset( $j["http-basic"] );
        }
        if ( empty( $j ) ) {
            is_file( $f ) && unlink( $f );
            exit;
        }
        file_put_contents( $f, json_encode( $j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) . "\n" );')
}

# Only Gravity rejects bad credentials before a real download, so only it is checked
# here. Anything but an auth error passes: a network blip shouldn't block setup.
auth_valid() {
    [ "$1" = composer.gravity.io ] || return 0
    local user pass status
    user=$(auth_get "$1" username)
    pass=$(auth_get "$1" password)
    user="${user//\\/\\\\}"
    pass="${pass//\\/\\\\}"
    status=$(printf 'user = "%s:%s"\n' "${user//\"/\\\"}" "${pass//\"/\\\"}" \
        | curl -s -I --max-time 15 -o /dev/null -w '%{http_code}' -K - \
            "https://composer.gravity.io/downloads/?plugin=gravityforms" || true)
    case "$status" in
        401|402|403) return 1 ;;
        000) warn "Couldn't reach Gravity Forms to check the license. Continuing." ;;
    esac
    return 0
}

# You fill in auth.json yourself: it starts with placeholders, and setup waits until
# they're replaced. Licenses are usually per client, so nothing is reused across projects.
require_auth_json() {
    local -a hosts=() problems=() problem_hosts=()
    local host label user pass reply
    while IFS= read -r host; do
        [ -n "$host" ] && hosts+=("$host")
    done < <(premium_hosts)
    [ "${#hosts[@]}" -gt 0 ] || return 0

    if [ ! -e auth.json ] || auth_json_ok; then
        for host in "${hosts[@]}"; do
            if [ "$(auth_status "$host")" = missing ]; then
                IFS='|' read -r _ _ _ _ _ user pass <<< "$(premium_vendor "$host")"
                auth_put auth.json "$host" "$user" "$pass"
            fi
        done
    fi
    chmod 600 auth.json

    while true; do
        problems=()
        problem_hosts=()
        if ! auth_json_ok; then
            problems+=("auth.json isn't valid JSON.")
            problem_hosts=("${hosts[@]}")
        else
            for host in "${hosts[@]}"; do
                label=$(auth_label "$host")
                if [ "$(auth_status "$host")" != ok ]; then
                    problems+=("$label: replace the {PLACEHOLDERS}.")
                elif [ "$host" = "${AUTH_REJECTED:-}" ]; then
                    problems+=("$label: rejected at the last Composer install. Check the values and that the license is active.")
                elif ! auth_valid "$host"; then
                    problems+=("$label: rejected these credentials. Check the values and that the license is active.")
                else
                    continue
                fi
                problem_hosts+=("$host")
            done
        fi
        [ "${#problems[@]}" -gt 0 ] || break

        warn "auth.json needs your premium plugin credentials:"
        printf '  - %s\n' "${problems[@]}"
        info "File: $PWD/auth.json (auth.json.example shows the format)"
        [ "$NONINTERACTIVE" = false ] || die "Fill in auth.json, then resume."
        if [ "$MODE" = clone ]; then
            # The repo's composer.json is the team's, so its plugins can't be dropped here.
            read_line reply "Edit it, then press Enter: "
        else
            read_line reply "Edit it, then press Enter (or type skip to set up without these plugins): "
            if [ "$reply" = skip ]; then
                skip_premium "${problem_hosts[@]}"
                break
            fi
        fi
        # A rejection from Composer can't be rechecked here, so the edit is trusted.
        AUTH_REJECTED=""
    done
    AUTH_REJECTED=""
    export AUTH_REJECTED
    remember AUTH_REJECTED
}

# Drops premium plugins this run added, so setup can finish while a license is pending.
skip_premium() {
    local host label repo url package flag
    for host in "$@"; do
        IFS='|' read -r label repo url package flag _ <<< "$(premium_vendor "$host")"
        [ -n "$flag" ] || continue
        # A lock from an earlier install still lists the plugin, and install follows the
        # lock, so it's updated too. Removing needs no download, and no credentials.
        if [ -f composer.lock ]; then
            composer remove --no-interaction --no-install "${package%%:*}"
        else
            composer remove --no-interaction --no-update "${package%%:*}"
        fi
        composer config --no-interaction --unset "repositories.$repo"
        printf -v "$flag" '%s' false
        export "${flag?}"
        remember "$flag"
        SKIPPED_PREMIUM="${SKIPPED_PREMIUM:-} $host"
        if [ -e auth.json ] && auth_json_ok; then auth_put auth.json "$host" "" ""; fi
    done
    export SKIPPED_PREMIUM
    remember SKIPPED_PREMIUM
    derive_tokens
    write_auth_example
    save_answers
    print_skipped_premium
}

print_skipped_premium() {
    local host label repo url package user pass
    for host in ${SKIPPED_PREMIUM:-}; do
        IFS='|' read -r label repo url package _ user pass <<< "$(premium_vendor "$host")"
        printf "\n"
        warn "$label was skipped. To add it later, put this in auth.json under \"http-basic\":"
        info "  \"$host\": { \"username\": \"$user\", \"password\": \"$pass\" }"
        info "Then run:"
        info "  lando composer config repositories.$repo composer $url"
        info "  lando composer require ${package%%:*}"
    done
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

# Composer's own auth errors bury the cause in a stack of usage text, so name it.
composer_install() {
    local log status=0 host
    log=$(mktemp)
    lando composer install --no-interaction 2>&1 | tee "$log" || status=$?
    if [ "$status" -ne 0 ]; then
        # Joined first: Composer wraps long URLs across lines.
        host=$(tr '\n' ' ' < "$log" \
            | sed -nE 's|.*"https://([^/"]+)/[^"]*" file could not be downloaded \(HTTP/[0-9.]+ 40[123].*|\1|p')
        if [ -n "$host" ]; then
            printf "\n"
            warn "$(auth_label "$host") rejected the credentials in auth.json."
            if [ "$MODE" = clone ]; then
                warn "Resume waits while you fix them."
            else
                warn "Resume waits while you fix them, or lets you skip the plugin."
            fi
            # Repeats the auth step on resume, flagged, so it stops there before installing again.
            AUTH_REJECTED="$host"
            export AUTH_REJECTED
            remember AUTH_REJECTED
            save_answers
            grep -vx require_auth_json "$STATE_FILE" > "$STATE_FILE.tmp" || true
            mv "$STATE_FILE.tmp" "$STATE_FILE"
        fi
    fi
    rm -f "$log"
    return "$status"
}

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
