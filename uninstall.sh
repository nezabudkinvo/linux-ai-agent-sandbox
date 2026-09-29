#!/bin/bash
# Remove safeai, as if it had never been installed: everything recorded in
# /var/lib/safeai/manifest (backed up files restored, created files removed),
# the ACL entries it put on your files and your safeai lists. It asks whether to
# delete the agent user, the packages safeai installed and the downloaded copy it
# was installed from too (default yes; --yes keeps the copy).
#
#   sudo /usr/local/lib/safeai/uninstall.sh      asks
#   sudo ./uninstall.sh --yes                    no questions: everything but the downloaded copy
#   sudo ./uninstall.sh --keep-agent             keep the agent user and its home
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/var/lib/safeai
MANIFEST=$STATE/manifest
YES=no KEEP_AGENT=no KEEP_PACKAGES=no
for a in "$@"; do
    case "$a" in --yes) YES=yes ;; --keep-agent) KEEP_AGENT=yes ;; *) sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 1 ;; esac
done
[ -n "${SAFEAI_ROLLBACK:-}" ] && YES=yes  # a failed install undoes itself
[ -f "$MANIFEST" ] || { echo "safeai is not installed ($MANIFEST not found)"; exit 0; }
AGENT=$(sed -n 's/^AGENT=//p' /etc/safeai.conf 2>/dev/null); AGENT=${AGENT:-aiagent}
OWNER=$(sed -n 's/^OWNER=//p' /etc/safeai.conf 2>/dev/null); OWNER=${OWNER:-${SUDO_USER:-}}
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
has() { grep -q "^$1" "$MANIFEST"; }
ours_user() { grep -qx "created-user $AGENT" "$MANIFEST" && getent passwd "$AGENT" >/dev/null; }
Q=$OWNER_HOME/.local/share/safeai-quarantine
PKGS=$(sed -n 's/^installed-package //p' "$MANIFEST" | tr '\n' ' ')
SRC_DIR=$(sed -n 's/^source-dir //p' "$MANIFEST" | tail -1)
t='~'; SRC_SHOWN=${SRC_DIR/#"$OWNER_HOME"/$t}
our_copy() {  # the copy safeai was installed from, if it still looks like one: yours, in your home
    [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] && [ ! -L "$SRC_DIR" ] && [ -f "$SRC_DIR/install.sh" ] &&
        [ -f "$SRC_DIR/uninstall.sh" ] && [ -f "$SRC_DIR/VERSION" ] && [ "$(stat -c %U -- "$SRC_DIR")" = "$OWNER" ] &&
        case "$SRC_DIR/" in "$OWNER_HOME"/?*/) true ;; *) false ;; esac
}
DEL_SRC=no

# ---- messages; the translation installed next to this script (or share/i18n/ru) replaces them
declare -A MSG=(
    [u_confirm]="Remove safeai with its services, your rules and the agent's access to your files? [y/N]: "
    [u_agent]="Delete the agent user %s with its home (its logins, chat history, agent programs)? [Y/n]: "
    [u_packages]="Remove the packages safeai installed (%s)? [Y/n]: "
    [u_nothing]="Nothing changed."
    [u_user_deleted]="User %s deleted."
    [u_kept_agent]="Kept: user %s (an ordinary user now; the access safeai gave it is removed). To delete it later: sudo userdel -r %s"
    [u_kept_packages]="Kept packages: %s"
    [u_source]="Delete the downloaded copy it was installed from (%s)? [Y/n]: "
    [u_kept_source]="Kept the downloaded copy: %s"
    [u_cd_away]="Your terminal is still in the deleted folder; leave it: cd ~"
    [u_done]="safeai removed. Files the agent made in your folders stay; they are yours."
)
m() { local k=$1; shift; printf "${MSG[$k]}" "$@"; }  # shellcheck disable=SC2059
if [ "$(sed -n 's/^LANG=//p' /etc/safeai.conf 2>/dev/null)" = ru ]; then
    for f in "$HERE/i18n-ru" "$HERE/share/i18n/ru"; do [ -f "$f" ] && { . "$f"; break; }; done
fi
tty_ok() { (: </dev/tty) 2>/dev/null; }
ask_yes() {  # ask_yes KEY ARGS... - true unless answered n; the default is yes
    local a=""
    read -r -p "$(m "$@")" a </dev/tty || true
    case "$a" in [nN]*) false ;; *) true ;; esac
}

if [ "$YES" != yes ]; then
    go=n
    tty_ok && { read -r -p "$(m u_confirm)" go </dev/tty || go=n; }
    case "$go" in [yY]*) ;; *) m u_nothing; echo; exit 0 ;; esac
    # what may stay: asked only when there is one; the default is to remove
    if ours_user && [ $KEEP_AGENT = no ]; then ask_yes u_agent "$AGENT" || KEEP_AGENT=yes; fi
    if [ -n "$PKGS" ]; then ask_yes u_packages "${PKGS% }" || KEEP_PACKAGES=yes; fi
    if our_copy; then ask_yes u_source "$SRC_SHOWN" && DEL_SRC=yes; fi
fi

systemctl disable --now safeai-guard.service safeai-check.timer >/dev/null 2>&1
# nothing of the agent may keep running while its traces are removed
getent passwd "$AGENT" >/dev/null && pkill -KILL -u "$AGENT" 2>/dev/null
has "vscode " && [ -x /usr/local/bin/safeai ] && sudo -u "$OWNER" -H /usr/local/bin/safeai settings set vscode you >/dev/null 2>&1

# your files: the ACL entries safeai added, agent ownership marks
if has "acl-user " && getent passwd "$AGENT" >/dev/null && [ -d "$OWNER_HOME" ]; then
    clean=$HERE/safeai-acl-clean
    [ -x "$clean" ] || clean=$HERE/libexec/safeai-acl-clean
    python3 -I "$clean" "$OWNER" "$AGENT"
fi

has "apparmor " && [ -e /etc/apparmor.d/safeai-agent ] && apparmor_parser -R /etc/apparmor.d/safeai-agent 2>/dev/null
getent passwd "$AGENT" >/dev/null && [ "$(getent passwd "$AGENT" | cut -d: -f7)" != /bin/bash ] && usermod -s /bin/bash "$AGENT"

# system files: restore what was modified, remove what was created (newest first)
tac "$MANIFEST" | while read -r kind a b c; do
    case "$kind" in
        modified-file) [ -e "$b" ] && cp -a "$b" "$a" ;;
        created-file) rm -f "$a" ;;
        audit-log-dir) chgrp "$b" "$a" 2>/dev/null; chmod "$c" "$a" 2>/dev/null ;;
    esac
done
for d in /etc/systemd/system/user@*.service.d; do rmdir "$d" 2>/dev/null; done
# Files keeps a removed extension loaded until it restarts
if grep -q "^created-file .*/safeai_nautilus.py$" "$MANIFEST" && pgrep -u "$OWNER" -x nautilus >/dev/null; then
    u=$(id -u "$OWNER")
    sudo -u "$OWNER" -H env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$u/bus" XDG_RUNTIME_DIR="/run/user/$u" \
        nautilus -q >/dev/null 2>&1
fi
systemctl daemon-reload
if has "audit-log-dir "; then
    auditctl -D -k safeai-deny >/dev/null 2>&1  # the loaded rules too, not only the files
    if has "enabled-service auditd"; then
        systemctl disable auditd >/dev/null 2>&1
        kill "$(pidof auditd)" 2>/dev/null  # "systemctl stop" is refused on some systems
    else
        kill -HUP "$(pidof auditd)" 2>/dev/null  # reread its restored config
    fi
fi

# packages safeai installed (newest first)
[ $KEEP_PACKAGES = yes ] && { m u_kept_packages "${PKGS% }"; echo; }
[ $KEEP_PACKAGES = yes ] || for p in $(sed -n 's/^installed-package //p' "$MANIFEST" | tac); do  # dependencies too
    # with its configuration files: they were not there before either
    if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "$p" >/dev/null 2>&1
    elif command -v dnf >/dev/null; then dnf remove -y -q "$p" >/dev/null 2>&1
    elif command -v pacman >/dev/null; then pacman -Rn --noconfirm "$p" >/dev/null 2>&1
    fi
done

# your safeai lists and quarantine (a failed update keeps the lists you already had)
if [ -n "$OWNER_HOME" ] && { [ -z "${SAFEAI_ROLLBACK:-}" ] || has "created-lists "; }; then
    rm -rf "$OWNER_HOME/.config/safeai" "$Q"
fi

# folders safeai created in your home, if nothing else is in them now (deepest first)
tac "$MANIFEST" | sed -n "s|^created-dir \($OWNER_HOME/.*\)|\1|p" | while read -r d; do rmdir "$d" 2>/dev/null; done
tac "$MANIFEST" | sed -n "s|^created-dir \(/usr/local/share/.*\)|\1|p" | while read -r d; do rmdir "$d" 2>/dev/null; done

# the agent user: its home, its leftovers in temporary folders
# (a failed install deletes it only if that install created it)
if [ -n "${SAFEAI_ROLLBACK:-}" ]; then [ "${SAFEAI_NEW_USER:-}" = yes ] || KEEP_AGENT=yes; fi
if ours_user && [ $KEEP_AGENT = no ]; then
    u=$(id -u "$AGENT")
    for t in /tmp /var/tmp /dev/shm; do find "$t" -xdev -depth -uid "$u" -delete 2>/dev/null; done
    userdel -r "$AGENT" 2>/dev/null
    getent group "$AGENT" >/dev/null && groupdel "$AGENT" 2>/dev/null
    m u_user_deleted "$AGENT"; echo
    keep=""
else
    keep=$(grep -x "created-user $AGENT" "$MANIFEST" || true)  # still ours, for a later install
    [ -n "$keep" ] && [ -z "${SAFEAI_ROLLBACK:-}" ] && { m u_kept_agent "$AGENT" "$AGENT"; echo; }
fi

grep -q "^created-dir /usr/local/lib/safeai" "$MANIFEST" && rm -rf /usr/local/lib/safeai
rm -rf "$STATE/backup"
if [ -n "$keep" ]; then echo "$keep" >"$MANIFEST"; else rm -f "$MANIFEST"; rmdir "$STATE" 2>/dev/null; fi
# the downloaded copy, only when you said so (never on --yes or a failed install); as you, not as root
if [ $DEL_SRC = yes ]; then
    sudo -u "$OWNER" rm -rf -- "$SRC_DIR"
    # a script cannot move your shell; say so when it stands in the folder just deleted
    case "$PWD/" in "$SRC_DIR"/*) m u_cd_away; echo ;; esac
elif [ -z "${SAFEAI_ROLLBACK:-}" ] && our_copy; then
    m u_kept_source "$SRC_SHOWN"; echo
fi
m u_done; echo
