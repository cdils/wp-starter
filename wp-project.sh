#!/bin/bash
#
# wp-project.sh: guided setup for Lando + Composer WordPress projects.
#
#   wp-project.sh new      Start a site from nothing
#   wp-project.sh adopt    Bring a live site (no repo yet) into local development
#   wp-project.sh clone    Set up local development for an existing repo
#   wp-project.sh resume   Continue a run that stopped (from the project folder)
#
# Options:
#   --config FILE   Read answers from FILE; anything missing uses its default
#   -h, --help      Show this help
#

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    LINK_DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
    SOURCE=$(readlink "$SOURCE")
    case "$SOURCE" in /*) ;; *) SOURCE="$LINK_DIR/$SOURCE" ;; esac
done
STARTER_ROOT=$(cd -P "$(dirname "$SOURCE")" && pwd)
export STARTER_ROOT

# shellcheck source=versions.env
. "$STARTER_ROOT/versions.env"
for lib in ui stages scaffold deploy pull mode_new mode_clone mode_adopt; do
    # shellcheck disable=SC1090
    . "$STARTER_ROOT/lib/$lib.sh"
done

show_help() {
    sed -n '3,13p' "$0" | sed -E 's/^# ?//'
}

MODE=""
CONFIG_FILE=""
NONINTERACTIVE=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        new|adopt|clone|resume) MODE="$1" ;;
        --config)
            [ "$#" -ge 2 ] || die "--config needs a file."
            CONFIG_FILE="$2"
            shift
            ;;
        -h|--help) show_help; exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
done

if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    NONINTERACTIVE=true
fi

if [ -z "$MODE" ]; then
    unset MODE
    heading "WordPress project setup"
    ask_choice MODE "What are you starting from?" \
        new "Nothing yet: build a new site" \
        adopt "A live site with no repo" \
        clone "An existing repo"
fi

case "$MODE" in
    new) run_new ;;
    adopt) run_adopt ;;
    clone) run_clone ;;
    resume) run_resume ;;
esac
