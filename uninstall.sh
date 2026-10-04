#!/bin/bash
# Remove safeai, as if it had never been installed: everything recorded in
# /var/lib/safeai/manifest (backed up files restored, created files removed),
# the ACL entries it put on your files and your safeai lists. It asks first
# whether to remove everything (the agent user and the packages safeai installed
# too); if not, which of these, and your rules, stay. The copy you downloaded and
# installed from is yours: it stays, and the last line says where it is.
#
#   sudo /usr/local/lib/safeai/uninstall.sh      asks
#   sudo ./uninstall.sh --yes                    no questions: everything
#   sudo ./uninstall.sh --keep-agent             keep the agent user and its home
#   sudo ./uninstall.sh --keep-rules             keep your rules for a later install
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/var/lib/safeai
MANIFEST=$STATE/manifest
YES=no KEEP_AGENT=no KEEP_PACKAGES=no KEEP_RULES=no
for a in "$@"; do
    case "$a" in --yes) YES=yes ;; --keep-agent) KEEP_AGENT=yes ;; --keep-rules) KEEP_RULES=yes ;;
        *) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 1 ;; esac
done
[ -n "${SAFEAI_ROLLBACK:-}" ] && YES=yes  # a failed install undoes itself
if [ ! -f "$MANIFEST" ]; then
    # an uninstall cut off at its very end (a power cut) leaves only safeai's own folder: it goes last
    if [ -f /usr/local/lib/safeai/VERSION ] && [ -f /usr/local/lib/safeai/uninstall.sh ]; then
        rm -rf /usr/local/lib/safeai && echo "removed /usr/local/lib/safeai, left by an uninstall that was cut off"
    fi
    echo "safeai is not installed ($MANIFEST not found)"; exit 0
fi
AGENT=$(sed -n 's/^AGENT=//p' /etc/safeai.conf 2>/dev/null); AGENT=${AGENT:-aiagent}
OWNER=$(sed -n 's/^OWNER=//p' /etc/safeai.conf 2>/dev/null); OWNER=${OWNER:-${SUDO_USER:-}}
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
has() { grep -q "^$1" "$MANIFEST"; }
LIB_OURS=no; has "created-dir /usr/local/lib/safeai" && LIB_OURS=yes  # it goes last, after the manifest
ours_user() { grep -qx "created-user $AGENT" "$MANIFEST" && getent passwd "$AGENT" >/dev/null; }
Q=$OWNER_HOME/.local/share/safeai-quarantine
PKGS=$(sed -n 's/^installed-package //p' "$MANIFEST" | tr '\n' ' ')
SRC_DIR=$(sed -n 's/^source-dir //p' "$MANIFEST" | tail -1)
t='~'; SRC_SHOWN=${SRC_DIR/#"$OWNER_HOME"/$t}

# ---- messages; the translation installed next to this script (or share/i18n/ru) replaces them
declare -A MSG=(
    [u_full]="Remove safeai completely, with your rules%s? [y/n] (Ctrl+C: cancel): "
    [u_full_agent]=", the agent %s and its logins and chats"
    [u_full_packages]=", the packages %s"
    [u_full_quarantine]=", the agent-made settings it moved out of your projects (%s)"
    [u_yn]="Please answer y or n (Ctrl+C: cancel)."
    [u_choose]="Then choose what stays; the rest is removed (Enter: removed, Ctrl+C: cancel):"
    [u_keep_rules]="  Keep your rules (what is open, read-only, closed) for a later install? [y/N]: "
    [u_keep_agent]="  Keep the agent user %s with its home (its logins, chat history, agent programs)? [y/N]: "
    [u_keep_packages]="  Keep the packages safeai installed (%s)? [y/N]: "
    [u_kept_rules]="Kept your rules in %s: the next install uses them."
    [u_kept_quarantine]="Kept the agent-made settings safeai moved out of your projects: %s"
    [u_save_home]="The agent %s goes with its home %s. Save the home first (its ssh keys, logins, chats, repositories)? [y/n]: "
    [u_save_where]="Where to put the archive (Enter: %s): "
    [u_save_bad]="Cannot put it at %s: give a new file name in a folder of yours."
    [u_saved]="The agent's home is saved in %s (only you can read it)."
    [u_save_failed]="Could not save the agent's home in %s, so the agent user is kept; delete it later: sudo userdel -r %s"
    [u_nothing]="Nothing changed."
    [u_user_deleted]="User %s deleted."
    [u_acl]="Taking safeai's permissions off your files (one pass over your home folder):"
    [u_acl_progress]="%d files checked, %d changed"
    [u_acl_failed]="Some of your files keep safeai's entries (listed above); the rest goes on."
    [u_kept_agent]="Kept: user %s (an ordinary user now; the access safeai gave it is removed). To delete it later: sudo userdel -r %s"
    [u_kept_packages]="Kept packages: %s"
    [u_kept_adopted]="Kept: user %s, as it was before safeai (only the access safeai gave it is removed)."
    [u_copy_left]="The copy you installed from stays in %s; if you no longer need it: rm -rf %s"
    [u_done]="safeai removed. Files the agent made in your folders stay; they are yours."
)
m() { local k=$1; shift; printf "${MSG[$k]}" "$@"; }  # shellcheck disable=SC2059
if [ "$(sed -n 's/^LANG=//p' /etc/safeai.conf 2>/dev/null)" = ru ]; then
    for f in "$HERE/i18n-ru" "$HERE/share/i18n/ru"; do [ -f "$f" ] && { . "$f"; break; }; done
fi
tty_ok() { (: </dev/tty) 2>/dev/null; }
keep() {  # keep KEY ARGS... - true only for an answer y; Enter removes, Ctrl+D cancels everything
    local a=""
    read -r -p "$(m "$@")" a </dev/tty || { echo; m u_nothing; echo; exit 0; }
    case "$a" in [yY]*) true ;; *) false ;; esac
}

if [ "$YES" != yes ]; then
    tty_ok || { m u_nothing; echo; exit 0; }  # nobody to ask
    # first: everything, or a choice of what stays; no default, so a stray Enter removes nothing
    what=""
    ours_user && [ $KEEP_AGENT = no ] && what+=$(m u_full_agent "$AGENT")
    [ -n "$PKGS" ] && what+=$(m u_full_packages "${PKGS% }")
    [ -n "$(find "$Q" -type f -print -quit 2>/dev/null)" ] && what+=$(m u_full_quarantine "${Q/#"$OWNER_HOME"/$t}")
    while :; do
        a=""
        read -r -p "$(m u_full "$what")" a </dev/tty || { echo; m u_nothing; echo; exit 0; }
        case "$a" in [yY]*) full=yes; break ;; [nN]*) full=no; break ;; *) m u_yn; echo ;; esac
    done
    if [ $full = no ]; then
        m u_choose; echo
        [ $KEEP_RULES = no ] && keep u_keep_rules && KEEP_RULES=yes
        if ours_user && [ $KEEP_AGENT = no ]; then keep u_keep_agent "$AGENT" && KEEP_AGENT=yes; fi
        if [ -n "$PKGS" ]; then keep u_keep_packages "${PKGS% }" && KEEP_PACKAGES=yes; fi
    fi
    # the agent's home goes with it: it may hold what is worth keeping. No default here either
    AGENT_HOME=$(getent passwd "$AGENT" | cut -d: -f6)
    if ours_user && [ $KEEP_AGENT = no ] && [ -d "$AGENT_HOME" ]; then
        while :; do
            a=""
            read -r -p "$(m u_save_home "$AGENT" "$AGENT_HOME")" a </dev/tty || { echo; m u_nothing; echo; exit 0; }
            case "$a" in [yY]*) break ;; [nN]*) a=""; break ;; *) m u_yn; echo ;; esac
        done
        if [ -n "$a" ]; then
            def="$OWNER_HOME/$AGENT-home-$(date +%Y-%m-%d).tar.gz"
            while :; do
                where=""
                read -r -p "$(m u_save_where "${def/#"$OWNER_HOME"/$t}")" where </dev/tty || { echo; m u_nothing; echo; exit 0; }
                where=${where:-$def}
                where=${where/#\~/$OWNER_HOME}
                case "$where" in /*) ;; *) where=$OWNER_HOME/$where ;; esac
                [ -d "$where" ] && where=$where/$(basename "$def")
                # a folder of yours (you will own the archive); never inside the home being deleted
                if [ -d "$(dirname "$where")" ] && sudo -u "$OWNER" test -w "$(dirname "$where")" && [ ! -e "$where" ] &&
                    case "$where/" in "$AGENT_HOME"/*) false ;; *) true ;; esac; then
                    SAVE_TO=$where; break
                fi
                m u_save_bad "$where"; echo
            done
        fi
    fi
fi

# once started, it runs to the end: Ctrl+C would only kill a tool half way through (userdel, the package
# manager); run it again to finish if it was stopped some other way
trap '' INT
systemctl disable --now safeai-guard.service safeai-check.timer safeai-ask.socket safeai-web.socket \
    safeai-web.service safeai-keep.socket >/dev/null 2>&1
systemctl stop 'safeai-ask@*.service' 'safeai-web@*.service' 'safeai-keep@*.service' >/dev/null 2>&1
rm -f /run/safeai-keep /run/safeai-keep.lock
# the agent's web rule (safeai-web), and the state it left
has "nft-table " && nft delete table inet safeai 2>/dev/null
rm -f /run/safeai-web /run/safeai-web.lock
# nothing of the agent may keep running while its traces are removed
getent passwd "$AGENT" >/dev/null && pkill -KILL -u "$AGENT" 2>/dev/null
# VS Code back to running Claude Code and Codex as you (also when it was switched on later, in safeai settings);
# if a settings file cannot be changed, say so: VS Code would point at programs that are gone
if [ -x /usr/local/bin/safeai ] && ! out=$(sudo -u "$OWNER" -H /usr/local/bin/safeai _vscode-off 2>&1); then
    printf '%s\n' "$out" >&2
fi

# your files: the ACL entries safeai added, agent ownership marks
if has "acl-user " && getent passwd "$AGENT" >/dev/null && [ -d "$OWNER_HOME" ]; then
    clean=$HERE/safeai-acl-clean
    [ -x "$clean" ] || clean=$HERE/libexec/safeai-acl-clean
    m u_acl; echo
    python3 -I "$clean" "$OWNER" "$AGENT" "${MSG[u_acl_progress]}" || { m u_acl_failed; echo; }
fi

has "apparmor " && [ -e /etc/apparmor.d/safeai-agent ] && apparmor_parser -R /etc/apparmor.d/safeai-agent 2>/dev/null
# the agent's login shell as it was (bash for a user safeai made)
sh_was=$(sed -n 's/^agent-shell //p' "$MANIFEST" | head -1)
case "$sh_was" in ""|"$HERE"/*|/usr/local/lib/safeai/*) sh_was=/bin/bash ;; esac
getent passwd "$AGENT" >/dev/null && [ "$(getent passwd "$AGENT" | cut -d: -f7)" != "$sh_was" ] && usermod -s "$sh_was" "$AGENT"

# system files: restore what was modified, remove what was created (newest first)
# files are put back whole, as the installer writes them: written next to the target, synced, renamed
tmp_of() { echo "$(dirname "$1")/.$(basename "$1").safeai-new"; }
tac "$MANIFEST" | while read -r kind a b c; do
    case "$kind" in modified-file|created-file) rm -f "$(tmp_of "$a")" ;; esac  # left by a run that was cut off
    case "$kind" in
        modified-file) [ -e "$b" ] && cp -a "$b" "$(tmp_of "$a")" && sync "$(tmp_of "$a")" && mv -f "$(tmp_of "$a")" "$a" ;;
        created-file) rm -f "$a" ;;
        created-dir) rmdir "$a" 2>/dev/null ;;
        audit-log-dir) chgrp "$b" "$a" 2>/dev/null; chmod "$c" "$a" 2>/dev/null ;;
    esac
done
for d in /etc/systemd/system/user@*.service.d; do rmdir "$d" 2>/dev/null; done
# the login screen as it was (an agent user kept is an ordinary user again)
grep -q "^\(created\|modified\)-file /var/lib/AccountsService/users/" "$MANIFEST" &&
    systemctl try-restart accounts-daemon.service >/dev/null 2>&1
# Files keeps a removed extension loaded until it restarts
if grep -q "^created-file .*/safeai_nautilus.py$" "$MANIFEST" && pgrep -u "$OWNER" -x nautilus >/dev/null; then
    u=$(id -u "$OWNER")
    sudo -u "$OWNER" -H env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$u/bus" XDG_RUNTIME_DIR="/run/user/$u" \
        nautilus -q >/dev/null 2>&1
fi
# your icon cache (when a program made one) without the emblems
h=$OWNER_HOME/.local/share/icons/hicolor
if grep -qF "created-file $h/" "$MANIFEST" && [ -f "$h/icon-theme.cache" ]; then
    u=$(command -v gtk-update-icon-cache || command -v gtk4-update-icon-cache || true)
    [ -n "$u" ] && sudo -u "$OWNER" -H "$u" -q -f -t "$h" 2>/dev/null
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
if [ $KEEP_PACKAGES = no ]; then  # a package manager stopped half way before: let it finish first
    command -v dpkg >/dev/null && dpkg --configure -a >/dev/null 2>&1
    command -v pacman >/dev/null && ! pgrep -x pacman >/dev/null && rm -f /var/lib/pacman/db.lck
fi
[ $KEEP_PACKAGES = yes ] || for p in $(sed -n 's/^installed-package //p' "$MANIFEST" | tac); do  # dependencies too
    # with its configuration files: they were not there before either
    if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "$p" >/dev/null 2>&1
    elif command -v dnf >/dev/null; then dnf remove -y -q "$p" >/dev/null 2>&1
    elif command -v pacman >/dev/null; then pacman -Rn --noconfirm "$p" >/dev/null 2>&1
    fi
done

# your safeai lists and quarantine (a failed update keeps the lists you already had)
if [ -n "$OWNER_HOME" ] && { [ -z "${SAFEAI_ROLLBACK:-}" ] || has "created-lists "; }; then
    if [ $KEEP_RULES = yes ] && [ -d "$OWNER_HOME/.config/safeai" ]; then  # the rules only, for the next install
        find "$OWNER_HOME/.config/safeai" -mindepth 1 -maxdepth 1 ! -name write-dirs ! -name read-only ! -name closed \
            ! -name env-open ! -name mode ! -name proxy -exec rm -rf {} +
        m u_kept_rules "$OWNER_HOME/.config/safeai"; echo
        # what it moved out of your projects stays with your rules
        if [ -n "$(find "$Q" -type f -print -quit 2>/dev/null)" ]; then m u_kept_quarantine "${Q/#"$OWNER_HOME"/$t}"; echo
        else rm -rf "$Q"; fi
    else
        rm -rf "$OWNER_HOME/.config/safeai" "$Q"
    fi
fi

# folders safeai created in your home, if nothing else is in them now (deepest first)
tac "$MANIFEST" | sed -n "s|^created-dir \($OWNER_HOME/.*\)|\1|p" | while read -r d; do rmdir "$d" 2>/dev/null; done
# a package removed above whose service was enabled: its link left behind (a power cut while it was being
# installed can leave the package manager unaware of it) points nowhere now
[ $KEEP_PACKAGES = yes ] || for p in $(sed -n 's/^installed-package //p' "$MANIFEST"); do
    find /etc/systemd/system -xdev -type l -name "$p.service" ! -exec test -e {} \; -delete 2>/dev/null
done
tac "$MANIFEST" | sed -n "s|^created-dir \(/usr/local/share/.*\)|\1|p" | while read -r d; do rmdir "$d" 2>/dev/null; done

# the agent user: its home, its leftovers in temporary folders
# (a failed install deletes it only if that install created it)
if [ -n "${SAFEAI_ROLLBACK:-}" ]; then [ "${SAFEAI_NEW_USER:-}" = yes ] || KEEP_AGENT=yes; fi
if ours_user && [ $KEEP_AGENT = no ]; then
    if [ -n "${SAVE_TO:-}" ]; then  # first its home, into an archive only you can read
        h=$(getent passwd "$AGENT" | cut -d: -f6)
        if tar --warning=no-file-ignored -C "$(dirname "$h")" -czf "$SAVE_TO.part" "$(basename "$h")" 2>/dev/null; then
            chown "$OWNER": "$SAVE_TO.part" && chmod 600 "$SAVE_TO.part" && sync "$SAVE_TO.part" &&
                mv "$SAVE_TO.part" "$SAVE_TO" && { m u_saved "$SAVE_TO"; echo; }
        else
            rm -f "$SAVE_TO.part"; m u_save_failed "$SAVE_TO" "$AGENT"; echo
            KEEP_AGENT=yes  # not deleted: nothing of it is lost
        fi
    fi
fi
if ours_user && [ $KEEP_AGENT = no ]; then
    u=$(id -u "$AGENT")
    for t in /tmp /var/tmp /dev/shm; do find "$t" -xdev -depth -uid "$u" -delete 2>/dev/null; done
    userdel -r "$AGENT" 2>/dev/null
    getent group "$AGENT" >/dev/null && groupdel "$AGENT" 2>/dev/null
    m u_user_deleted "$AGENT"; echo
    keep=""
elif has "created-user $AGENT" && ! getent passwd "$AGENT" >/dev/null && [ $KEEP_AGENT = no ]; then
    # a run cut off half way through deleting the user: its group and home may be left
    getent group "$AGENT" >/dev/null && [ -z "$(getent group "$AGENT" | cut -d: -f4)" ] && groupdel "$AGENT" 2>/dev/null
    h=$(sed -n 's/^agent-home //p' "$MANIFEST" | head -1)
    [ -n "$h" ] && [ -d "$h" ] && ! cut -d: -f6 /etc/passwd | grep -qx "$h" && rm -rf "$h"
    keep=""
else
    keep=$(grep -x "created-user $AGENT" "$MANIFEST" || true)  # still ours, for a later install
    [ -n "$keep" ] && [ -z "${SAFEAI_ROLLBACK:-}" ] && { m u_kept_agent "$AGENT" "$AGENT"; echo; }
    has "adopted-user $AGENT" && { m u_kept_adopted "$AGENT"; echo; }
    # the agent stays: take safeai's hook out of its Claude Code settings and safeai's notes out of
    # its instructions (its own settings and instructions stay)
    home=$(getent passwd "$AGENT" | cut -d: -f6)
    [ -n "$home" ] && runuser -u "$AGENT" -- env HOME="$home" python3 -I -c '
import json, os, sys
p = os.path.expanduser("~/.claude/settings.json")
try:
    d = json.load(open(p))
except (OSError, ValueError):
    sys.exit(0)
e = d.get("hooks", {}).get("PostToolUseFailure", [])
keep = [x for x in e if not any(h.get("command") == sys.argv[1] for h in x.get("hooks", []))]
if keep != e:
    if keep:
        d["hooks"]["PostToolUseFailure"] = keep
    else:
        del d["hooks"]["PostToolUseFailure"]
        if not d["hooks"]:
            del d["hooks"]
    with open(p + ".safeai.tmp", "w") as f:
        json.dump(d, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(p + ".safeai.tmp", p)
' /usr/local/lib/safeai/safeai-explain 2>/dev/null
    [ -n "$home" ] && runuser -u "$AGENT" -- env HOME="$home" python3 -I -c '
import os, re
home = os.path.expanduser("~")
def write(p, data):
    with open(p + ".safeai.tmp", "w") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(p + ".safeai.tmp", p)
p = home + "/.claude/CLAUDE.md"
if os.path.isfile(p) and not os.path.islink(p):
    old = open(p).read()
    new = re.sub(r"\A@~/\.claude/safeai\.md\n\n?", "", old)
    new = "\n".join(l for l in new.split("\n") if l != "@~/.claude/safeai.md")
    if new != old:
        os.remove(p) if not new.strip() else write(p, new)
p = home + "/.codex/AGENTS.md"
if os.path.isfile(p) and not os.path.islink(p):
    old = open(p).read()
    new = re.sub(r"<!-- safeai: start -->.*?<!-- safeai: end -->\n\n?", "", old, flags=re.S)
    if new != old:
        os.remove(p) if not new.strip() else write(p, new)
if os.path.isfile(home + "/.claude/safeai.md"):
    os.remove(home + "/.claude/safeai.md")
' 2>/dev/null
fi

rm -rf "$STATE/backup" "$STATE/before-update"
rm -f "$OWNER_HOME/.safeai-acl-test"  # the installer's probe, if a run was cut off right there
# your session's safeai state: the chat switch, the windows, whose each chat is, the launcher's log,
# the agent's recent questions, chat marks (and their temporary files)
if u=$(id -u "$OWNER" 2>/dev/null); then
    for f in safeai-me safeai-windows safeai-chats-who safeai-launches safeai-who.lock safeai-asked.json; do
        rm -f "/run/user/$u/$f" "/run/user/$u/$f.tmp"
    done
    rm -rf "/run/user/$u/safeai-marked"
fi
if [ -n "$keep" ]; then echo "$keep" >"$MANIFEST"; else rm -f "$MANIFEST"; rmdir "$STATE" 2>/dev/null; fi
# safeai's own folder last, this script with it: a power cut before here leaves the manifest, so running
# uninstall again finishes; after here, nothing but this folder (see the start)
if [ $LIB_OURS = yes ] || { [ -f /usr/local/lib/safeai/VERSION ] && [ -f /usr/local/lib/safeai/uninstall.sh ]; }; then
    rm -rf /usr/local/lib/safeai
fi
sync
# the copy you downloaded and installed from is yours, with whatever you changed in it: it stays
if [ -z "${SAFEAI_ROLLBACK:-}" ] && [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/install.sh" ]; then
    m u_copy_left "$SRC_SHOWN" "$SRC_SHOWN"; echo
fi
m u_done; echo
