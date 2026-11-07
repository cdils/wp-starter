# Stages and resume. Answers and progress live in .wp-project-* files, which the
# generated .gitignore excludes. Neither file holds a secret.

STATE_FILE=".wp-project-state"
ANSWERS_FILE=".wp-project-answers"
REMEMBERED=" "

remember() {
    case "$REMEMBERED" in
        *" $1 "*) ;;
        *) REMEMBERED="$REMEMBERED$1 " ;;
    esac
}

save_answers() {
    local var
    remember NONINTERACTIVE
    remember AUTO_COMMIT
    remember AUTO_REMOVE
    export AUTO_COMMIT="${AUTO_COMMIT:-false}" AUTO_REMOVE="${AUTO_REMOVE:-false}"
    : > "$ANSWERS_FILE"
    for var in $REMEMBERED; do
        printf '%s=%q\n' "$var" "${!var}" >> "$ANSWERS_FILE"
    done
}

stage_done() { [ -f "$STATE_FILE" ] && grep -qx "$1" "$STATE_FILE"; }

on_stage_exit() {
    local status=$?
    [ "$status" -eq 0 ] && return 0
    printf "\n"
    warn "Stopped during: ${CURRENT_STAGE:-setup}"
    warn "Fix the problem, then run this from $PWD:"
    printf "  %s resume\n" "$STARTER_ROOT/wp-project.sh"
    if [ -n "${DUMP_DIR:-}" ] && [ -d "$DUMP_DIR" ]; then
        warn "A database copy is still in $DUMP_DIR. Resuming removes it at the end; if you give up, delete it."
    fi
}

# run_stage "Label" function
run_stage() {
    local label="$1" fn="$2"
    if stage_done "$fn"; then
        info "Already done: $label"
        return 0
    fi
    CURRENT_STAGE="$label"
    printf "\n${GREEN}==> %s${NC}\n" "$label"
    "$fn"
    echo "$fn" >> "$STATE_FILE"
    CURRENT_STAGE=""
}

run_resume() {
    [ -f "$ANSWERS_FILE" ] || die "Nothing to resume here: no $ANSWERS_FILE in $PWD."
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
    PROJECT_DIR="$PWD"
    export_answers
    # Before its questions, adopt must not derive: defaults would answer them.
    if [ "$MODE" != adopt ] || stage_done stage_adopt_questions; then
        derive_tokens
    fi
    trap on_stage_exit EXIT
    # Containers may have stopped since the run failed, and that stage won't repeat.
    if stage_done lando_start; then
        lando_start
    fi
    case "$MODE" in
        new) stages_new ;;
        adopt) stages_adopt ;;
        clone) stages_clone ;;
        *) die "Unknown mode in $ANSWERS_FILE: $MODE" ;;
    esac
}

export_answers() {
    local line var
    while IFS= read -r line; do
        var="${line%%=*}"
        remember "$var"
        export "${var?}"
    done < "$ANSWERS_FILE"
}

preflight() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed."
    done
    case " $* " in
        *" lando "*)
            docker info >/dev/null 2>&1 || die "Docker isn't running. Start it and try again."
            ;;
    esac
}
