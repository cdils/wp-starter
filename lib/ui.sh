# Output and prompts. Every prompt checks for a preset value first, so --config and
# resume can answer without a terminal.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

die() { printf "${RED}Error: %s${NC}\n" "$1" >&2; exit 1; }
warn() { printf "${YELLOW}%s${NC}\n" "$1"; }
info() { printf "%s\n" "$1"; }
ok() { printf "${GREEN}%s${NC}\n" "$1"; }

heading() {
    printf "\n${BLUE}==============================================\n"
    printf "  %s\n" "$1"
    printf "==============================================${NC}\n\n"
}

is_set() { eval "[ -n \"\${$1+x}\" ]"; }

# Fails cleanly when there's no input, such as an unattended run without --config.
read_line() {
    local __var="$1" __prompt="$2" __reply=""
    if ! read -r -p "$__prompt" __reply; then
        die "No input available. Run interactively, or pass --config."
    fi
    printf -v "$__var" '%s' "$__reply"
}

# ask VAR "Prompt" [default] [validator]
# With no default the answer is required. Pass "-" as the default for optional answers.
ask() {
    local var="$1" prompt="$2" default="${3-}" validator="${4-}" reply optional=false
    if [ "$default" = "-" ]; then
        optional=true
        default=""
    fi

    while true; do
        if is_set "$var"; then
            reply="${!var}"
        elif [ "$NONINTERACTIVE" = true ]; then
            reply="$default"
        elif [ -n "$default" ]; then
            read_line reply "$prompt [$default]: "
            reply="${reply:-$default}"
        else
            read_line reply "$prompt: "
        fi

        if [ -z "$reply" ] && [ "$optional" = false ]; then
            [ "$NONINTERACTIVE" = false ] || die "Missing answer for $var."
            warn "An answer is required."
            unset "$var"
            continue
        fi
        if [ -n "$validator" ] && [ -n "$reply" ] && ! "$validator" "$reply"; then
            [ "$NONINTERACTIVE" = false ] || die "Invalid value for $var: $reply"
            unset "$var"
            continue
        fi
        printf -v "$var" '%s' "$reply"
        export "${var?}"
        remember "$var"
        return 0
    done
}

# ask_yn VAR "Prompt" y|n: stores true or false
ask_yn() {
    local var="$1" prompt="$2" default="$3" reply hint="[y/N]"
    [ "$default" = "y" ] && hint="[Y/n]"

    if is_set "$var"; then
        reply="${!var}"
    elif [ "$NONINTERACTIVE" = true ]; then
        reply="$default"
    else
        read_line reply "$prompt $hint: "
        reply="${reply:-$default}"
    fi

    case "$reply" in
        y|Y|yes|true) reply=true ;;
        *) reply=false ;;
    esac
    printf -v "$var" '%s' "$reply"
    export "${var?}"
    remember "$var"
}

# ask_choice VAR "Prompt" value "Label" value "Label"...: the first pair is the default
ask_choice() {
    local var="$1" prompt="$2" default="$3" reply i
    shift 2
    local -a values=() labels=()
    while [ "$#" -gt 0 ]; do
        values+=("$1")
        labels+=("$2")
        shift 2
    done

    if is_set "$var"; then
        reply="${!var}"
    elif [ "$NONINTERACTIVE" = true ]; then
        reply="$default"
    else
        printf "%s\n" "$prompt"
        for i in "${!values[@]}"; do
            printf "  %d) %s\n" "$((i + 1))" "${labels[$i]}"
        done
        while true; do
            read_line reply "Choose [1]: "
            reply="${reply:-1}"
            if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#values[@]}" ]; then
                reply="${values[$((reply - 1))]}"
                break
            fi
            warn "Enter a number from the list."
        done
    fi

    for i in "${values[@]}"; do
        if [ "$i" = "$reply" ]; then
            printf -v "$var" '%s' "$reply"
            export "${var?}"
            remember "$var"
            return 0
        fi
    done
    die "Invalid value for $var: $reply"
}

# A confirm that never auto-accepts: outward-facing steps need an explicit preset.
confirm() {
    local reply
    if [ "$NONINTERACTIVE" = true ]; then
        return 1
    fi
    read_line reply "$1 [y/N]: "
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Typed paths: expands ~, and anchors relative paths to where the wizard started,
# since it changes into the project folder before using them.
abs_path() {
    case "$1" in
        ""|/*|*://*) printf '%s' "$1" ;;
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
        *) printf '%s' "${START_DIR:-$PWD}/$1" ;;
    esac
}

valid_slug() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && return 0
    warn "Use lowercase letters, numbers and hyphens."
    return 1
}

valid_url() {
    [[ "$1" =~ ^https?://[^[:space:]]+$ ]] && return 0
    warn "Use a full URL starting with http:// or https://."
    return 1
}

valid_php() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]] && return 0
    warn "Use major.minor, for example 8.4."
    return 1
}

valid_branch() {
    [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && return 0
    warn "Use a plain git branch name."
    return 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] && return 0
    warn "Use a port number, for example 22."
    return 1
}

# Local paths are checked as typed, so ~ and relative paths resolve the way abs_path will.
valid_backup() {
    local path
    path=$(abs_path "$1")
    { [ -d "$path" ] || [[ -f "$path" && "$path" == *.zip ]]; } && return 0
    warn "Not a folder or .zip: $1"
    return 1
}

valid_sql_file() {
    local path
    path=$(abs_path "$1")
    [[ -f "$path" && ( "$path" == *.sql || "$path" == *.sql.gz ) ]] && return 0
    warn "Not a .sql or .sql.gz file: $1"
    return 1
}
