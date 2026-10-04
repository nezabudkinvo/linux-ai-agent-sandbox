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
# The owner's network settings (safeai settings: proxy), put here by safeai when it starts this shell: the
# proxy variables are in the environment of everything here; Claude also gets them as --settings, above the
# agent's own and the project's settings, so neither sends it around the proxy. A proxy of this machine that
# does not answer stops claude and codex: they would only wait. (The kernel lets the agent's web through
# that proxy only, whatever runs here; see safeai-web.)
_safeai_net() {  # _safeai_net NAME ARGS... - may NAME start now
    local name=$1 a hp
    shift
    if [ -n "${SAFEAI_CLAUDE_STOP:-}" ]; then
        printf 'safeai: agent %s is not started: %s\n' "$name" "$SAFEAI_CLAUDE_STOP" >&2
        return 1
    fi
    if [ "$name" = Claude ]; then
        for a in "$@"; do
            case "$a" in --settings|--settings=*)
                printf 'safeai: agent Claude is not started: --settings cannot be combined with the network settings safeai gives agent Claude\n' >&2
                return 1 ;;
            esac
        done
    fi
    for hp in ${SAFEAI_CLAUDE_PROXIES:-}; do
        # a free proxy port of this machine taken by this user (on any address) would send everything around it
        case "${hp%:*}" in 127.*|localhost|::1) local here=1 ;; *) local here= ;; esac
        if [ -n "$here" ] && awk -v p="$(printf '%04X' "${hp##*:}")" -v u="$(id -u)" 'FNR > 1 && $4 == "0A" && $8 == u &&
                substr($2, length($2) - 3) == p { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
            printf 'safeai: agent %s is not started: your proxy port %s is held by %s, not by your proxy app\n' \
                "$name" "$hp" "$(id -un)" >&2
            return 1
        fi
        timeout 2 bash -c 'h=${1%:*}; h=${h#[}; : <"/dev/tcp/${h%]}/${1##*:}"' _ "$hp" 2>/dev/null && continue
        printf 'safeai: agent %s is not started: your proxy %s does not answer (is your proxy app running?)\n' "$name" "$hp" >&2
        return 1
    done
}
claude() {
    _safeai_in_home claude && return 1
    if [ -z "${SAFEAI_CLAUDE_SETTINGS:-}${SAFEAI_CLAUDE_STOP:-}" ]; then
        command claude "$@"
        return
    fi
    _safeai_net Claude "$@" || return 1
    command claude "$@" --settings "$SAFEAI_CLAUDE_SETTINGS"
}
codex() {
    _safeai_in_home codex && return 1
    _safeai_net Codex "$@" || return 1
    command codex "$@"
}
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
