#!/bin/bash

#
# WordPress Plugin Composerizer
# Analyzes wp-content/plugins and wp-content/mu-plugins (directories and single-file
# plugins) and wp-content/themes, and adds them to composer (pinned to the installed
# version) or to the .gitignore whitelist. Child themes are always whitelisted.
# Composer changes are batched into as few `composer require` calls as possible.
#

set -e

# Parse arguments
AUTO_UPDATE=false
AUTO_REQUIRE=false
DRY_RUN=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --update|-u) AUTO_UPDATE=true ;;
        --auto-require|-a) AUTO_REQUIRE=true ;;
        --dry-run|-d) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: wp-composerize.sh [options]"
            echo ""
            echo "Options:"
            echo "  -a, --auto-require  Add all available packages to require without prompting"
            echo "  -d, --dry-run       Show what would be done without making changes"
            echo "  -u, --update        Run composer update after adding packages"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "=============================================="
echo "  WordPress Plugin Composerizer"
echo "=============================================="
echo -e "${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
    echo ""
fi

if [ "$AUTO_REQUIRE" = true ]; then
    echo -e "${YELLOW}AUTO-REQUIRE MODE - All available packages will be added to require${NC}"
    echo ""
fi

# Check if we're in a WordPress project root
if [ ! -f "composer.json" ]; then
    echo -e "${RED}Error: composer.json not found.${NC}"
    echo "Please run this script from the root of a composerized WordPress project."
    exit 1
fi

if [ ! -d "wp-content/plugins" ] && [ ! -d "wp-content/mu-plugins" ] && [ ! -d "wp-content/themes" ]; then
    echo -e "${RED}Error: none of wp-content/plugins, wp-content/mu-plugins or wp-content/themes found.${NC}"
    exit 1
fi

# Check for required tools
if ! command -v curl &> /dev/null; then
    echo -e "${RED}Error: curl is required but not installed.${NC}"
    exit 1
fi

if ! command -v composer &> /dev/null; then
    echo -e "${RED}Error: composer is required but not installed.${NC}"
    exit 1
fi

# php is used to parse composer.json (it ships with composer, so this is a safe dep).
if ! command -v php &> /dev/null; then
    echo -e "${RED}Error: php is required but not installed.${NC}"
    exit 1
fi

# Every `composer require` fails against an invalid composer.json, so catch it before scanning.
if ! validate_output=$(composer validate --no-check-publish --no-check-lock 2>&1); then
    echo -e "${RED}Error: composer.json is invalid.${NC}"
    echo "$validate_output"
    exit 1
fi

# Arrays to track results
declare -a WPACKAGIST_PLUGINS=()
declare -a CUSTOM_REPO_PLUGINS=()
declare -a PREMIUM_PLUGINS=()
declare -a SKIPPED_PLUGINS=()
declare -a COMPOSERIZED_DIRS=()   # original dirs/files safe to delete once composer installs them

# Pending composer requires, collected during the scan and applied in batches afterward.
declare -a PENDING_REF=()      # package reference, e.g. wpackagist-plugin/akismet:^5.3.1
declare -a PENDING_WLNAME=()   # .gitignore whitelist entry name (foo or foo.php)
declare -a PENDING_PREFIX=()   # .gitignore path prefix, e.g. /wp-content/plugins/
declare -a PENDING_DEV=()      # true = require-dev, false = require
declare -a PENDING_PATH=()     # original dir/file path (for cleanup instructions)
declare -a PENDING_KIND=()     # wpackagist | custom (for the summary grouping)
declare -a PENDING_BASE=()     # summary display base, e.g. "akismet^5.3.1"

# Store custom package mappings as parallel arrays (compatible with bash 3.x, macOS default)
CUSTOM_PACKAGE_SLUGS=()
CUSTOM_PACKAGE_NAMES=()

# Build map of available packages from custom repositories in composer.json
build_custom_package_map() {
    echo -e "${YELLOW}Analyzing composer.json repositories...${NC}"

    # Extract the URLs of every VCS repository from composer.json. Parsed with php
    # (guaranteed present alongside composer) rather than jq, which handles both the
    # object and array forms of "repositories" and a missing key without erroring.
    local vcs_repos
    vcs_repos=$(php -r '$j=json_decode(file_get_contents("composer.json"),true); if(!empty($j["repositories"])) foreach($j["repositories"] as $r){ if(isset($r["type"],$r["url"]) && $r["type"]==="vcs") echo $r["url"],"\n"; }' 2>/dev/null || true)

    while IFS= read -r url; do
        if [ -n "$url" ]; then
            # Extract org/repo from GitHub URL
            local repo_path
            repo_path=$(echo "$url" | sed -E 's|.*github\.com/||' | sed 's|\.git$||')
            local slug
            slug=$(basename "$repo_path")
            local package_name="$repo_path"

            if [ -n "$slug" ] && [ -n "$package_name" ]; then
                CUSTOM_PACKAGE_SLUGS+=("$slug")
                CUSTOM_PACKAGE_NAMES+=("$package_name")
                echo "  Found VCS package: ${slug} -> ${package_name}"
            fi
        fi
    done <<< "$vcs_repos"

    # Delicious Brains WP Migrate DB Pro lives in a custom composer repo where the
    # plugin slug differs from what we'd guess, so map it explicitly.
    if php -r '$j=json_decode(file_get_contents("composer.json"),true); $f=false; if(!empty($j["repositories"])) foreach($j["repositories"] as $r){ if(isset($r["url"]) && $r["url"]==="https://composer.deliciousbrains.com") $f=true; } exit($f?0:1);' 2>/dev/null; then
        CUSTOM_PACKAGE_SLUGS+=("wp-migrate-db-pro")
        CUSTOM_PACKAGE_NAMES+=("deliciousbrains-plugin/wp-migrate-db-pro")
        echo "  Found Delicious Brains repo: wp-migrate-db-pro -> deliciousbrains-plugin/wp-migrate-db-pro"
    fi

    echo ""
}

# Function to check if a plugin is available from a custom repository
get_custom_package() {
    local slug="$1"
    local i

    for i in "${!CUSTOM_PACKAGE_SLUGS[@]}"; do
        if [ "${CUSTOM_PACKAGE_SLUGS[$i]}" = "$slug" ]; then
            echo "${CUSTOM_PACKAGE_NAMES[$i]}"
            return 0
        fi
    done
    return 1
}

# Function to check if a plugin or theme is resolvable via WPackagist.
check_wpackagist() {
    local slug="$1"
    local type="$2"   # plugin | theme

    # WPackagist mirrors the WordPress.org plugin and theme directories, so presence on
    # WordPress.org means composer can resolve wpackagist-<type>/<slug>.
    # A single lightweight HTTP check avoids spawning composer once per entry.
    local url="https://api.wordpress.org/plugins/info/1.0/${slug}.json"
    if [ "$type" = "theme" ]; then
        url="https://api.wordpress.org/themes/info/1.2/?action=theme_information&request%5Bslug%5D=${slug}"
    fi

    local body
    body=$(curl -fsS -L --max-time 15 "$url" 2>/dev/null) || return 1
    # Non-existent entries can return an empty/null body (plugins) or an
    # {"error":...} body (themes) even on HTTP 200.
    case "$body" in
        ""|"null"|"false") return 1 ;;
    esac
    printf '%s' "$body" | grep -q "\"slug\""
}

# Read the installed version from a plugin's main file header or a theme's style.css
# (echoes the version). Accepts a plugin directory, a single-file plugin path, or a
# theme directory.
get_installed_version() {
    local path="$1"
    local type="$2"   # plugin | theme
    local main_file version

    if [ -f "$path" ]; then
        main_file="$path"
    elif [ "$type" = "theme" ]; then
        main_file="$path/style.css"
        [ -f "$main_file" ] || return 1
    else
        # The main plugin file is the top-level .php carrying a "Plugin Name:" header.
        main_file=$(grep -ilE "Plugin Name:" "$path"/*.php 2>/dev/null | head -n1)
    fi
    [ -z "$main_file" ] && return 1

    version=$(grep -iE "^[[:space:]]*\*?[[:space:]]*Version:" "$main_file" 2>/dev/null | head -n1 \
        | sed -E 's/.*[Vv]ersion:[[:space:]]*//' | tr -d '\r' | awk '{print $1}')
    [ -z "$version" ] && return 1
    echo "$version"
}

# A child theme declares its parent with a "Template:" header in style.css.
is_child_theme() {
    grep -qiE "^[[:space:]]*\*?[[:space:]]*Template:[[:space:]]*[^[:space:]]" "$1/style.css" 2>/dev/null
}

# Turn an installed version into a caret constraint suffix (":^x.y.z").
# Returns "" for versions we can't safely pin (pre-release tags, empty, etc.).
version_constraint() {
    local version="$1"
    if [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo ":^${version}"
    else
        echo ""
    fi
}

# Function to check if a plugin or theme is already in composer.json (any package format)
is_in_composer() {
    local slug="$1"
    local type="$2"   # plugin | theme

    # Check for the WPackagist format matching this type, so a plugin and a theme
    # sharing a slug don't mask each other.
    if grep -q "\"wpackagist-${type}/${slug}\"" composer.json 2>/dev/null; then
        return 0
    fi

    # Check for any non-WPackagist package ending with the slug (e.g., "vendor/plugin-slug").
    # This catches VCS repos and custom composer repos.
    if grep -oE "\"[^\"]+/${slug}\"" composer.json 2>/dev/null | grep -qv '^"wpackagist-'; then
        return 0
    fi

    return 1
}

# Gitignore whitelist helpers, parameterized by whitelist entry name (foo or foo.php)
# and path prefix, so the same logic serves plugins, mu-plugins, themes, dirs and single
# files. Entries match whole lines (with or without a trailing slash) so "foo" never
# matches a sibling "foo-pro" entry.
is_in_gitignore_whitelist() {
    local name="$1"
    local prefix="$2"
    grep -qxF -e "!${prefix}${name}" -e "!${prefix}${name}/" .gitignore 2>/dev/null
}

remove_from_gitignore_whitelist() {
    local name="$1"
    local prefix="$2"
    grep -vxF -e "!${prefix}${name}" -e "!${prefix}${name}/" .gitignore > .gitignore.tmp || true
    mv .gitignore.tmp .gitignore
}

# Whitelist a premium/custom entry in .gitignore (or note that it already is).
whitelist_entry() {
    if is_in_gitignore_whitelist "$whitelist_name" "$whitelist_prefix"; then
        echo -e "  ${GREEN}✓${NC} Already whitelisted in .gitignore"
        SKIPPED_PLUGINS+=("$slug (already in gitignore)")
    elif [ "$DRY_RUN" = true ]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would add to .gitignore whitelist"
        PREMIUM_PLUGINS+=("$slug")
    else
        echo -e "  ${CYAN}→ Adding to .gitignore whitelist (premium/custom ${entry_type})${NC}"
        add_to_gitignore_whitelist "$whitelist_name" "$whitelist_prefix" "$marker"
        echo -e "  ${GREEN}✓${NC} Added to .gitignore whitelist"
        PREMIUM_PLUGINS+=("$slug")
    fi
}

add_to_gitignore_whitelist() {
    local name="$1"
    local prefix="$2"
    local marker="$3"
    if grep -q "$marker" .gitignore; then
        sed -i.bak "/${marker}/a\\
!${prefix}${name}" .gitignore
        rm -f .gitignore.bak
    else
        echo "!${prefix}${name}" >> .gitignore
    fi
}

# Function to prompt for require vs require-dev
prompt_require_type() {
    local slug="$1"
    local choice

    echo "" >&2
    read -p "  Add ${slug} to [r]equire, require-[d]ev, or [s]kip? [r/d/s]: " choice

    case "$choice" in
        d|D) echo "dev" ;;
        s|S) echo "skip" ;;
        *) echo "prod" ;;
    esac
}

# Queue a plugin for a batched composer require.
queue_require() {
    PENDING_REF+=("$1")
    PENDING_WLNAME+=("$2")
    PENDING_PREFIX+=("$3")
    PENDING_DEV+=("$4")
    PENDING_PATH+=("$5")
    PENDING_KIND+=("$6")
    PENDING_BASE+=("$7")
}

# Apply one group (require or require-dev) of queued packages in a single composer
# call. If the batch fails, fall back to requiring each package individually so one
# bad package can't drop the whole group. Sets SUCCEEDED[$i]=1 for each applied index.
apply_group() {
    local dev="$1"; shift
    local -a idx=("$@")
    [ ${#idx[@]} -eq 0 ] && return 0

    local label="require"
    [ "$dev" = "true" ] && label="require-dev"

    local -a refs=()
    local i
    for i in "${idx[@]}"; do refs+=("${PENDING_REF[$i]}"); done

    local -a args=()
    [ "$dev" = "true" ] && args+=("--dev")
    args+=("${refs[@]}" "--no-update")

    echo -n "  Adding ${#refs[@]} package(s) to ${label}... "
    if composer require "${args[@]}" > /dev/null 2>&1; then
        echo -e "${GREEN}Done${NC}"
        for i in "${idx[@]}"; do SUCCEEDED[$i]=1; done
    else
        echo -e "${YELLOW}batch failed — retrying individually${NC}"
        for i in "${idx[@]}"; do
            local -a one=()
            [ "$dev" = "true" ] && one+=("--dev")
            one+=("${PENDING_REF[$i]}" "--no-update")
            echo -n "    ${PENDING_BASE[$i]}... "
            local err
            if err=$(composer require "${one[@]}" 2>&1); then
                echo -e "${GREEN}Done${NC}"
                SUCCEEDED[$i]=1
            else
                echo -e "${RED}Failed${NC}"
                echo -e "      ${RED}${err}${NC}"
                SUCCEEDED[$i]=0
            fi
        done
    fi
}

# Build the custom package map from composer.json
build_custom_package_map

echo -e "${YELLOW}Scanning wp-content/plugins, wp-content/mu-plugins and wp-content/themes...${NC}"
echo ""

# Collect plugin directories AND single-file plugins from both plugin roots, plus
# theme directories (themes are always directories).
declare -a ALL_ENTRIES=()
for root in "wp-content/plugins" "wp-content/mu-plugins" "wp-content/themes"; do
    [ -d "$root" ] || continue
    while IFS= read -r e; do
        [ -n "$e" ] && ALL_ENTRIES+=("$e")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    [ "$root" = "wp-content/themes" ] && continue
    while IFS= read -r e; do
        [ -n "$e" ] && ALL_ENTRIES+=("$e")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.php' 2>/dev/null | sort)
done

if [ ${#ALL_ENTRIES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No plugins or themes found.${NC}"
    exit 0
fi

total_plugins=${#ALL_ENTRIES[@]}
current=0

for entry in "${ALL_ENTRIES[@]}"; do
    current=$((current + 1))
    name=$(basename "$entry")

    # Skip index.php placeholders / silence-is-golden files.
    if [ "$name" = "index.php" ]; then
        continue
    fi

    # Single-file plugin (foo.php) vs plugin directory (foo/).
    if [ -f "$entry" ]; then
        slug="${name%.php}"
        whitelist_name="$name"        # keep the .php in the whitelist path
    else
        slug="$name"
        whitelist_name="$name"
    fi

    # Choose the entry type, .gitignore whitelist path prefix and section marker for this root.
    root_dir=$(dirname "$entry")
    whitelist_prefix="/${root_dir}/"
    case "$root_dir" in
        */mu-plugins) entry_type="plugin"; marker="# Non Composer MU Plugins" ;;
        */themes)
            entry_type="theme"; marker="# Non Composer Themes"
            # Projects from the old wp-starter.sh use the singular heading.
            grep -q "^$marker\$" .gitignore 2>/dev/null || marker="# Non Composer Theme"
            ;;
        *)            entry_type="plugin"; marker="# Non Composer Plugins" ;;
    esac

    echo -e "${BLUE}[${current}/${total_plugins}]${NC} Checking: ${slug} (${root_dir##*/})"

    # Skip only if already in composer.json
    if is_in_composer "$slug" "$entry_type"; then
        echo -e "  ${GREEN}✓${NC} Already in composer.json"
        SKIPPED_PLUGINS+=("$slug (already in composer)")
        echo ""
        continue
    fi

    # Child themes are site-specific, so never resolve them from a registry — a custom
    # child theme sharing a slug with a WordPress.org theme would be replaced by it.
    if [ "$entry_type" = "theme" ] && is_child_theme "$entry"; then
        echo -e "  ${CYAN}Child theme${NC} — treating as custom"
        whitelist_entry
        echo ""
        continue
    fi

    # Check if available from a custom repository
    custom_package=$(get_custom_package "$slug" 2>/dev/null || true)

    if [ -n "$custom_package" ]; then
        echo -e "  ${GREEN}Found in custom repo:${NC} ${custom_package}"

        if is_in_gitignore_whitelist "$whitelist_name" "$whitelist_prefix"; then
            echo -e "  ${YELLOW}Note:${NC} Currently whitelisted in .gitignore — will move to composer if added"
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would add to composer.json"
            if is_in_gitignore_whitelist "$whitelist_name" "$whitelist_prefix"; then
                echo -e "  ${CYAN}[DRY RUN]${NC} Would remove from .gitignore whitelist"
            fi
            CUSTOM_REPO_PLUGINS+=("$slug -> ${custom_package}")
        else
            if [ "$AUTO_REQUIRE" = true ]; then
                require_type="prod"
            else
                require_type=$(prompt_require_type "$slug")
            fi

            case "$require_type" in
                "prod")
                    queue_require "$custom_package" "$whitelist_name" "$whitelist_prefix" false "$entry" "custom" "$slug -> ${custom_package}"
                    echo -e "  ${CYAN}Queued for require${NC}"
                    ;;
                "dev")
                    queue_require "$custom_package" "$whitelist_name" "$whitelist_prefix" true "$entry" "custom" "$slug -> ${custom_package}"
                    echo -e "  ${CYAN}Queued for require-dev${NC}"
                    ;;
                "skip")
                    echo -e "  ${YELLOW}Skipped${NC}"
                    SKIPPED_PLUGINS+=("$slug (user skipped)")
                    ;;
            esac
        fi
    else
        # Check WPackagist availability
        echo -n "  Checking WPackagist... "
        if check_wpackagist "$slug" "$entry_type"; then
            echo -e "${GREEN}Found!${NC}"

            # Pin to the installed version so composer reproduces production, not "latest".
            installed_version=$(get_installed_version "$entry" "$entry_type" || true)
            constraint=$(version_constraint "$installed_version")
            pkg_ref="wpackagist-${entry_type}/${slug}${constraint}"
            if [ -n "$constraint" ]; then
                echo -e "  ${CYAN}Installed version:${NC} ${installed_version} → pinning ${constraint#:}"
            elif [ -n "$installed_version" ]; then
                echo -e "  ${YELLOW}Installed version ${installed_version} isn't cleanly pinnable — using latest${NC}"
            else
                echo -e "  ${YELLOW}Could not read installed version — using latest${NC}"
            fi

            if is_in_gitignore_whitelist "$whitelist_name" "$whitelist_prefix"; then
                echo -e "  ${YELLOW}Note:${NC} Currently whitelisted in .gitignore — will move to composer if added"
            fi

            if [ "$DRY_RUN" = true ]; then
                echo -e "  ${CYAN}[DRY RUN]${NC} Would add ${pkg_ref} to composer.json"
                if is_in_gitignore_whitelist "$whitelist_name" "$whitelist_prefix"; then
                    echo -e "  ${CYAN}[DRY RUN]${NC} Would remove from .gitignore whitelist"
                fi
                WPACKAGIST_PLUGINS+=("${slug}${constraint}")
            else
                if [ "$AUTO_REQUIRE" = true ]; then
                    require_type="prod"
                else
                    require_type=$(prompt_require_type "$slug")
                fi

                case "$require_type" in
                    "prod")
                        queue_require "$pkg_ref" "$whitelist_name" "$whitelist_prefix" false "$entry" "wpackagist" "${slug}${constraint}"
                        echo -e "  ${CYAN}Queued for require${NC}"
                        ;;
                    "dev")
                        queue_require "$pkg_ref" "$whitelist_name" "$whitelist_prefix" true "$entry" "wpackagist" "${slug}${constraint}"
                        echo -e "  ${CYAN}Queued for require-dev${NC}"
                        ;;
                    "skip")
                        echo -e "  ${YELLOW}Skipped${NC}"
                        SKIPPED_PLUGINS+=("$slug (user skipped)")
                        ;;
                esac
            fi
        else
            echo -e "${YELLOW}Not found${NC}"
            whitelist_entry
        fi
    fi

    echo ""
done

# Apply the queued composer requires in as few calls as possible (live runs only).
if [ "$DRY_RUN" = false ] && [ ${#PENDING_REF[@]} -gt 0 ]; then
    echo -e "${YELLOW}Applying composer changes...${NC}"

    declare -a SUCCEEDED=()
    declare -a prod_idx=()
    declare -a dev_idx=()
    for i in "${!PENDING_REF[@]}"; do
        SUCCEEDED[$i]=0
        if [ "${PENDING_DEV[$i]}" = "true" ]; then
            dev_idx+=("$i")
        else
            prod_idx+=("$i")
        fi
    done

    apply_group false "${prod_idx[@]}"
    apply_group true "${dev_idx[@]}"

    # Record results: gitignore removal, cleanup dirs, and summary grouping.
    for i in "${!PENDING_REF[@]}"; do
        [ "${SUCCEEDED[$i]}" = "1" ] || continue

        if is_in_gitignore_whitelist "${PENDING_WLNAME[$i]}" "${PENDING_PREFIX[$i]}"; then
            remove_from_gitignore_whitelist "${PENDING_WLNAME[$i]}" "${PENDING_PREFIX[$i]}"
            echo -e "  ${GREEN}✓${NC} ${PENDING_BASE[$i]}: removed from .gitignore whitelist"
        fi

        COMPOSERIZED_DIRS+=("${PENDING_PATH[$i]}")

        suffix="(require)"
        [ "${PENDING_DEV[$i]}" = "true" ] && suffix="(require-dev)"
        if [ "${PENDING_KIND[$i]}" = "wpackagist" ]; then
            WPACKAGIST_PLUGINS+=("${PENDING_BASE[$i]} ${suffix}")
        else
            CUSTOM_REPO_PLUGINS+=("${PENDING_BASE[$i]} ${suffix}")
        fi
    done

    echo ""
fi

# Calculate totals
TOTAL_COMPOSER_ADDED=$((${#WPACKAGIST_PLUGINS[@]} + ${#CUSTOM_REPO_PLUGINS[@]}))
TOTAL_CHANGES=$((TOTAL_COMPOSER_ADDED + ${#PREMIUM_PLUGINS[@]}))

# Summary
echo -e "${BLUE}=============================================="
echo "  Summary"
echo "=============================================="
echo -e "${NC}"

if [ "$TOTAL_CHANGES" -eq 0 ] && [ ${#SKIPPED_PLUGINS[@]} -gt 0 ]; then
    echo -e "${GREEN}No changes needed!${NC} All plugins and themes are already managed."
    echo ""
fi

if [ "$DRY_RUN" = true ]; then
    WOULD_PREFIX="Would add"
else
    WOULD_PREFIX="Added"
fi

if [ ${#WPACKAGIST_PLUGINS[@]} -gt 0 ]; then
    echo -e "${GREEN}${WOULD_PREFIX} to composer.json from WPackagist (${#WPACKAGIST_PLUGINS[@]}):${NC}"
    for plugin in "${WPACKAGIST_PLUGINS[@]}"; do
        echo "  - $plugin"
    done
    echo ""
fi

if [ ${#CUSTOM_REPO_PLUGINS[@]} -gt 0 ]; then
    echo -e "${GREEN}${WOULD_PREFIX} to composer.json from custom repositories (${#CUSTOM_REPO_PLUGINS[@]}):${NC}"
    for plugin in "${CUSTOM_REPO_PLUGINS[@]}"; do
        echo "  - $plugin"
    done
    echo ""
fi

if [ ${#PREMIUM_PLUGINS[@]} -gt 0 ]; then
    echo -e "${YELLOW}${WOULD_PREFIX} to .gitignore whitelist (${#PREMIUM_PLUGINS[@]}):${NC}"
    for plugin in "${PREMIUM_PLUGINS[@]}"; do
        echo "  - $plugin"
    done
    echo ""
fi

if [ ${#SKIPPED_PLUGINS[@]} -gt 0 ]; then
    echo -e "${CYAN}Skipped - already managed (${#SKIPPED_PLUGINS[@]}):${NC}"
    for plugin in "${SKIPPED_PLUGINS[@]}"; do
        echo "  - $plugin"
    done
    echo ""
fi

# Show what files were/would be modified
if [ "$TOTAL_CHANGES" -gt 0 ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}=============================================="
        echo "  Files That Would Be Modified"
        echo "=============================================="
        echo -e "${NC}"

        if [ "$TOTAL_COMPOSER_ADDED" -gt 0 ]; then
            echo -e "  ${CYAN}○${NC} composer.json (${TOTAL_COMPOSER_ADDED} packages)"
        fi

        if [ ${#PREMIUM_PLUGINS[@]} -gt 0 ]; then
            echo -e "  ${CYAN}○${NC} .gitignore (${#PREMIUM_PLUGINS[@]} entries)"
        fi

        echo ""
        echo -e "${YELLOW}To apply these changes, run without --dry-run:${NC}"
        echo -e "  ${CYAN}wp-composerize.sh${NC}"
        echo ""
    else
        echo -e "${BLUE}=============================================="
        echo "  Files Modified"
        echo "=============================================="
        echo -e "${NC}"

        if [ "$TOTAL_COMPOSER_ADDED" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} composer.json (${TOTAL_COMPOSER_ADDED} packages added)"
        fi

        if [ ${#PREMIUM_PLUGINS[@]} -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} .gitignore (${#PREMIUM_PLUGINS[@]} entries whitelisted)"
        fi

        echo ""
    fi
fi

# Run composer update or show next steps (skip in dry run)
if [ "$DRY_RUN" = false ] && [ "$TOTAL_COMPOSER_ADDED" -gt 0 ]; then
    if [ "$AUTO_UPDATE" = true ]; then
        echo -e "${YELLOW}Running composer update...${NC}"
        echo ""
        composer update
        echo ""
        echo -e "${GREEN}Composer packages installed!${NC}"
        echo ""
        echo -e "${YELLOW}Next steps:${NC}"
        echo "1. Delete the original plugin/theme directories (now managed by Composer):"
        for dir in "${COMPOSERIZED_DIRS[@]}"; do
            echo "   rm -rf ${dir}"
        done
        echo ""
    else
        echo -e "${YELLOW}=============================================="
        echo "  Next Steps"
        echo "=============================================="
        echo -e "${NC}"
        echo "Packages have been added to composer.json but NOT installed yet."
        echo ""
        echo "To install the packages, run:"
        echo -e "  ${CYAN}composer update${NC}"
        echo ""
        echo "Or re-run this script with the --update flag:"
        echo -e "  ${CYAN}wp-composerize.sh --update${NC}"
        echo ""
        echo "After installing, delete the original plugin/theme directories:"
        for dir in "${COMPOSERIZED_DIRS[@]}"; do
            echo "   rm -rf ${dir}"
        done
        echo ""
    fi
fi

if [ "$DRY_RUN" = false ] && [ ${#PREMIUM_PLUGINS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Premium/custom plugins and themes:${NC}"
    echo "These are now whitelisted in .gitignore and will be version controlled."
    echo "Commit them to your repository."
    echo ""
fi

echo -e "${GREEN}Done!${NC}"
