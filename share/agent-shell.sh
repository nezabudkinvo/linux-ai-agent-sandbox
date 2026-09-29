# safeai: sourced by the agent's ~/.bashrc (install.sh adds the line).
# An AI tool the agent does not have yet: say how to install it for the agent, once,
# without sudo. Other unknown commands go to the handler that was there before.
[ -n "${_safeai_shell:-}" ] && return 0  # sourced twice in one shell: keep the first chain
_safeai_shell=1
if declare -F command_not_found_handle >/dev/null; then
    eval "_safeai_cnf_before () $(declare -f command_not_found_handle | tail -n +2)"
fi
command_not_found_handle() {
    local how=""
    case "$1" in
        claude) how="curl -fsSL https://claude.ai/install.sh | bash" ;;
        codex) how="npm config set prefix ~/.local && npm install -g @openai/codex" ;;
        gemini) how="npm config set prefix ~/.local && npm install -g @google/gemini-cli" ;;
    esac
    if [ -n "$how" ]; then
        printf '%s is not installed for the agent. Install it here, once, no sudo:\n  %s\n' "$1" "$how" >&2
        case "$how" in npm*) command -v npm >/dev/null ||
            printf '(npm is missing: ask the owner to install Node.js and npm)\n' >&2 ;; esac
        return 127
    fi
    if declare -F _safeai_cnf_before >/dev/null; then
        _safeai_cnf_before "$@"
        return $?
    fi
    printf 'bash: %s: command not found\n' "$1" >&2
    return 127
}
