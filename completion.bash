# Bash completion for `stack/compose` (the context-selecting wrapper),
# plus the `dok` shorthand for it.
#
#   source stack/context/completion.bash
#
# Completes the wrapper's own `--cx`/`--ctx`/`--context` with the contexts
# the repo actually defines — the `<ctx>` of every `[docker-]compose.<ctx>.ya?ml`
# beside it — and delegates everything else to docker's own completion, so
# subcommands, flags and service names stay correct without being restated
# here.

# Where the wrapper sits in a project: what the bare `dok` word runs and
# what the `complete` registration at the bottom names.
_stacx_wrapper="stack/compose"

_compose_ctx_contexts() {
    local dir="$1" file base
    # `default` is the resolver's reserved spelling for the default stack.
    printf 'default\n'
    for file in "$dir"/compose.*.yml "$dir"/compose.*.yaml \
        "$dir"/docker-compose.*.yml "$dir"/docker-compose.*.yaml; do
        [ -e "$file" ] || continue
        base="${file##*/}"
        base="${base#docker-}"
        base="${base#compose.}"
        base="${base%.yml}"
        base="${base%.yaml}"
        # Skip the override/variant files: only a bare `<ctx>` names a
        # context (`compose.<ctx>.override.yml` does not).
        case "$base" in
        *.*) continue ;;
        esac
        printf '%s\n' "$base"
    done | sort -u
}

_compose_ctx() {
    local cur prev root wrapper i
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    # The wrapper lives in <root>/<dir>/ (`stack/` by convention), so
    # contexts sit one level up; for the bare `dok` word the root is the
    # working directory itself. `wrapper` is the same command relative to
    # the root, for the delegation below.
    case "${COMP_WORDS[0]}" in
    */*)
        root="$(cd "$(dirname "${COMP_WORDS[0]}")/.." 2>/dev/null && pwd)" || root="."
        wrapper="$(basename "$(dirname "${COMP_WORDS[0]}")")/compose"
        ;;
    *)
        root="$PWD"
        wrapper="$_stacx_wrapper"
        ;;
    esac

    case "$prev" in
    --cx | --ctx | --context)
        mapfile -t COMPREPLY < <(compgen -W "$(_compose_ctx_contexts "$root")" -- "$cur")
        return
        ;;
    esac

    case "$cur" in
    --cx=* | --ctx=* | --context=*)
        mapfile -t COMPREPLY < <(
            compgen -W "$(_compose_ctx_contexts "$root")" -- "${cur#*=}"
        )
        return
        ;;
    esac

    # Delegate: hand docker's cobra completion the command line with our own
    # flag removed, plus the word being completed. Its output is
    # "value<TAB>description" lines and a trailing ":directive" line.
    local args=() ctx="${COMPOSE_CONTEXT:-}" no_override="" skip=0
    for ((i = 1; i < COMP_CWORD; i++)); do
        if [ "$skip" = 1 ]; then
            skip=0
            continue
        fi
        case "${COMP_WORDS[i]}" in
        --cx | --ctx | --context)
            ctx="${COMP_WORDS[i + 1]}"
            skip=1
            ;;
        --cx=* | --ctx=* | --context=*)
            ctx="${COMP_WORDS[i]#*=}"
            ;;
        --no-override)
            no_override=1
            ;;
        --env | --export) ;;
        *)
            args+=("${COMP_WORDS[i]}")
            ;;
        esac
    done
    # The delegation runs in a subshell with the context's compose files
    # exported, so service names come from the stack being completed — not
    # from the default one. The subshell keeps that out of the user's env.
    mapfile -t COMPREPLY < <(
        (
            cd "$root" || exit
            [ -n "$ctx" ] && export COMPOSE_CONTEXT="$ctx"
            [ -n "$no_override" ] && export COMPOSE_CTX_OVERRIDES=""
            eval "$("$wrapper" --export 2> /dev/null)" 2> /dev/null
            docker __complete compose "${args[@]}" "$cur" 2> /dev/null
        ) |
            sed '/^:/d; s/\t.*//' |
            compgen -W "$(cat)" -- "$cur"
    )

    # The wrapper's own flags, merged in: they must not shadow docker's on
    # a shared prefix like `--no-`.
    case "$cur" in
    -*)
        mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(
            compgen -W "--cx --ctx --context --no-override --env --export" -- "$cur"
        )
        ;;
    esac
}

complete -F _compose_ctx "$_stacx_wrapper" "./$_stacx_wrapper" dok

# The repo's context-selecting wrapper when the working directory has one,
# plain `docker compose` anywhere else.
dok() {
    if [ -x "$_stacx_wrapper" ]; then
        "$_stacx_wrapper" "$@"
    else
        docker compose "$@"
    fi
}
