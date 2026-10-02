# safeai: sourced by the agent's ~/.bashrc (install.sh adds the line).
# An AI tool the agent does not have yet: say how to install it for the agent, once,
# without sudo. Other unknown commands go to the handler that was there before.
# `home` goes to the owner's home folder (cd alone goes to the agent's own).
# claude, codex, gemini: not in the owner's home folder itself (see _safeai_in_home).
[ -n "${_safeai_shell:-}" ] && return 0  # sourced twice in one shell: keep the first chain
_safeai_shell=1
_safeai_owner_home() {
    local o
    o=$(sed -n 's/^OWNER=//p' /etc/safeai.conf 2>/dev/null)
    [ -n "$o" ] && getent passwd "$o" | cut -d: -f6
}
home() {
    local h
    h=$(_safeai_owner_home) && [ -n "$h" ] || { echo "home: the owner is not in /etc/safeai.conf" >&2; return 1; }
    cd -- "$h"
}
# An AI tool takes the folder it starts in for its project and reads the project's .claude and .codex
# settings there. In the owner's home folder itself those are the owner's own, closed to the agent:
# Claude complains about them, Codex stops. A project folder is what was meant anyway.
_safeai_in_home() {
    [ "$PWD" = "$(_safeai_owner_home)" ] || return 1
    printf '%s: start it in a project folder (cd ~/Projects/...), not in the home folder itself:\n' "$1" >&2
    printf '  there it would take the owner'"'"'s own settings for the project'"'"'s\n' >&2
}
claude() { _safeai_in_home claude && return 1; command claude "$@"; }
codex() { _safeai_in_home codex && return 1; command codex "$@"; }
gemini() { _safeai_in_home gemini && return 1; command gemini "$@"; }
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
        case $- in  # safeai PROGRAM in your own terminal runs this without a shell to type in
            *i*) printf '%s is not installed for the agent. Install it here, once, no sudo:\n  %s\n' "$1" "$how" >&2 ;;
            *) printf '%s is not installed for the agent. Open its terminal (safeai) and install it there, once, no sudo:\n  %s\n' \
                "$1" "$how" >&2 ;;
        esac
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
