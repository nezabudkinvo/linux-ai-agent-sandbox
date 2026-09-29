#!/bin/bash
# safeai installer.
#
#   ./install.sh                ask a few questions, show the plan; on your yes it
#                               asks for sudo and installs exactly that plan
#   ./install.sh --plan         only show what would be changed
#   sudo ./install.sh --yes     install with the defaults, no questions
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
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB=/usr/local/lib/safeai
STATE=/var/lib/safeai
MANIFEST=$STATE/manifest
MODE_ARG=${1:-}
STARTED=no
NEW_USER=no
case "$MODE_ARG" in ""|--plan|--yes|--update|--apply) ;; *) sed -n '2,17s/^# \{0,1\}//p' "$0"; exit 1 ;; esac
[ "$(uname -s)" = Linux ] || { echo "Linux only" >&2; exit 1; }
if [ "$(id -u)" = 0 ]; then
    OWNER=${SUDO_USER:-}
    [ -n "$OWNER" ] && [ "$OWNER" != root ] || { echo "run it from your own account: ./install.sh" >&2; exit 1; }
else
    OWNER=$(id -un)
    case "$MODE_ARG" in --yes|--update|--apply) echo "this needs sudo: sudo ./install.sh $MODE_ARG" >&2; exit 1 ;; esac
fi
# --apply: the answers you gave before sudo, as KEY=VALUE arguments (checked below)
declare -A GIVEN=()
if [ "$MODE_ARG" = --apply ]; then
    for kv in "${@:2}"; do
        case "$kv" in AGENT=*|MODE=*|APPARMOR=*|AUDIT=*|VSCODE=*|NAUTILUS=*|LANG=*) GIVEN[${kv%%=*}]=${kv#*=} ;;
            *) echo "bad argument: $kv" >&2; exit 1 ;; esac
    done
    for k in APPARMOR AUDIT VSCODE NAUTILUS; do
        case "${GIVEN[$k]:-}" in yes|no) ;; *) echo "bad $k" >&2; exit 1 ;; esac
    done
    case "${GIVEN[MODE]:-}" in strict|relaxed|keep) ;; *) echo "bad MODE" >&2; exit 1 ;; esac
    case "${GIVEN[LANG]:-}" in en|ru) ;; *) echo "bad LANG" >&2; exit 1 ;; esac
fi
saved() { sed -n "s/^$1=//p" /etc/safeai.conf 2>/dev/null | tail -1 || true; }  # answers from the last install
if [ "$MODE_ARG" = --update ] && [ ! -f "$MANIFEST" ]; then
    echo "safeai is not installed; run: sudo ./install.sh" >&2; exit 1
fi

# ---- messages (printf templates); share/i18n/ru replaces them ------------------------------
declare -A MSG=(
    [error]="error: %s"
    [error_line]="error on line %s"
    [reverting]="reverting what was already done"
    [sudo_why]="Installing needs root for the changes above; sudo asks for your password now."
    [err_home]="home folder of %s not found"
    [err_systemd]="systemd is required"
    [err_python]="python 3.8 or newer is required"
    [err_pkg]="install %s with your package manager and re-run"
    [q_agent]="Name of the agent's Linux user"
    [err_name]="bad user name: %s"
    [err_same]="the agent must be a separate user"
    [err_exists]="user %s already exists and was not created by safeai; choose another name"
    [q_mode]="Default for your home: strict (the agent sees nothing until you open it) or relaxed (your folders open, settings read-only, secrets closed)"
    [err_mode]="answer strict or relaxed"
    [q_apparmor]="AppArmor: refuse .env-like files to every agent process at open time"
    [q_audit]="Audit log of refused actions (safeai log; installs auditd, changes its log group)"
    [q_vscode]="VS Code: Claude Code and Codex always run as the agent (safeai settings switches back)"
    [q_nautilus]="Files (Nautilus): right-click menu and emblems"
    [plan]="Plan"
    [plan_head]="Owner: %s    agent user: %s    home default: %s\n\nWith sudo, as root:"
    [mode_keep]="as before"
    [plan_core]="  user %s (no password, no groups of yours, no sudo)
  /etc/sudoers.d/safeai          %s may run programs as %s; nothing the other way
  /etc/safeai.conf, /usr/local/bin/safeai (with Tab completion), %s/
  services safeai-guard (root), safeai-check.timer (as %s, every 5 minutes)"
    [plan_lists]="  your lists in %s (secret stores like ~/.ssh closed in both modes)"
    [plan_apparmor]="  AppArmor profile /etc/apparmor.d/safeai-agent; login shell of %s -> %s/safeai-shell;
  %s added to /etc/cron.deny and /etc/at.deny (backed up)"
    [plan_audit]="  audit rules /etc/audit/rules.d/50-safeai.rules;
  /etc/audit/auditd.conf: log_group -> %s (backed up)"
    [plan_packages]="  packages from %s: %s (and what they depend on)"
    [plan_you]="As you (no root):
  ACL entries for %s on your files (only that user's entries; removed on uninstall)"
    [plan_agent]="As %s: its instructions (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md), git trust for your
  repositories and your git name and e-mail for its commits"
    [plan_vscode]="  VS Code settings.json: two settings (backed up to settings.json.safeai-backup)"
    [plan_nautilus]="  ~/.local/share/nautilus-python/extensions/safeai_nautilus.py;
  Files restarts to load it (its open windows close)"
    [plan_untouched]="Does not touch: network, other users, your groups or login, other services."
    [proceed]="Proceed? [Y/n]: "
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
    [restart_files]="Files restarted to load the extension"
    [done]="  safeai                  a terminal as the agent here (then claude, codex, ...; exit to leave)
  safeai status           mode and your rules
  safeai ls DIR           what the agent can do there
  safeai open PATH        the agent may read and write there
  safeai read PATH        read only
  safeai close PATH       closed
  safeai settings         settings; r there drops all your rules (asks first)
  Verify:                 %s/check.sh
  Remove:                 sudo %s/uninstall.sh
  The downloaded copy is no longer needed and can be deleted."
)
m() {  # m KEY [ARGS...] - the message, formatted
    local key=$1; shift
    # shellcheck disable=SC2059
    printf "${MSG[$key]}" "$@"
}
tty_ok() { (: </dev/tty) 2>/dev/null; }  # a terminal to ask in (not when piped or in CI)
LANG_CHOICE=${GIVEN[LANG]:-${SAFEAI_LANG:-$(saved LANG)}}
if [ -z "$LANG_CHOICE" ] && { [ "$MODE_ARG" = "" ] || [ "$MODE_ARG" = --plan ]; } && tty_ok; then
    read -r -p "Language (en/ru) [en]: " LANG_CHOICE </dev/tty || true
fi
# shellcheck source=share/i18n/ru
[ "${LANG_CHOICE:-en}" = ru ] && . "$SRC/share/i18n/ru"

rollback() {
    trap - ERR
    if [ "$MODE_ARG" = --update ]; then  # keep the working installation and your settings
        echo "update failed; safeai keeps running with what is installed. Try again: safeai settings update" >&2
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
say() { printf '\n== %s\n' "$*"; }
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
if getent passwd "$AGENT" >/dev/null && ! ours_agent "$AGENT"; then
    die "$(m err_exists "$AGENT")"
fi
if [ "$MODE_ARG" != --apply ]; then
HOME_MODE=keep
if [ $FIRST = yes ]; then
    ask HOME_MODE "$(m q_mode)" \
        "${SAFEAI_MODE:-strict}"
    case "$HOME_MODE" in strict|relaxed) ;; *) die "$(m err_mode)" ;; esac
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
if [ "$MODE_ARG" != --apply ]; then
say "$(m plan)"
m plan_head "$OWNER" "$AGENT" "$([ "$HOME_MODE" = keep ] && m mode_keep || echo "$HOME_MODE")"; echo
m plan_core "$AGENT" "$OWNER" "$AGENT" "$LIB" "$OWNER"; echo
[ $APPARMOR = yes ] && { m plan_apparmor "$AGENT" "$LIB" "$AGENT"; echo; }
[ $AUDIT = yes ] && { m plan_audit "$OWNER_GROUP"; echo; }
# the packages that are missing, by the names this system uses
need=()
command -v setfacl >/dev/null || need+=(acl)
if [ $AUDIT = yes ] && ! command -v auditctl >/dev/null; then
    case $PKG in apt) need+=(auditd) ;; *) need+=(audit) ;; esac
fi
if [ $NAUTILUS = yes ] && ! python3 -c 'import gi; gi.require_version("Nautilus", "4.0")' 2>/dev/null; then
    case $PKG in apt) need+=(python3-nautilus) ;; dnf) need+=(nautilus-python) ;; *) need+=(python-nautilus) ;; esac
fi
[ ${#need[@]} -gt 0 ] && { m plan_packages "$PKG" "${need[*]}"; echo; }
m plan_you "$AGENT"; echo
[ $FIRST = yes ] && { m plan_lists "$CONF"; echo; }
[ $VSCODE = yes ] && { m plan_vscode; echo; }
[ $NAUTILUS = yes ] && { m plan_nautilus; echo; }
m plan_agent "$AGENT"; echo
m plan_untouched; echo
[ "$MODE_ARG" = --plan ] && exit 0
if [ "$MODE_ARG" = "" ]; then
    go=n  # no terminal to ask in: no
    tty_ok && { go=""; read -r -p "$(m proceed)" go </dev/tty || go=n; }
    case "${go:-y}" in [yY]*) ;; *) m nothing; echo; exit 0 ;; esac
fi
fi
if [ "$(id -u)" != 0 ]; then  # the plan is agreed: now root, for exactly these answers
    echo; m sudo_why; echo
    exec sudo -- "$SRC/install.sh" --apply "AGENT=$AGENT" "MODE=$HOME_MODE" "APPARMOR=$APPARMOR" \
        "AUDIT=$AUDIT" "VSCODE=$VSCODE" "NAUTILUS=$NAUTILUS" "LANG=${LANG_CHOICE:-en}"
fi

# ---- manifest and rollback -----------------------------------------------------------------
mkdir -p "$STATE" && chmod 700 "$STATE"
touch "$MANIFEST"
STARTED=yes
trap 'm error_line "$LINENO" >&2; echo >&2; rollback' ERR
note() { grep -qxF "$*" "$MANIFEST" || echo "$*" >>"$MANIFEST"; }
backup() {  # backup FILE - keep the original once, record it
    local f=$1 b
    [ -e "$f" ] || { note "created-file $f"; return 0; }
    grep -q "^modified-file $f " "$MANIFEST" && return 0
    b=$STATE/backup/${f//\//%}
    mkdir -p "$STATE/backup" && cp -a "$f" "$b" && note "modified-file $f $b"
}
put() {  # put SRC DEST MODE - install a file safeai owns
    [ -e "$2" ] || note "created-file $2"
    install -m "$3" -o root -g root "$1" "$2"
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
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null 2>&1 ||
                 { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null; } ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        pacman) pacman -S --needed --noconfirm "$@" >/dev/null ;;
        *) m err_pkg "$*" >&2; echo >&2; return 1 ;;
    esac || return 1
    # every package that came in, dependencies included: uninstall removes them again
    local p
    for p in $(comm -13 <(printf '%s\n' "$PKGS_BEFORE") <(pkg_list)); do note "installed-package $p"; done
}

# ---- core ---------------------------------------------------------------------------------
say "$(m s_core)"
command -v setfacl >/dev/null || pkg_install acl
probe=$(as_owner mktemp "$OWNER_HOME/.safeai-acl-test.XXXXXX")
if ! setfacl -m u:root:r-- "$probe" 2>/dev/null; then
    rm -f "$probe"
    die "$(m err_acl)"
fi
rm -f "$probe"

if ! getent passwd "$AGENT" >/dev/null; then
    useradd -m -U -s /bin/bash "$AGENT"
    note "created-user $AGENT"
    NEW_USER=yes
fi
usermod -p '*' "$AGENT"
AGENT_HOME=$(getent passwd "$AGENT" | cut -d: -f6)
chmod 750 "$AGENT_HOME"
if id -nG "$AGENT" | tr ' ' '\n' | grep -qvx "$AGENT"; then die "$(m err_groups "$AGENT")"; fi
# the agent must not be able to change what root is about to run
if [ -n "$(runuser -u "$AGENT" -- find "$SRC" -writable -print -quit 2>/dev/null)" ]; then
    die "$(m err_writable "$SRC" "$AGENT")"
fi

tmp=$(mktemp)
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
for f in safeai-guard safeai-run safeai-codex safeai-shell safeai-acl-clean; do put "$SRC/libexec/$f" "$LIB/$f" 755; done
# so the checkout can be deleted: removal and the checks live next to the program
put "$SRC/uninstall.sh" "$LIB/uninstall.sh" 755
put "$SRC/share/i18n/ru" "$LIB/i18n-ru" 644  # uninstall.sh speaks the language chosen here
put "$SRC/share/agent-shell.sh" "$LIB/agent-shell.sh" 644  # the agent's shell: how to install AI tools
put "$SRC/tests/check.sh" "$LIB/check.sh" 755
put "$SRC/VERSION" "$LIB/VERSION" 644
put "$SRC/share/allowed_signers" "$LIB/allowed_signers" 644  # the release key updates must be signed with
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
if [ $FIRST = yes ]; then
    note "created-lists $CONF"
    as_owner /usr/local/bin/safeai init "$HOME_MODE"
    # this checkout: the agent must not change what the next "sudo ./install.sh" runs
    case "$SRC/" in "$OWNER_HOME"/*) as_owner /usr/local/bin/safeai read "$SRC" >/dev/null ;; esac
else
    as_owner /usr/local/bin/safeai setup
fi
if [ "$MODE_ARG" != --update ]; then  # the copy installed from: uninstall.sh offers to delete it
    sed -i '/^source-dir /d' "$MANIFEST"
    case "$SRC/" in "$OWNER_HOME"/?*/) note "source-dir $SRC" ;; esac
fi

for u in safeai-guard.service safeai-check.service safeai-check.timer; do
    [ -e "/etc/systemd/system/$u" ] || note "created-file /etc/systemd/system/$u"
done
cat >/etc/systemd/system/safeai-guard.service <<EOF
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
cat >/etc/systemd/system/safeai-check.service <<EOF
[Unit]
Description=safeai: verify and repair agent access

[Service]
Type=oneshot
User=$OWNER
ExecStart=/usr/local/bin/safeai check --fix
Nice=10
IOSchedulingClass=idle
EOF
cat >/etc/systemd/system/safeai-check.timer <<'EOF'
[Unit]
Description=safeai: check agent access every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now safeai-check.timer >/dev/null 2>&1
systemctl enable safeai-guard.service >/dev/null 2>&1
systemctl restart safeai-guard.service

# ---- AppArmor --------------------------------------------------------------------------------
if [ $APPARMOR = yes ]; then
    say "$(m s_apparmor)"
    abi=3.0 extra=""
    if [ -e /etc/apparmor.d/abi/4.0 ]; then abi=4.0 extra=$'  userns,\n  mqueue,\n  io_uring,'; fi
    [ -e /etc/apparmor.d/safeai-agent ] || note "created-file /etc/apparmor.d/safeai-agent"
    note "apparmor safeai-agent"
    sed "s|@ABI@|$abi|" "$SRC/share/apparmor/safeai-agent.in" |
        awk -v extra="$extra" '{ if ($0 == "  @EXTRA@") { if (extra != "") print extra } else print }' \
        >/etc/apparmor.d/safeai-agent
    apparmor_parser -r /etc/apparmor.d/safeai-agent
    backup /etc/shells
    grep -qx "$LIB/safeai-shell" /etc/shells || echo "$LIB/safeai-shell" >>/etc/shells
    [ "$(getent passwd "$AGENT" | cut -d: -f7)" = "$LIB/safeai-shell" ] || usermod -s "$LIB/safeai-shell" "$AGENT"
    drop=/etc/systemd/system/user@$(id -u "$AGENT").service.d
    [ -e "$drop/safeai.conf" ] || note "created-file $drop/safeai.conf"
    mkdir -p "$drop"
    printf '[Service]\nAppArmorProfile=safeai-agent\n' >"$drop/safeai.conf"
    systemctl daemon-reload
    for f in /etc/cron.deny /etc/at.deny; do
        backup "$f"
        touch "$f"
        grep -qx "$AGENT" "$f" || echo "$AGENT" >>"$f"
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
    } >/etc/audit/rules.d/50-safeai.rules
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
    augenrules --load >/dev/null
fi

# ---- VS Code and Files (your account, no root) -------------------------------------------------
if [ $VSCODE = yes ]; then
    say "$(m s_vscode)"
    note "vscode $OWNER"
    as_owner /usr/local/bin/safeai settings set vscode agent
fi
if [ $NAUTILUS = yes ]; then
    say "$(m s_nautilus)"
    python3 -c 'import gi; gi.require_version("Nautilus", "4.0")' 2>/dev/null ||
        pkg_install python3-nautilus 2>/dev/null || pkg_install nautilus-python 2>/dev/null ||
            pkg_install python-nautilus  # Debian/Ubuntu; Fedora; Arch
    ext=$OWNER_HOME/.local/share/nautilus-python/extensions/safeai_nautilus.py
    [ -e "$ext" ] || note "created-file $ext"
    if ! cmp -s "$SRC/share/nautilus/safeai_nautilus.py" "$ext"; then
        as_owner install -D -m 644 "$SRC/share/nautilus/safeai_nautilus.py" "$ext"
        files_restart && { m restart_files; echo; }
    fi
fi

# ---- what the agent is told ---------------------------------------------------------------------
runuser -u "$AGENT" -- env HOME="$AGENT_HOME" sh -c 'umask 077; cd && mkdir -p .claude .codex &&
    cat >.claude/.CLAUDE.md.tmp && mv -f .claude/.CLAUDE.md.tmp .claude/CLAUDE.md &&
    cp .claude/CLAUDE.md .codex/.AGENTS.md.tmp && mv -f .codex/.AGENTS.md.tmp .codex/AGENTS.md' \
    < <(sed "s|@OWNER@|$OWNER|g" "$SRC/share/agent-about.md")
# its shell tells how to install claude, codex, ... for itself (the agent's own file; no-op once removed)
runuser -u "$AGENT" -- env HOME="$AGENT_HOME" sh -c 'cd && { grep -qF "$0" .bashrc 2>/dev/null ||
    printf "\n[ -f %s ] && . %s\n" "$0" "$0" >>.bashrc; }' "$LIB/agent-shell.sh"

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
say "$(m s_done)"
m done "$LIB" "$LIB"; echo
