# Deployment answers, tokens and rendering. Hosts are data: see templates/deploy/hosts/.

ask_deploy() {
    ask_choice DEPLOY_HOST "Where does this site deploy?" \
        none "Not decided yet (CI only)" \
        bigscoots "BigScoots" \
        wpengine "WP Engine" \
        siteground "SiteGround" \
        hostgator "HostGator" \
        godaddy "GoDaddy (SFTP)" \
        ssh "Other host with SSH and rsync" \
        sftp "Other host with SFTP only"

    if [ "$DEPLOY_HOST" = none ]; then
        return 0
    fi

    ask PROD_BRANCH "Production branch" "main" valid_branch
    ask_yn HAS_STAGING "Is there a staging site?" y
    if [ "$HAS_STAGING" = true ]; then
        ask STAGING_BRANCH "Staging branch" "develop" valid_branch
        ask STAGING_URL "Staging URL" "" valid_url
    fi
    if [ "$DEPLOY_HOST" = wpengine ]; then
        ask WPE_ENV_PRODUCTION "WP Engine production install name (the acme in acme.wpengine.com)" "" valid_slug
        if [ "$HAS_STAGING" = true ]; then
            ask WPE_ENV_STAGING "WP Engine staging install name (the acmestg in acmestg.wpengine.com)" "" valid_slug
        fi
    fi
}

# Space-separated preset values become the flag syntax each transport expects. Each one
# is anchored to the transfer root. Both run in a subshell, so set -f (no globbing:
# sucuri-*.php is a pattern for rsync, not for this shell) doesn't leak.
rsync_flags() {
    local item
    set -f
    for item in $1; do
        printf -- "--exclude='/%s' \\\\\n" "$item"
    done
}

prefixed_flags() {
    local item
    set -f
    for item in $2; do
        printf -- " --exclude=%s%s%s" "$3" "$item" "$1"
    done
}

derive_deploy_tokens() {
    export DEPLOY_HOST="${DEPLOY_HOST:-none}" HAS_STAGING="${HAS_STAGING:-false}"
    # Staging only means something with a deploy target.
    [ "$DEPLOY_HOST" != none ] || HAS_STAGING=false
    export PROD_BRANCH="${PROD_BRANCH:-main}" STAGING_BRANCH="${STAGING_BRANCH:-develop}"
    export STAGING_URL="${STAGING_URL:-}"
    export WPE_ENV_PRODUCTION="${WPE_ENV_PRODUCTION:-}" WPE_ENV_STAGING="${WPE_ENV_STAGING:-}"

    DEPLOY=false
    [ "$DEPLOY_HOST" != none ] && DEPLOY=true
    export DEPLOY

    export CI_BRANCHES="$PROD_BRANCH"
    [ "$HAS_STAGING" = true ] && CI_BRANCHES="$STAGING_BRANCH, $PROD_BRANCH"

    export STAGING_ENV_NOTE=""
    [ "$HAS_STAGING" = true ] && STAGING_ENV_NOTE=" and \`staging\`"

    export SSH_ALIAS_PRODUCTION="${PROJECT_NAME}-production" SSH_ALIAS_STAGING="${PROJECT_NAME}-staging"
    export SSH_ALIAS="$SSH_ALIAS_PRODUCTION" SSH_ALIAS_LIST="\`${PROJECT_NAME}-production\`"
    if [ "$HAS_STAGING" = true ]; then
        SSH_ALIAS="$SSH_ALIAS_STAGING"
        SSH_ALIAS_LIST="\`$SSH_ALIAS_STAGING\` and \`$SSH_ALIAS_PRODUCTION\`"
    fi

    export HOST_LABEL="" TRANSPORT="" SSH_PORT="22" SECRET_NAMES="" DEPLOY_SUMMARY="" HAS_SSH=false
    export ROOT_EXCLUDE_FLAGS="" WP_CONTENT_EXCLUDE_FLAGS=""
    export WP_CONTENT_EXCLUDE_WPE="" ROOT_EXCLUDE_WPE="" BUILD_STEPS=""

    [ "$DEPLOY" = true ] || return 0

    local preset="$STARTER_ROOT/templates/deploy/hosts/${DEPLOY_HOST}.conf"
    [ -f "$preset" ] || die "Unknown host preset: $DEPLOY_HOST"
    local ROOT_EXCLUDES="" WP_CONTENT_EXCLUDES=""
    # shellcheck disable=SC1090
    . "$preset"
    # The SFTP deploy mirrors plugins/ and themes/ as separate jobs, with no exclude hook.
    if [ "$TRANSPORT" = sftp ] && [ -n "$WP_CONTENT_EXCLUDES" ]; then
        die "$preset sets WP_CONTENT_EXCLUDES, which the SFTP deploy can't apply."
    fi

    ROOT_EXCLUDE_FLAGS=$(rsync_flags "$ROOT_EXCLUDES")
    WP_CONTENT_EXCLUDE_FLAGS=$(rsync_flags "$WP_CONTENT_EXCLUDES")
    WP_CONTENT_EXCLUDE_WPE=$(prefixed_flags "" "$WP_CONTENT_EXCLUDES" "/wp-content/")
    ROOT_EXCLUDE_WPE=$(prefixed_flags "" "$ROOT_EXCLUDES" "/")

    case "$TRANSPORT" in
        rsync)
            DEPLOY_SUMMARY="rsync over SSH in three passes, with \`--delete\` scoped to \`wp-admin\`, \`wp-includes\`, and the \`plugins\` and \`themes\` folders of \`wp-content\`. The server keeps its own \`wp-config.php\`. Run the deploy workflow by hand with \`dry_run\` to rehearse."
            SECRET_NAMES="\`SSH_HOST\`, \`SSH_USER\`, \`SSH_PATH\`, \`SSH_PORT\`, \`SSH_PRIVATE_KEY\`. Optional: \`SSH_KNOWN_HOSTS\` to pin the host key."
            HAS_SSH=true
            ;;
        sftp)
            DEPLOY_SUMMARY="SFTP mirror of \`wp-content/plugins\` and \`wp-content/themes\` only. WordPress core on the server is not managed by Composer, so it updates separately, and composer.lock's core version may not match production."
            SECRET_NAMES="\`SFTP_HOST\`, \`SFTP_USER\`, \`SFTP_PASSWORD\`, \`SFTP_PATH\`."
            ;;
        wpe)
            DEPLOY_SUMMARY="WP Engine's official GitHub Action, using the SSH Gateway. Install names are in the \`deploy-*.yml\` callers."
            SECRET_NAMES="\`WPE_SSHG_KEY_PRIVATE\`."
            HAS_SSH=true
            ;;
        *) die "Unknown transport in $preset: $TRANSPORT" ;;
    esac
    [ "$HAS_AUTH" = true ] && SECRET_NAMES="$SECRET_NAMES Also \`COMPOSER_AUTH_JSON\` (the contents of auth.json)."
    # Callers pass secrets by their own name; GitHub resolves each from the job's environment.
    SECRET_NAMES="$SECRET_NAMES Set them on each GitHub environment (\`production\`$STAGING_ENV_NOTE), with the same names in each."

    BUILD_STEPS=$(perl "$STARTER_ROOT/lib/render.pl" build-steps.yml \
        < "$STARTER_ROOT/templates/deploy/partials/build-steps.yml")
    export TRANSPORT HOST_LABEL SSH_PORT
}

render_ci_and_deploy() {
    local policy="${1:-overwrite}"
    render_overlay "$STARTER_ROOT/templates/ci" . "$policy"
    if [ "$DEPLOY" = true ]; then
        render_overlay "$STARTER_ROOT/templates/deploy/$TRANSPORT" . "$policy"
    fi
}
