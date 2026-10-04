#!/bin/bash
# safeai installer.
#
#   ./install.sh                ask a few questions, show the plan; on your yes it
#                               asks for sudo and installs exactly that plan
#   ./install.sh --plan         only show what would be changed
#   sudo SAFEAI_MODE=strict ./install.sh --yes
#                               no questions: the defaults, and how it starts (strict
#                               or relaxed: there is no default for that one);
#                               SAFEAI_ADOPT_USER=1 uses an agent user that exists already
#   sudo ./install.sh --update  update an installed safeai with the answers given
#                               last time (`safeai settings update` runs this)
#   (sudo ./install.sh asks the same questions, already as root)
#
# Messages are English; SAFEAI_LANG=ru (or answering "ru" to the first question)
# loads the translation from share/i18n/ru.
#
# Everything it creates or changes is recorded in /var/lib/safeai/manifest;
# files it modifies are backed up first. uninstall.sh reverts exactly that list.
# If a step fails, the installer reverts what it already did.
set -Eeuo pipefail  # -E: a failure inside a function reverts the install too

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB=/usr/local/lib/safeai
STATE=/var/lib/safeai
MANIFEST=$STATE/manifest
MODE_ARG=${1:-}
STARTED=no
NEW_USER=no
case "$MODE_ARG" in ""|--plan|--yes|--update|--apply) ;; *) sed -n '2,20s/^# \{0,1\}//p' "$0"; exit 1 ;; esac
[ "$(uname -s)" = Linux ] || { echo "Linux only" >&2; exit 1; }
EARLY=""  # a reason to stop, said once the messages are loaded (below)
if [ "$(id -u)" = 0 ]; then
    OWNER=${SUDO_USER:-}
    [ -n "$OWNER" ] && [ "$OWNER" != root ] || EARLY=err_own
else
    OWNER=$(id -un)
    case "$MODE_ARG" in --yes|--update|--apply) EARLY=err_sudo ;; esac
fi
# --apply: the answers you gave before sudo, as KEY=VALUE arguments (checked below)
declare -A GIVEN=()
if [ "$MODE_ARG" = --apply ]; then
    for kv in "${@:2}"; do
        case "$kv" in AGENT=*|MODE=*|APPARMOR=*|AUDIT=*|VSCODE=*|NAUTILUS=*|LANG=*|ADOPT=*) GIVEN[${kv%%=*}]=${kv#*=} ;;
            *) echo "bad argument: $kv" >&2; exit 1 ;; esac
    done
    for k in APPARMOR AUDIT VSCODE NAUTILUS ADOPT; do
        case "${GIVEN[$k]:-}" in yes|no) ;; *) echo "bad $k" >&2; exit 1 ;; esac
    done
    case "${GIVEN[MODE]:-}" in strict|relaxed|keep) ;; *) echo "bad MODE" >&2; exit 1 ;; esac
    case "${GIVEN[LANG]:-}" in en|ru) ;; *) echo "bad LANG" >&2; exit 1 ;; esac
fi
saved() { sed -n "s/^$1=//p" /etc/safeai.conf 2>/dev/null | tail -1 || true; }  # answers from the last install
if [ "$MODE_ARG" = --update ] && [ ! -f "$MANIFEST" ] && [ -z "$EARLY" ]; then EARLY=err_notinstalled; fi

# ---- messages (printf templates); share/i18n/ru replaces them ------------------------------
declare -A MSG=(
    [error]="error: %s"
    [error_line]="error on line %s"
    [reverting]="reverting what was already done"
    [interrupted]="interrupted"
    [sudo_why]="Installing needs root for the changes above; sudo asks for your password now."
    [err_own]="run it from your own account: ./install.sh"
    [err_other_owner]="safeai is installed for %s: it protects one person's files per computer. To install it for yourself, %s removes it first (sudo /usr/local/lib/safeai/uninstall.sh)"
    [plan_others]="Other people have accounts here (%s): safeai keeps the agent out of your files only; theirs it sees as any user does, and they cannot have their own agent with this install."
    [err_sudo]="this needs sudo: sudo ./install.sh %s"
    [err_notinstalled]="safeai is not installed; run: sudo ./install.sh"
    [err_incomplete]="this copy of safeai is incomplete (%s is missing); download it again"
    [applying]="Setting the agent's access on your folders; with many files this takes a minute or two."
    [update_failed]="update failed; the version installed before is back. Try again: safeai settings update"
    [err_home]="home folder of %s not found"
    [err_systemd]="systemd is required"
    [err_python]="python 3.8 or newer is required"
    [err_pkg]="install %s with your package manager and re-run"
    [q_agent]="Name of the agent's Linux user"
    [err_name]="bad user name: %s"
    [err_same]="the agent must be a separate user"
    [err_exists]="user %s already exists and was not created by safeai; choose another name, or use it: SAFEAI_ADOPT_USER=1"
    [q_adopt]="User %s already exists (made before safeai). Use it as the agent? Its home, logins and files stay, and safeai never deletes it"
    [err_adopt]="user %s cannot be the agent: %s"
    [why_uid]="it is a system or administrator account"
    [why_sudo]="it may use sudo"
    [why_home]="its home is inside yours"
    [q_mode_intro]="How should it start in your home? You choose, there is no default:
  strict   the agent sees nothing in your home; you open the folders it should work in
  relaxed  your folders are open to it; settings, programs, secrets and .env files are protected,
           and you close what you want to keep from it"
    [q_mode]="Type strict or relaxed: "
    [err_mode]="answer strict or relaxed"
    [err_mode_needed]="choose how it starts: SAFEAI_MODE=strict or SAFEAI_MODE=relaxed (there is no default)"
    [plan_adopt]="  user %s exists already: it becomes the agent as it is (its home and logins stay; no password login)"
    [q_apparmor]="AppArmor: refuse .env-like files to every agent process at open time"
    [q_audit]="Audit log of refused actions (safeai log; installs auditd, changes its log group)"
    [q_vscode]="VS Code: chats through safeai, as the agent, with a status bar switch for chats as you"
    [q_nautilus]="Files (Nautilus): right-click menu and emblems"
    [plan]="Plan"
    [plan_head]="Owner: %s    agent user: %s    start: %s\n\nWith sudo, as root:"
    [mode_keep]="as before"
    [plan_core]="  user %s (no password, no groups of yours, no sudo)
  /etc/sudoers.d/safeai          %s may run programs as %s; nothing the other way
  /etc/safeai.conf, /usr/local/bin/safeai (with Tab completion), %s/
  services safeai-guard (root), safeai-check.timer (as %s, every 5 minutes),
  safeai-ask.socket (the agent may ask you for access; the question shows on your screen),
  safeai-web (root, network rules only: when you set a proxy, the agent's web traffic
  goes only through it; nftables table inet safeai)"
    [plan_lists]="  your lists in %s (secret stores like ~/.ssh closed in both modes)"
    [plan_apparmor]="  AppArmor profile /etc/apparmor.d/safeai-agent (and its rules from your lists in
  /etc/apparmor.d/local/safeai-keep, by the service safeai-keep); login shell of %s -> %s/safeai-shell;
  %s added to /etc/cron.deny and /etc/at.deny (backed up)"
    [plan_audit]="  audit rules /etc/audit/rules.d/50-safeai.rules;
  /etc/audit/auditd.conf: log_group -> %s (backed up)"
    [plan_packages]="  packages from %s: %s (and what they depend on)"
    [plan_you]="As you (no root):
  ACL entries for %s on your files (only that user's entries; removed on uninstall)"
    [plan_agent]="As %s: safeai's notes for it (~/.claude/safeai.md, imported by its CLAUDE.md; a part of
  ~/.codex/AGENTS.md - its own instructions stay), a Claude Code hook that
  explains refusals to it; its Claude takes the proxy from your Claude settings at every start;
  git trust for your
  repositories and your git name and e-mail for its commits"
    [plan_vscode]="  VS Code settings.json: two settings (their old values kept in settings.json.safeai-keys)"
    [plan_nautilus]="  ~/.local/share/nautilus-python/extensions/safeai_nautilus.py, its emblems in
  ~/.local/share/icons/hicolor/scalable/emblems;
  Files restarts to load it (its open windows close)"
    [plan_untouched]="Does not change: your network settings (only the agent's web, when you set a proxy), other users, your groups or login, other services."
    [plan_undo]="All of it can be undone at any time: sudo %s/uninstall.sh puts everything back as it was."
    [agent_mark]="[safeai: agent chat, limited access]"
    [plan_brief]="Agent user %s: no password, no sudo, none of your groups.
Your files: %s; ACL entries, a guard service and a check every 5 minutes keep it so."
    [mode_strict]="closed to the agent until you open them"
    [mode_relaxed]="your folders open to the agent; settings, programs and secrets protected"
    [plan_also]="Also:%s."
    [x_apparmor]="AppArmor"
    [x_audit]="a log of refusals"
    [x_vscode]="VS Code chats as the agent"
    [x_files]="a menu and emblems in Files"
    [x_packages]="packages %s"
    [proceed]="Proceed? [Y/n, d: every change]: "
    [nothing]="Nothing changed."
    [s_core]="Core"
    [s_apparmor]="AppArmor"
    [s_audit]="Audit log"
    [s_vscode]="VS Code"
    [s_nautilus]="Files (Nautilus)"
    [s_done]="Done"
    [err_acl]="your home folder's filesystem has no ACL support"
    [err_groups]="%s is in other groups"
    [err_writable]="%s is writable by %s; run the installer from a folder it cannot write to"
    [err_sudoers]="sudoers check failed"
    [err_auditgroup]="group %s has other members who would read the audit log; re-run and answer n for it"
    [err_audit]="safeai's audit rules did not load (auditctl -l does not show them); re-run and answer n for the audit log"
    [restart_files]="Files restarted to load the extension"
    [keep_failed]="What you closed or made read-only is not kept from deletion by the agent (%s).
Look at: journalctl -u 'safeai-keep@*'; then: safeai check --fix"
    [web_failed]="The rule for the agent's web is not in place (%s): the agent does not start until it is.
Look at: journalctl -u safeai-web.service; then: safeai check --fix"
    [done]="Start the agent in a project folder: safeai claude (or safeai for its terminal).
Access: safeai open | read | close PATH. State: safeai status. Settings: safeai settings.
Help: safeai --help. Full self-test (temporarily creates test files; about a minute): %s/check.sh.
Remove: sudo %s/uninstall.sh"
)
m() {  # m KEY [ARGS...] - the message, formatted
    local key=$1; shift
    # shellcheck disable=SC2059
    printf "${MSG[$key]}" "$@"
}
tty_ok() { (: </dev/tty) 2>/dev/null; }  # a terminal to ask in (not when piped or in CI)
LANG_CHOICE=${GIVEN[LANG]:-${SAFEAI_LANG:-$(saved LANG)}}
if [ -z "$LANG_CHOICE" ] && { [ "$MODE_ARG" = "" ] || [ "$MODE_ARG" = --plan ]; } && tty_ok; then
    while :; do
        read -r -p "Language (en/ru) [en]: " LANG_CHOICE </dev/tty || { LANG_CHOICE=en; break; }
        case "${LANG_CHOICE:-en}" in en|ru) break ;; *) echo "Answer en or ru." >/dev/tty ;; esac
    done
fi
case "${LANG_CHOICE:-en}" in en|ru) ;; *) echo "bad language: $LANG_CHOICE (use en or ru)" >&2; exit 1 ;; esac
# shellcheck source=share/i18n/ru
[ "${LANG_CHOICE:-en}" = ru ] && . "$SRC/share/i18n/ru"
[ -z "$EARLY" ] || { m "$EARLY" "$MODE_ARG" >&2; echo >&2; exit 1; }
# every file this installs: a copy with one missing would stop half way
for f in bin/safeai libexec/safeai-guard libexec/safeai-web libexec/safeai-keep libexec/safeai-run libexec/safeai-codex libexec/safeai-shell \
         libexec/safeai-acl-clean libexec/safeai-explain libexec/safeai-owner-mark uninstall.sh tests/check.sh VERSION \
         share/i18n/ru share/agent-shell.sh share/agent-about.md share/allowed_signers share/bash-completion/safeai \
         share/apparmor/safeai-agent.in share/nautilus/safeai_nautilus.py share/nautilus/emblems/safeai-closed.svg \
         share/nautilus/emblems/safeai-readonly.svg share/nautilus/emblems/safeai-partly.svg \
         share/nautilus/emblems/safeai-open-closed.svg share/nautilus/emblems/safeai-read-closed.svg \
         share/vscode/package.json share/vscode/extension.js; do
    [ -f "$SRC/$f" ] || { m err_incomplete "$f" >&2; echo >&2; exit 1; }
done

UPD=$STATE/before-update
rollback() {
    [ "${ROLLED:-}" = yes ] && return  # once, also when Ctrl+C and the failure it causes both get here
    ROLLED=yes
    trap - ERR
    trap '' INT TERM  # putting back is not interrupted
    set +e  # put back as much as possible
    if [ "$MODE_ARG" = --update ]; then  # the installation as it was before, with your settings
        local f u
        # what this update added goes again (units first), what it replaced comes back
        comm -13 <(sort "$UPD/manifest") <(sort "$MANIFEST") | sed -n 's/^created-file //p' | while read -r f; do
            case "$f" in /etc/systemd/system/*.socket|/etc/systemd/system/*.timer|/etc/systemd/system/*.service)
                u=$(basename "$f"); case "$u" in *@.service) ;; *) systemctl disable --now "$u" >/dev/null 2>&1 ;; esac ;;
            esac
            rm -f "$f"
        done
        systemctl stop 'safeai-keep@*.service' 'safeai-web@*.service' >/dev/null 2>&1  # none left writing
        if ! grep -q "^created-file /etc/systemd/system/safeai-keep.socket" "$UPD/manifest"; then
            rm -f /run/safeai-keep /run/safeai-keep.lock
        fi
        if grep -q "^nft-table " "$MANIFEST" && ! grep -q "^nft-table " "$UPD/manifest"; then
            systemctl stop 'safeai-web@*.service' >/dev/null 2>&1
            nft delete table inet safeai >/dev/null 2>&1
            rm -f /run/safeai-web /run/safeai-web.lock
        fi
        comm -13 <(sort "$UPD/manifest") <(sort "$MANIFEST") | sed -n 's/^created-dir //p' | sort -r |
            while read -r f; do rmdir "$f" 2>/dev/null; done
        cp "$UPD/manifest" "$MANIFEST"
        find "$LIB" -mindepth 1 -delete 2>/dev/null
        tar -C / -xpf "$UPD/files.tar"
        systemctl daemon-reload
        systemctl restart safeai-guard.service >/dev/null 2>&1
        [ -e /etc/apparmor.d/safeai-agent ] && apparmor_parser -r /etc/apparmor.d/safeai-agent >/dev/null 2>&1
        m update_failed >&2; echo >&2
        return
    fi
    m reverting >&2; echo >&2
    SAFEAI_ROLLBACK=1 SAFEAI_NEW_USER=$NEW_USER bash "$SRC/uninstall.sh" --yes >&2 || true
}
die() {
    m error "$*" >&2; echo >&2
    [ "$STARTED" = yes ] && rollback
    exit 1
}
say() {  # a step: bold on a terminal that shows it
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then printf '\n\033[1;36m▸ %s\033[0m\n' "$*"
    else printf '\n== %s\n' "$*"; fi
}
interactive() { { [ "$MODE_ARG" = "" ] || [ "$MODE_ARG" = --plan ]; } && tty_ok; }
ask() {  # ask VAR "question" default
    local ans=""
    if interactive; then
        read -r -p "$2 [$3]: " ans </dev/tty || true
    fi
    printf -v "$1" '%s' "${ans:-$3}"
}
yesno() {  # yesno VAR "question" y|n - the default is the capital letter: [Y/n] or [y/N]
    local v="" hint="[y/N]"
    [ "$3" = y ] && hint="[Y/n]"
    if interactive; then
        read -r -p "$2 $hint: " v </dev/tty || true
    fi
    case "${v:-$3}" in [yY]*) printf -v "$1" yes ;; *) printf -v "$1" no ;; esac
}

# ---- checks that change nothing ------------------------------------------------------
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
OWNER_GROUP=$(id -gn "$OWNER")
[ -d "$OWNER_HOME" ] || die "$(m err_home "$OWNER")"
[ -d /run/systemd/system ] || die "$(m err_systemd)"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null || die "$(m err_python)"
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf >/dev/null; then PKG=dnf
elif command -v pacman >/dev/null; then PKG=pacman
else PKG=none; fi
as_owner() { if [ "$(id -u)" = 0 ]; then sudo -u "$OWNER" -H "$@"; else "$@"; fi; }
# Your icon cache, when a program made one in ~/.local/share/icons/hicolor: GTK trusts it over the
# folder, so without a refresh the emblems are not found. A cache, not your data: made again.
icon_cache() {
    local h=$OWNER_HOME/.local/share/icons/hicolor u
    [ -f "$h/icon-theme.cache" ] || return 0
    u=$(command -v gtk-update-icon-cache || command -v gtk4-update-icon-cache || true)
    if [ -n "$u" ]; then as_owner "$u" -q -f -t "$h" || true; else as_owner touch "$h"; fi
}
files_restart() {  # nautilus -q in your session, if Files is running; it loads extensions only at start
    local u
    pgrep -u "$OWNER" -x nautilus >/dev/null || return 1
    u=$(id -u "$OWNER")
    as_owner env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$u/bus" XDG_RUNTIME_DIR="/run/user/$u" \
        nautilus -q >/dev/null 2>&1 || true
}

CONF=$OWNER_HOME/.config/safeai
FIRST=yes
[ -f "$CONF/write-dirs" ] && FIRST=no
cur_agent=$(sed -n 's/^AGENT=//p' /etc/safeai.conf 2>/dev/null || true)
# one person per computer: safeai keeps the agent out of its owner's files, and is installed once
cur_owner=$(sed -n 's/^OWNER=//p' /etc/safeai.conf 2>/dev/null || true)
[ -z "$cur_owner" ] || [ "$cur_owner" = "$OWNER" ] || die "$(m err_other_owner "$cur_owner" "$cur_owner")"
# other people with an account here: said in the plan (safeai protects only your files)
others=$(awk -F: -v min="$(awk '/^UID_MIN/ {print $2}' /etc/login.defs 2>/dev/null || echo 1000)" \
    -v me="$OWNER" -v ag="${cur_agent:-aiagent}" '$3 >= min && $3 < 60000 && $1 != me && $1 != ag \
    && $7 !~ /(nologin|false)$/ {printf "%s%s", sep, $1; sep=", "}' /etc/passwd)

# ---- questions (none on --apply: they were answered before sudo) -------------------------
if [ "$MODE_ARG" = --apply ]; then
    AGENT=${GIVEN[AGENT]:-} HOME_MODE=${GIVEN[MODE]} APPARMOR=${GIVEN[APPARMOR]} AUDIT=${GIVEN[AUDIT]}
    VSCODE=${GIVEN[VSCODE]} NAUTILUS=${GIVEN[NAUTILUS]}
else
ask AGENT "$(m q_agent)" "${cur_agent:-aiagent}"
fi
ours_agent() {  # created by safeai: the manifest says so (root), or the root-owned config does
    grep -qx "created-user $1" "$MANIFEST" 2>/dev/null || [ "$1" = "$cur_agent" ]
}
[[ "$AGENT" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "$(m err_name "$AGENT")"
[ "$AGENT" != "$OWNER" ] || die "$(m err_same)"
ADOPT=${GIVEN[ADOPT]:-no}
if getent passwd "$AGENT" >/dev/null && ! ours_agent "$AGENT"; then
    # a user made before safeai (by hand, or by another tool): it may become the agent, as it is
    if [ "$MODE_ARG" = --apply ]; then :  # answered before sudo
    elif [ "${SAFEAI_ADOPT_USER:-}" = 1 ]; then ADOPT=yes
    elif interactive; then yesno ADOPT "$(m q_adopt "$AGENT")" n
    fi
    [ $ADOPT = yes ] || die "$(m err_exists "$AGENT")"
fi
if [ $ADOPT = yes ]; then  # never an account that could do more than the agent may
    u=$(id -u "$AGENT")
    [ "$u" -ge "$(awk '/^UID_MIN/ {print $2}' /etc/login.defs 2>/dev/null || echo 1000)" ] && [ "$u" != "$(id -u "$OWNER")" ] ||
        die "$(m err_adopt "$AGENT" "$(m why_uid)")"
    if [ "$(id -u)" = 0 ] && sudo -l -U "$AGENT" 2>/dev/null | grep -q "may run the following"; then
        die "$(m err_adopt "$AGENT" "$(m why_sudo)")"
    fi
    case "$(getent passwd "$AGENT" | cut -d: -f6)/" in "$OWNER_HOME"/*) die "$(m err_adopt "$AGENT" "$(m why_home)")" ;; esac
fi
if [ "$MODE_ARG" != --apply ]; then
HOME_MODE=keep
if [ $FIRST = yes ]; then
    HOME_MODE=${SAFEAI_MODE:-}
    if [ -z "$HOME_MODE" ] && interactive; then
        echo; m q_mode_intro; echo
        while :; do
            read -r -p "$(m q_mode)" HOME_MODE </dev/tty || { HOME_MODE=""; break; }
            case "$HOME_MODE" in strict|relaxed) break ;; *) m err_mode; echo ;; esac
        done
    fi
    case "$HOME_MODE" in strict|relaxed) ;; *) die "$(m err_mode_needed)" ;; esac
fi
APPARMOR=no
if [ -d /sys/kernel/security/apparmor ] && command -v apparmor_parser >/dev/null; then
    yesno APPARMOR "$(m q_apparmor)" "$(a=$(saved APPARMOR); echo "${a:-y}")"
fi
yesno AUDIT "$(m q_audit)" "$(a=$(saved AUDIT); echo "${a:-y}")"
VSCODE=no
if [ -d "$OWNER_HOME/.config/Code" ] || [ -d "$OWNER_HOME/.vscode-server" ]; then
    yesno VSCODE "$(m q_vscode)" "$(a=$(saved VSCODE); echo "${a:-n}")"
fi
NAUTILUS=no
if command -v nautilus >/dev/null; then
    # offer it by default only when Files (Nautilus) is your default file manager
    fm=$(as_owner xdg-mime query default inode/directory 2>/dev/null || true)
    case "$fm" in *Nautilus*|*nautilus*) def=y ;; *) def=n ;; esac
    yesno NAUTILUS "$(m q_nautilus)" "$(a=$(saved NAUTILUS); echo "${a:-$def}")"
fi
fi
[ $FIRST = no ] && HOME_MODE=keep

# ---- the plan ---------------------------------------------------------------------------
# shown once: not to --apply (agreed before sudo) and not again in the shielded run below
if [ "$MODE_ARG" != --apply ] && [ -z "${SAFEAI_SHIELDED:-}" ]; then
# the packages that are missing, by the names this system uses
need=()
command -v setfacl >/dev/null || need+=(acl)
PATH=$PATH:/usr/sbin:/sbin command -v nft >/dev/null || need+=(nftables)  # the agent's web through your proxy
if [ $AUDIT = yes ] && ! command -v auditctl >/dev/null; then
    case $PKG in apt) need+=(auditd) ;; *) need+=(audit) ;; esac
fi
if [ $NAUTILUS = yes ] && ! python3 -c 'import gi; gi.require_version("Nautilus", "4.0")' 2>/dev/null; then
    case $PKG in apt) need+=(python3-nautilus) ;; dnf) need+=(nautilus-python) ;; *) need+=(python-nautilus) ;; esac
fi
full_plan() {  # every change, file by file
    m plan_head "$OWNER" "$AGENT" "$([ "$HOME_MODE" = keep ] && m mode_keep || echo "$HOME_MODE")"; echo
    [ -n "$others" ] && { m plan_others "$others"; echo; }
    if [ $ADOPT = yes ]; then m plan_adopt "$AGENT"; echo; fi
    m plan_core "$AGENT" "$OWNER" "$AGENT" "$LIB" "$OWNER"; echo
    [ $APPARMOR = yes ] && { m plan_apparmor "$AGENT" "$LIB" "$AGENT"; echo; }
    [ $AUDIT = yes ] && { m plan_audit "$OWNER_GROUP"; echo; }
    [ ${#need[@]} -gt 0 ] && { m plan_packages "$PKG" "${need[*]}"; echo; }
    m plan_you "$AGENT"; echo
    [ $FIRST = yes ] && { m plan_lists "$CONF"; echo; }
    [ $VSCODE = yes ] && { m plan_vscode; echo; }
    [ $NAUTILUS = yes ] && { m plan_nautilus; echo; }
    m plan_agent "$AGENT"; echo
}
brief_plan() {  # what it means for you, in a few lines
    local also=()
    if [ $ADOPT = yes ]; then m plan_adopt "$AGENT"; echo; fi
    m plan_brief "$AGENT" "$(m "mode_$HOME_MODE")"; echo
    [ -n "$others" ] && { m plan_others "$others"; echo; }
    [ $APPARMOR = yes ] && also+=("$(m x_apparmor)")
    [ $AUDIT = yes ] && also+=("$(m x_audit)")
    [ $VSCODE = yes ] && also+=("$(m x_vscode)")
    [ $NAUTILUS = yes ] && also+=("$(m x_files)")
    [ ${#need[@]} -gt 0 ] && also+=("$(m x_packages "${need[*]}")")
    if [ ${#also[@]} -gt 0 ]; then local IFS=,; m plan_also "${also[*]/#/ }"; echo; fi
}
say "$(m plan)"
if [ "$MODE_ARG" = --plan ]; then full_plan; else brief_plan; fi
m plan_untouched; echo
m plan_undo "$LIB"; echo
[ "$MODE_ARG" = --plan ] && exit 0
if [ "$MODE_ARG" = "" ]; then
    go=n  # no terminal to ask in: no
    while tty_ok; do
        go=""; read -r -p "$(m proceed)" go </dev/tty || go=n
        case "$go" in [dD]*) echo; full_plan; echo ;; *) break ;; esac
    done
    case "${go:-y}" in [yY]*) ;; *) m nothing; echo; exit 0 ;; esac
fi
fi
if [ "$(id -u)" != 0 ]; then  # the plan is agreed: now root, for exactly these answers
    echo; m sudo_why; echo
    exec sudo -- "$SRC/install.sh" --apply "AGENT=$AGENT" "MODE=$HOME_MODE" "APPARMOR=$APPARMOR" \
        "AUDIT=$AUDIT" "VSCODE=$VSCODE" "NAUTILUS=$NAUTILUS" "LANG=${LANG_CHOICE:-en}" "ADOPT=$ADOPT"
fi

# ---- from here root changes the system. Ctrl+C in the terminal must not kill a tool half way through
# (useradd, the package manager): the work goes on in a session of its own, which the terminal's Ctrl+C
# does not reach; this process passes it on, and the work finishes its current step, then reverts.
if [ -z "${SAFEAI_SHIELDED:-}" ]; then
    if [ "$MODE_ARG" = --update ]; then set -- --update
    else  # the answers given here, as for sudo above
        set -- --apply "AGENT=$AGENT" "MODE=$HOME_MODE" "APPARMOR=$APPARMOR" "AUDIT=$AUDIT" "VSCODE=$VSCODE" \
            "NAUTILUS=$NAUTILUS" "LANG=${LANG_CHOICE:-en}" "ADOPT=$ADOPT"
    fi
    SAFEAI_SHIELDED=1 setsid "$SRC/install.sh" "$@" &
    pid=$! rc=1
    trap 'kill -TERM "$pid" 2>/dev/null' INT TERM
    while kill -0 "$pid" 2>/dev/null; do wait "$pid"; rc=$?; done
    exit "$rc"
fi

# ---- manifest and rollback -----------------------------------------------------------------
# Crash safety (a power cut at any moment): every change is written to the manifest, on disk, before
# it is made, and every file is replaced whole (written next to it, synced, renamed over it). So
# running the installer again finishes the job, and uninstall.sh undoes what was begun.
mkdir -p "$STATE" && chmod 700 "$STATE"
touch "$MANIFEST" && sync "$MANIFEST"
if [ "$MODE_ARG" = --update ]; then  # what is installed now: an update that fails puts it back
    find "$UPD" -mindepth 1 -delete 2>/dev/null || true  # not there the first time
    mkdir -p "$UPD"
    cp "$MANIFEST" "$UPD/manifest"
    { printf '%s\0' "${LIB#/}"
      sed -n 's/^created-file \(.*\)/\1/p; s/^modified-file \([^ ]*\) .*/\1/p' "$MANIFEST" |
          while read -r f; do if [ -e "$f" ]; then printf '%s\0' "${f#/}"; fi; done  # (the last one may be gone)
    } | tar -C / --null -T - -cpf "$UPD/files.tar"
fi
STARTED=yes
# in the main shell only (a failing $(...) is the caller's to judge); after reverting, stop
# (set +e first: a message that cannot be written, the terminal gone, must not stop the reverting)
trap '[ "$BASHPID" = "$$" ] || exit 1; set +e; trap - ERR; m error_line "$LINENO" >&2; echo >&2; rollback; exit 1' ERR
# Ctrl+C (or being stopped) once root has started changing things: the same as a failed step
trap 'set +e; trap - ERR; echo >&2; m interrupted >&2; echo >&2; rollback; exit 130' INT TERM
note() { grep -qxF "$*" "$MANIFEST" || { echo "$*" >>"$MANIFEST" && sync "$MANIFEST"; }; }
whole() {  # whole DEST [MODE] - stdin becomes DEST at once: on a power cut, DEST is the old or the new one
    local t
    t=$(dirname "$1")/.$(basename "$1").safeai-new  # a dot file: sudo, systemd, AppArmor, audit skip it
    cat >"$t" && chmod "${2:-644}" "$t" && sync "$t" && mv -f "$t" "$1"
}
backup() {  # backup FILE - keep the original once, record it (not one safeai made itself)
    local f=$1 b
    [ -e "$f" ] || { note "created-file $f"; return 0; }
    grep -qxF "created-file $f" "$MANIFEST" && return 0
    grep -q "^modified-file $f " "$MANIFEST" && return 0
    b=$STATE/backup/${f//\//%}
    mkdir -p "$STATE/backup" && cp -a "$f" "$b" && sync "$b" && note "modified-file $f $b"
}
put() {  # put SRC DEST MODE - install a file safeai owns, whole (see whole)
    [ -e "$2" ] || note "created-file $2"
    whole "$2" "$3" <"$1" && chown root:root "$2"
}
pkg_list() {
    case $PKG in
        apt) dpkg-query -W -f='${Package}\n' ;;
        dnf) rpm -qa --qf '%{NAME}\n' ;;
        pacman) pacman -Qq ;;
    esac 2>/dev/null | sort -u
}
PKGS_BEFORE=$(pkg_list)
pkg_install() {
    local p
    # written down first: one a power cut leaves installed is still removed on uninstall
    for p in "$@"; do grep -qx "$p" <<<"$PKGS_BEFORE" || note "installed-package $p"; done
    case $PKG in
        apt) dpkg --configure -a >/dev/null 2>&1  # a package manager stopped half way before: finish it
             DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null 2>&1 ||
                 { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null; } ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        pacman) pgrep -x pacman >/dev/null || rm -f /var/lib/pacman/db.lck  # left by a pacman that was cut off
                pacman -S --needed --noconfirm "$@" >/dev/null ;;
        *) m err_pkg "$*" >&2; echo >&2; return 1 ;;
    esac || return 1
    # every package that came in, dependencies included: uninstall removes them again
    for p in $(comm -13 <(printf '%s\n' "$PKGS_BEFORE") <(pkg_list)); do note "installed-package $p"; done
}

# ---- core ---------------------------------------------------------------------------------
say "$(m s_core)"
command -v setfacl >/dev/null || pkg_install acl
probe=$OWNER_HOME/.safeai-acl-test  # one name: a run that was cut off leaves no other behind
rm -f "$probe" && as_owner touch "$probe"
if ! setfacl -m u:root:r-- "$probe" 2>/dev/null; then
    rm -f "$probe"
    die "$(m err_acl)"
fi
rm -f "$probe"

if ! getent passwd "$AGENT" >/dev/null; then
    # its group, left by a run of safeai cut off between creating the group and the user
    if getent group "$AGENT" >/dev/null && grep -qx "created-user $AGENT" "$MANIFEST"; then groupdel "$AGENT"; fi
    # written down first: a user that a power cut leaves behind is still safeai's, and so is its home.
    # NEW_USER before that: Ctrl+C from here on reverts the user (or what of it there is), and the record
    NEW_USER=yes
    note "created-user $AGENT"
    [ -e "/home/$AGENT" ] || note "agent-home /home/$AGENT"
    useradd -m -d "/home/$AGENT" -U -s /bin/bash "$AGENT"
    sync -f "/home/$AGENT"  # its shell files on disk now: a power cut must not leave them empty
elif [ $ADOPT = yes ]; then
    note "adopted-user $AGENT"  # uninstall leaves it, with its home
fi
usermod -p '*' "$AGENT"
AGENT_HOME=$(getent passwd "$AGENT" | cut -d: -f6)
chmod 750 "$AGENT_HOME"
if id -nG "$AGENT" | tr ' ' '\n' | grep -qvx "$AGENT"; then die "$(m err_groups "$AGENT")"; fi
# the login screen lists people, not the agent: AccountsService (GDM, LightDM, GNOME Settings) is told it
# is a system account. It has no password ('*' above), so it could not log in there anyway.
acc=/var/lib/AccountsService/users/$AGENT
if [ -d "$(dirname "$acc")" ]; then
    backup "$acc"
    { [ ! -f "$acc" ] || cat "$acc"; } | awk 'BEGIN { done = 0 }
        /^SystemAccount=/ { next }
        { print } /^\[User\]$/ && !done { print "SystemAccount=true"; done = 1 }
        END { if (!done) { print "[User]"; print "SystemAccount=true" } }' | whole "$acc" 600
    systemctl try-restart accounts-daemon.service >/dev/null 2>&1 || true  # it reads the file at start
fi
# the agent must not be able to change what root is about to run
if [ -n "$(runuser -u "$AGENT" -- find "$SRC" -writable -print -quit 2>/dev/null)" ]; then
    die "$(m err_writable "$SRC" "$AGENT")"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT  # also when a step below fails
printf '# safeai: %s may run programs as %s; there is no rule the other way round\n%s ALL=(%s) NOPASSWD: ALL\n' \
    "$OWNER" "$AGENT" "$OWNER" "$AGENT" >"$tmp"
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "$(m err_sudoers)"; }
put "$tmp" /etc/sudoers.d/safeai 440
yn() { [ "$1" = yes ] && echo y || echo n; }
repo=$(saved REPO)  # where `safeai settings update` downloads from (kept across updates)
printf 'OWNER=%s\nAGENT=%s\nLANG=%s\nAPPARMOR=%s\nAUDIT=%s\nVSCODE=%s\nNAUTILUS=%s\nREPO=%s\n' "$OWNER" "$AGENT" \
    "${LANG_CHOICE:-en}" "$(yn $APPARMOR)" "$(yn $AUDIT)" "$(yn $VSCODE)" "$(yn $NAUTILUS)" \
    "${repo:-https://github.com/nezabudkinvo/linux-ai-agent-sandbox}" >"$tmp"
put "$tmp" /etc/safeai.conf 644
rm -f "$tmp"
[ -d "$LIB" ] || note "created-dir $LIB"
install -d -m 755 "$LIB"
put "$SRC/bin/safeai" /usr/local/bin/safeai 755
for f in safeai-guard safeai-web safeai-keep safeai-run safeai-codex safeai-shell safeai-acl-clean safeai-explain safeai-owner-mark; do put "$SRC/libexec/$f" "$LIB/$f" 755; done
# so the checkout can be deleted: removal and the checks live next to the program
put "$SRC/uninstall.sh" "$LIB/uninstall.sh" 755
put "$SRC/share/i18n/ru" "$LIB/i18n-ru" 644  # uninstall.sh speaks the language chosen here
put "$SRC/share/agent-shell.sh" "$LIB/agent-shell.sh" 644  # the agent's shell: how to install AI tools
put "$SRC/tests/check.sh" "$LIB/check.sh" 755
put "$SRC/VERSION" "$LIB/VERSION" 644
put "$SRC/share/allowed_signers" "$LIB/allowed_signers" 644  # the release key updates must be signed with
[ -d "$LIB/vscode" ] || note "created-dir $LIB/vscode"  # safeai's VS Code extension, put in by safeai settings
install -d -m 755 "$LIB/vscode"
for f in package.json extension.js; do put "$SRC/share/vscode/$f" "$LIB/vscode/$f" 644; done
# Tab completion (bash-completion looks in /usr/local/share too)
for d in /usr/local/share/bash-completion /usr/local/share/bash-completion/completions; do
    [ -d "$d" ] || { note "created-dir $d"; install -d -m 755 "$d"; }
done
put "$SRC/share/bash-completion/safeai" /usr/local/share/bash-completion/completions/safeai 644

note "acl-user $AGENT"
# folders in your home that safeai creates, removed again if still empty on uninstall
for d in .config .local .local/share .local/share/nautilus-python .local/share/nautilus-python/extensions; do
    [ -e "$OWNER_HOME/$d" ] || note "created-dir $OWNER_HOME/$d"
done
m applying; echo  # a home with millions of files takes a while: say so before the pause
[ $FIRST = yes ] && note "created-lists $CONF"
# your umask, kept with your lists: whether a file others may not read is private on purpose (with
# 077 every file is, so the mode says nothing; see mode_private in bin/safeai)
as_owner sh -c 'mkdir -p "$0" && chmod 700 "$0" && umask >"$0/umask"' "$CONF"
# safeai-keep is not set up yet at this point (an update from a version without it): the rules from
# your lists are asked for once, after the AppArmor profile (SAFEAI_INSTALLING)
if [ $FIRST = yes ]; then
    as_owner env SAFEAI_INSTALLING=1 /usr/local/bin/safeai init "$HOME_MODE"
    # this checkout: the agent must not change what the next "sudo ./install.sh" runs
    case "$SRC/" in "$OWNER_HOME"/*) as_owner env SAFEAI_INSTALLING=1 /usr/local/bin/safeai read "$SRC" >/dev/null ;; esac
else
    as_owner env SAFEAI_INSTALLING=1 /usr/local/bin/safeai setup
fi
if [ "$MODE_ARG" != --update ]; then  # the copy installed from: uninstall.sh offers to delete it
    sed -i '/^source-dir /d' "$MANIFEST"
    case "$SRC/" in "$OWNER_HOME"/?*/) note "source-dir $SRC" ;; esac
fi

for u in safeai-guard.service safeai-check.service safeai-check.timer safeai-ask.socket safeai-ask@.service \
         safeai-web.service safeai-web.socket safeai-web@.service safeai-keep.socket safeai-keep@.service; do
    [ -e "/etc/systemd/system/$u" ] || note "created-file /etc/systemd/system/$u"
done
whole /etc/systemd/system/safeai-guard.service <<EOF
[Unit]
Description=safeai: agent files to the owner, new .env closed at once
After=local-fs.target

[Service]
ExecStart=$LIB/safeai-guard
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
whole /etc/systemd/system/safeai-check.service <<EOF
[Unit]
Description=safeai: verify and repair agent access

[Service]
Type=oneshot
User=$OWNER
ExecStart=/usr/local/bin/safeai check --fix
Nice=10
IOSchedulingClass=idle
EOF
whole /etc/systemd/system/safeai-check.timer <<'EOF'
[Unit]
Description=safeai: check agent access every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
# the agent asks you for access (safeai ask): a question on your screen, answered as you
whole /etc/systemd/system/safeai-ask.socket <<EOF
[Unit]
Description=safeai: the agent asks you for access on your screen

[Socket]
ListenStream=/run/safeai-ask.sock
SocketUser=root
SocketGroup=$(id -gn "$AGENT")
SocketMode=0660
RemoveOnStop=yes
Accept=yes
MaxConnections=1

[Install]
WantedBy=sockets.target
EOF
whole /etc/systemd/system/safeai-ask@.service <<EOF
[Unit]
Description=safeai: a question from the agent

[Service]
User=$OWNER
ExecStart=/usr/local/bin/safeai _answer
StandardInput=socket
StandardOutput=socket
StandardError=journal
RuntimeMaxSec=300
EOF
# the agent's web only through your proxy (safeai settings: proxy): at boot, and when safeai asks
command -v nft >/dev/null || pkg_install nftables
WEB_LIMITS="CapabilityBoundingSet=CAP_NET_ADMIN CAP_DAC_READ_SEARCH
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/run
ProtectHome=read-only
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_NETLINK
MemoryMax=64M"
whole /etc/systemd/system/safeai-web.service <<EOF
[Unit]
Description=safeai: the agent's web only through your proxy, when you set one
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$LIB/safeai-web
$WEB_LIMITS

[Install]
WantedBy=multi-user.target
EOF
whole /etc/systemd/system/safeai-web.socket <<EOF
[Unit]
Description=safeai: apply your proxy setting for the agent's web

[Socket]
ListenStream=/run/safeai-web.sock
SocketUser=root
SocketGroup=$OWNER_GROUP
SocketMode=0660
RemoveOnStop=yes
Accept=yes
MaxConnections=4

[Install]
WantedBy=sockets.target
EOF
whole /etc/systemd/system/safeai-web@.service <<EOF
[Unit]
Description=safeai: apply your proxy setting for the agent's web

[Service]
ExecStart=$LIB/safeai-web
StandardInput=socket
StandardOutput=socket
StandardError=journal
RuntimeMaxSec=30
$WEB_LIMITS
EOF
# what you closed or made read-only stays where it is: AppArmor rules from your lists (safeai-keep)
KEEP_LIMITS="CapabilityBoundingSet=CAP_MAC_ADMIN CAP_DAC_READ_SEARCH
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/run /etc/apparmor.d/local
ProtectHome=read-only
PrivateTmp=yes
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX
MemoryMax=256M"
whole /etc/systemd/system/safeai-keep.socket <<EOF
[Unit]
Description=safeai: what you closed or made read-only stays where it is

[Socket]
ListenStream=/run/safeai-keep.sock
SocketUser=root
SocketGroup=$OWNER_GROUP
SocketMode=0660
RemoveOnStop=yes
Accept=yes
MaxConnections=4

[Install]
WantedBy=sockets.target
EOF
whole /etc/systemd/system/safeai-keep@.service <<EOF
[Unit]
Description=safeai: what you closed or made read-only stays where it is

[Service]
ExecStart=$LIB/safeai-keep
StandardInput=socket
StandardOutput=socket
StandardError=journal
RuntimeMaxSec=120
$KEEP_LIMITS
EOF
note "nft-table inet safeai"
systemctl daemon-reload
systemctl enable --now safeai-check.timer >/dev/null 2>&1
systemctl enable --now safeai-ask.socket >/dev/null 2>&1
systemctl enable --now safeai-web.socket >/dev/null 2>&1
systemctl enable --now safeai-keep.socket >/dev/null 2>&1
systemctl enable safeai-web.service >/dev/null 2>&1
systemctl restart safeai-web.service >/dev/null 2>&1 || true  # "failed: why" is in /run/safeai-web
web=$(as_owner /usr/local/bin/safeai _web 2>/dev/null) || true  # your proxy setting counts from now, not from the first chat
case "$web" in on|off) ;; *) m web_failed "${web:-safeai-web does not answer}" >&2; echo >&2 ;; esac
systemctl enable safeai-guard.service >/dev/null 2>&1
systemctl restart safeai-guard.service

# ---- AppArmor --------------------------------------------------------------------------------
if [ $APPARMOR = yes ]; then
    say "$(m s_apparmor)"
    abi=3.0 extra=""
    if [ -e /etc/apparmor.d/abi/4.0 ]; then abi=4.0 extra=$'  userns,\n  mqueue,\n  io_uring,'; fi
    backup /etc/apparmor.d/safeai-agent
    note "apparmor safeai-agent"
    # the rules safeai-keep writes from your lists, included by the profile
    [ -d /etc/apparmor.d/local ] || { note "created-dir /etc/apparmor.d/local"; mkdir -p /etc/apparmor.d/local; }
    backup /etc/apparmor.d/local/safeai-keep  # put back as it was on uninstall, if it was there
    sed -e "s|@ABI@|$abi|" -e "s|@OWNERHOME@|$OWNER_HOME|" "$SRC/share/apparmor/safeai-agent.in" |
        awk -v extra="$extra" '{ if ($0 == "  @EXTRA@") { if (extra != "") print extra } else print }' |
        whole /etc/apparmor.d/safeai-agent
    apparmor_parser -r /etc/apparmor.d/safeai-agent
    keep=$(as_owner /usr/local/bin/safeai _keep 2>/dev/null) || true  # your lists, as rules: at once
    case "$keep" in on*|off) ;; *) m keep_failed "${keep:-safeai-keep does not answer}" >&2; echo >&2 ;; esac
    backup /etc/shells
    grep -qx "$LIB/safeai-shell" /etc/shells || { cat /etc/shells; echo "$LIB/safeai-shell"; } | whole /etc/shells
    sh_was=$(getent passwd "$AGENT" | cut -d: -f7)
    grep -q "^agent-shell " "$MANIFEST" || note "agent-shell $sh_was"  # put back on uninstall
    [ "$sh_was" = "$LIB/safeai-shell" ] || usermod -s "$LIB/safeai-shell" "$AGENT"
    drop=/etc/systemd/system/user@$(id -u "$AGENT").service.d
    [ -e "$drop/safeai.conf" ] || note "created-file $drop/safeai.conf"
    mkdir -p "$drop"
    printf '[Service]\nAppArmorProfile=safeai-agent\n' | whole "$drop/safeai.conf"
    systemctl daemon-reload
    for f in /etc/cron.deny /etc/at.deny; do
        backup "$f"
        touch "$f"
        grep -qx "$AGENT" "$f" || { cat "$f"; echo "$AGENT"; } | whole "$f" "$(stat -c %a "$f")"
    done
fi

# ---- audit log -------------------------------------------------------------------------------
if [ $AUDIT = yes ]; then
    say "$(m s_audit)"
    members=$(getent group "$OWNER_GROUP" | cut -d: -f4)
    if [ -n "$members" ] && [ "$members" != "$OWNER" ]; then
        die "$(m err_auditgroup "$OWNER_GROUP")"
    fi
    if ! command -v auditctl >/dev/null; then
        pkg_install auditd 2>/dev/null || pkg_install audit  # Debian/Ubuntu; Fedora and Arch
    fi
    u=$(id -u "$AGENT")
    [ -e /etc/audit/rules.d/50-safeai.rules ] || note "created-file /etc/audit/rules.d/50-safeai.rules"
    # only syscalls this architecture has (arm64 has no open, rename, mkdir, ...)
    names="open openat openat2 creat truncate execve unlink unlinkat rename renameat renameat2
           mkdir mkdirat rmdir chmod fchmodat link linkat symlink symlinkat"
    {
        echo "# safeai: permission refusals of the agent user (safeai log)"
        for a in b64 b32; do
            sc=""
            for n in $names; do
                ausyscall "$([ $a = b64 ] && uname -m || echo i386)" "$n" >/dev/null 2>&1 && sc+="${sc:+,}$n"
            done
            [ -n "$sc" ] || continue
            for e in EACCES EPERM; do
                echo "-a always,exit -F arch=$a -S $sc -F uid=$u -F exit=-$e -k safeai-deny"
            done
        done
    } | whole /etc/audit/rules.d/50-safeai.rules 640
    backup /etc/audit/auditd.conf
    sed -i "s/^log_group *=.*/log_group = $OWNER_GROUP/" /etc/audit/auditd.conf
    grep -q "^audit-log-dir " "$MANIFEST" ||
        note "audit-log-dir /var/log/audit $(stat -c %G /var/log/audit) $(stat -c %a /var/log/audit)"
    chgrp "$OWNER_GROUP" /var/log/audit && chmod 750 /var/log/audit
    # auditd enabled/started here is stopped and disabled again on uninstall
    systemctl is-enabled --quiet auditd 2>/dev/null || note "enabled-service auditd"
    # Fedora and Arch refuse "systemctl restart auditd": start it if needed and send
    # SIGHUP, which makes auditd read its config (the new log group) again
    systemctl enable --now auditd >/dev/null 2>&1 || true
    kill -HUP "$(pidof auditd)"
    backup /etc/audit/audit.rules  # augenrules writes these two
    [ -e /etc/audit/audit.rules.prev ] || note "created-file /etc/audit/audit.rules.prev"
    # safeai's rules loaded before go first: where nothing in rules.d starts with -D (Arch), loading
    # them again stops at "Rule exists". Other rules there may fail to load too; ours must not.
    auditctl -D -k safeai-deny >/dev/null 2>&1 || true
    augenrules --load >/dev/null 2>&1 || true
    auditctl -l 2>/dev/null | grep -q "key=safeai-deny" || die "$(m err_audit)"
fi

# ---- VS Code and Files (your account, no root) -------------------------------------------------
if [ $VSCODE = yes ]; then
    say "$(m s_vscode)"
    note "vscode $OWNER"
    as_owner /usr/local/bin/safeai settings set vscode on
fi
if [ $NAUTILUS = yes ]; then
    say "$(m s_nautilus)"
    python3 -c 'import gi; gi.require_version("Nautilus", "4.0")' 2>/dev/null ||
        pkg_install python3-nautilus 2>/dev/null || pkg_install nautilus-python 2>/dev/null ||
            pkg_install python-nautilus  # Debian/Ubuntu; Fedora; Arch
    ext=$OWNER_HOME/.local/share/nautilus-python/extensions/safeai_nautilus.py
    backup "$ext"
    changed=no
    if ! cmp -s "$SRC/share/nautilus/safeai_nautilus.py" "$ext"; then
        as_owner install -D -m 644 "$SRC/share/nautilus/safeai_nautilus.py" "$ext"
        changed=yes
    fi
    # its emblems: closed, read-only, partly open
    icons=.local/share/icons/hicolor/scalable/emblems
    for d in .local/share/icons .local/share/icons/hicolor .local/share/icons/hicolor/scalable "$icons"; do
        [ -e "$OWNER_HOME/$d" ] || note "created-dir $OWNER_HOME/$d"
    done
    for f in "$SRC"/share/nautilus/emblems/safeai-*.svg; do
        dst=$OWNER_HOME/$icons/$(basename "$f")
        [ -e "$dst" ] || note "created-file $dst"
        cmp -s "$f" "$dst" || { as_owner install -D -m 644 "$f" "$dst"; changed=yes; }
    done
    icon_cache
    [ $changed = yes ] && files_restart && { m restart_files; echo; }
fi

# ---- what the agent is told ---------------------------------------------------------------------
# The agent's own instructions stay as they are: safeai's notes go to ~/.claude/safeai.md,
# imported by its CLAUDE.md, and into a marked block of ~/.codex/AGENTS.md (left alone
# when that is a link to somewhere else). Done as the agent, in its own home.
sed "s|@OWNER@|$OWNER|g; s|@MARK@|$(m agent_mark)|g" "$SRC/share/agent-about.md" | runuser -u "$AGENT" -- env HOME="$AGENT_HOME" python3 -I -c '
import os, re, sys
text = sys.stdin.read()
home = os.path.expanduser("~")
os.makedirs(home + "/.claude", mode=0o700, exist_ok=True)
os.makedirs(home + "/.codex", mode=0o700, exist_ok=True)
def write(p, data):
    with open(p + ".safeai.tmp", "w") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(p + ".safeai.tmp", p)
write(home + "/.claude/safeai.md", text)
IMPORT = "@~/.claude/safeai.md"
p = home + "/.claude/CLAUDE.md"
old = open(p).read() if os.path.isfile(p) and not os.path.islink(p) else ""
if old.startswith(text.splitlines()[0] + "\n"):
    old = ""  # written whole by an older safeai: the import replaces it
if not os.path.islink(p) and IMPORT not in old.splitlines():
    write(p, IMPORT + "\n" + ("\n" + old if old else ""))
START, END = "<!-- safeai: start -->", "<!-- safeai: end -->"
block = START + "\n" + text.rstrip("\n") + "\n" + END + "\n"
p = home + "/.codex/AGENTS.md"
if os.path.islink(p) or (os.path.exists(p) and not os.path.isfile(p)):
    print(f"Note: {p} is a link; safeai left it as it is. Its notes for the agent are in ~/.claude/safeai.md.")
else:
    old = open(p).read() if os.path.exists(p) else ""
    if old.startswith(text.splitlines()[0] + "\n"):
        old = ""
    old = re.sub(re.escape(START) + ".*?" + re.escape(END) + "\n?", "", old, flags=re.S)
    write(p, block + ("\n" + old if old.strip() else ""))
'
# Claude Code (as the agent): when a tool is refused, safeai-explain tells the model why and
# what to ask you for; each reply begins with a mark that the chat is the agent's (safeai-owner-mark).
# Merged into the agent's own settings, never overwriting them.
runuser -u "$AGENT" -- env HOME="$AGENT_HOME" python3 -I -c '
import json, os, sys
p = os.path.expanduser("~/.claude/settings.json")
try:
    d = json.load(open(p))
except FileNotFoundError:
    d = {}
except ValueError:
    sys.exit(0)  # not plain JSON: leave it to its owner
for event, cmd in (("PostToolUseFailure", sys.argv[1]), ("UserPromptSubmit", sys.argv[2])):
    entries = d.setdefault("hooks", {}).setdefault(event, [])
    if not any(h.get("command") == cmd for e in entries for h in e.get("hooks", [])):
        entries.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p + ".safeai.tmp", "w") as f:
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(p + ".safeai.tmp", p)
' "$LIB/safeai-explain" "$LIB/safeai-owner-mark"
# a user safeai made, whose shell files a power cut emptied (written, not yet on disk): from /etc/skel again
if grep -qx "created-user $AGENT" "$MANIFEST"; then
    for f in .bashrc .profile .bash_logout; do
        if [ -f "/etc/skel/$f" ] && [ ! -s "$AGENT_HOME/$f" ] && [ ! -L "$AGENT_HOME/$f" ]; then
            runuser -u "$AGENT" -- sh -c 'cat >"$0"' "$AGENT_HOME/$f" <"/etc/skel/$f"
        fi
    done
fi
# its shell tells how to install claude, codex, ... for itself (the agent's own file; no-op once removed)
runuser -u "$AGENT" -- env HOME="$AGENT_HOME" sh -c 'cd && { grep -qF "$0" .bashrc 2>/dev/null ||
    printf "\n[ -f %s ] && . %s\n" "$0" "$0" >>.bashrc; }; sync -f .bashrc' "$LIB/agent-shell.sh"

# git for the agent in your repositories: they belong to you, so git refuses them
# ("dubious ownership") until the agent trusts them. That check guards the agent from
# your .git/config, which is fine; the other way round is guarded by .git/config being
# read-only to the agent. Its commits carry your name and e-mail, as your own would.
if command -v git >/dev/null; then
    as_agent_git() { runuser -u "$AGENT" -- env HOME="$AGENT_HOME" git config --global "$@"; }
    as_agent_git --get-all safe.directory 2>/dev/null | grep -qx '\*' || as_agent_git --add safe.directory '*'
    for k in user.name user.email; do
        v=$(as_owner git config --global --get "$k" 2>/dev/null || true)
        if [ -n "$v" ] && ! as_agent_git --get "$k" >/dev/null 2>&1; then as_agent_git "$k" "$v"; fi
    done
fi

trap - ERR
find "$UPD" -delete 2>/dev/null || true  # the update went through: no way back needed
say "$(m s_done)"
m done "$LIB" "$LIB"; echo
