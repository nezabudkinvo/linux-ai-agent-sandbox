#!/bin/bash
# End-to-end check of an installed safeai: tries, as the agent, to reach what must
# be closed and to do normal work. Run as yourself (no sudo). Exit code 1 = failures.
# It opens a scratch folder in your home for the agent and removes it at the end.
set -uo pipefail
AGENT=$(sed -n 's/^AGENT=//p' /etc/safeai.conf 2>/dev/null); AGENT=${AGENT:-aiagent}
AG="sudo -n -u $AGENT -H"
H=$HOME
LIB=/usr/local/lib/safeai
fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
skip() { printf '  skip  %s\n' "$1"; }
# deny WHAT CMD - the agent's command must fail and must not print the mark
deny() {
    local what=$1 out; shift
    if out=$($AG sh -c "$*" 2>/dev/null) && [ -n "$out" ]; then bad "$what"; else
        case "$out" in *SAFEAI-MARK*) bad "$what" ;; *) ok "$what" ;; esac
    fi
}
allow() {
    local what=$1; shift
    if $AG sh -c "$*" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

[ "$(id -un)" != "$AGENT" ] || { echo "run as yourself"; exit 1; }
mode=$(cat "$H/.config/safeai/mode" 2>/dev/null || echo strict)
# a scratch folder opened for the agent, removed at the end
work=$H/safeai-check-work-$$
mkdir "$work"
safeai open "$work" >/dev/null

echo "Agent user:"
id -nG "$AGENT" | tr ' ' '\n' | grep -qvx "$AGENT" && bad "$AGENT is in other groups" || ok "$AGENT has only its own group"
$AG sudo -n true 2>/dev/null && bad "$AGENT has sudo" || ok "$AGENT has no sudo"

echo "Closed:"
[ -d "$H/.ssh" ] && deny "~/.ssh" "ls $H/.ssh"
while read -r p; do
    [ -n "$p" ] && [ -e "$p" ] && deny "${p#$H/}" "cat '$p' 2>/dev/null || ls '$p'"
done < <(grep -v '^#' "$H/.config/safeai/closed" 2>/dev/null)

t=$work/.safeai-check-$$
mkdir "$t" || exit 1
echo "New .env files:"
printf 'SECRET=SAFEAI-MARK\n' >"$t/.env"
sleep 1
deny "a .env just created" "cat '$t/.env'"
printf 'X=SAFEAI-MARK\n' >"$t/app.tmp" && mv "$t/app.tmp" "$t/prod.env"
sleep 1
deny "a file renamed to *.env" "cat '$t/prod.env'"

echo "AppArmor:"
if [ -e /etc/apparmor.d/safeai-agent ]; then
    SH="$AG $LIB/safeai-shell"
    case "$($SH -c 'cat /proc/self/attr/current' 2>/dev/null)" in
        safeai-agent*) ok "agent login shell runs in the profile" ;;
        *) bad "agent login shell is not confined" ;;
    esac
    printf 'X=SAFEAI-MARK\n' >"$t/race.env"
    case "$($SH -c "cat '$t/race.env'" 2>/dev/null)" in
        *SAFEAI-MARK*) bad "a new .env is readable at once" ;; *) ok "a new .env is refused at open time" ;;
    esac
    [ "$($SH -c 'd=$(mktemp -d) && echo A=1 >$d/.env && cat $d/.env; rm -f $d/.env; rmdir $d' 2>/dev/null)" = A=1 ] \
        && ok "own .env in /tmp works (tests)" || bad "own .env in /tmp does not work"
else
    skip "profile not installed"
fi

echo "Read-only:"
deny "write to ~" "touch $H/.safeai-probe && echo SAFEAI-MARK"
g=$(find "$work" -maxdepth 3 -name .git -type d 2>/dev/null | head -1)
if [ -n "$g" ]; then
    deny "write to .git/hooks" "touch '$g/hooks/.safeai-probe' && echo SAFEAI-MARK"
    deny "write to .git/config" "echo >> '$g/config' && echo SAFEAI-MARK"
fi
# a repository you create now, in an open folder: made by hand (your git must never run
# where the agent can write). The whole .git must be read-only to the agent, so it cannot
# replace config/hooks by renaming them aside through a writable .git.
mkdir -p "$t/repo/.git/hooks" "$t/repo/.git/modules/m/hooks" && : >"$t/repo/.git/config" && sleep 1
deny "cannot write a new repo's .git/config" "echo x >> '$t/repo/.git/config' && echo SAFEAI-MARK"
deny "cannot rename a new repo's .git/config aside" "mv '$t/repo/.git/config' '$t/repo/.git/c2' && echo SAFEAI-MARK"
deny "cannot create files in a new repo's .git" "touch '$t/repo/.git/evil' && echo SAFEAI-MARK"
deny "cannot write a new repo's submodule hook" "echo x > '$t/repo/.git/modules/m/hooks/post-checkout' && echo SAFEAI-MARK"
# config the agent authors (a place that runs code as you) is quarantined by the periodic check
$AG sh -c "mkdir -p '$t/proj/.vscode' && echo x > '$t/proj/.vscode/tasks.json' && echo x > '$t/proj/.claude'" 2>/dev/null
safeai check --fix >/dev/null 2>&1
[ -e "$t/proj/.vscode" ] && bad "agent-made .vscode is not quarantined" || ok "agent-made .vscode is quarantined"
[ -e "$t/proj/.claude" ] && bad "agent-made .claude is not quarantined" || ok "agent-made .claude is quarantined"
# ...but in a repository the agent created itself they are its project's files and stay
$AG sh -c "mkdir -p '$t/own/.vscode' && git init -q '$t/own' && echo x > '$t/own/.vscode/settings.json'" 2>/dev/null
safeai check --fix >/dev/null 2>&1
if ! command -v git >/dev/null; then skip "git missing: agent's own repository"
elif [ -e "$t/own/.vscode/settings.json" ]; then ok "the agent's own repository keeps its .vscode"
else bad "the agent's own repository lost its .vscode"; fi

echo "New folders ($mode mode):"
n=$H/safeai-newdir-$$
mkdir "$n"
sleep 3
if [ "$mode" = strict ]; then
    deny "a new folder in ~ is closed" "ls '$n' && echo SAFEAI-MARK"
    deny "~ cannot be listed" "ls $H && echo SAFEAI-MARK"
else
    allow "a new folder in ~ is open at once" "touch '$n/x' && rm '$n/x'"
fi
rmdir "$n"

echo "Normal work:"
allow "create and read a file in an open folder" "echo hi > '$t/a.txt' && cat '$t/a.txt'"
sleep 1
[ -O "$t/a.txt" ] && ok "agent's file belongs to you" || bad "agent's file still belongs to the agent"
echo x >>"$t/a.txt" 2>/dev/null && ok "you can edit the agent's file" || bad "you cannot edit the agent's file"

echo "Closed folders leave no agent access behind:"
cdir=$work/.safeai-closed-$$
mkdir "$cdir" && safeai open "$cdir" >/dev/null 2>&1 && safeai close "$cdir" >/dev/null 2>&1
touch "$cdir/inside" 2>/dev/null
if getfacl -p "$cdir" 2>/dev/null | grep -q "default:user:$AGENT:[^-]"; then bad "closed folder keeps an agent default ACL"; else ok "closed folder has no agent default ACL"; fi
deny "new file in a reopened-then-closed folder stays unreadable" "cat '$cdir/inside' && echo SAFEAI-MARK"
rm -f "$cdir/inside"; safeai open "$cdir" >/dev/null 2>&1; safeai close "$cdir" >/dev/null 2>&1
rmdir "$cdir" 2>/dev/null; safeai check --fix >/dev/null 2>&1

echo "Running the agent:"
[ "$(cd "$work" && echo 'id -un' | safeai 2>/dev/null | tail -1)" = "$AGENT" ] && ok "safeai opens the agent's shell" \
    || bad "safeai does not open the agent's shell"
[ "$(cd "$work" && $LIB/safeai-run id -un 2>/dev/null)" = "$AGENT" ] && ok "editor launcher runs the agent" \
    || bad "editor launcher does not run the agent"
c=$H/safeai-check-closed-$$
mkdir "$c" && safeai close "$c" >/dev/null
out=$(cd "$c" && $LIB/safeai-run id -un 2>/dev/null)
[ -z "$out" ] && ok "editor launcher refuses a closed folder (never runs you instead)" \
    || bad "editor launcher ran in a closed folder as: $out"
[ "$(cd "$c" && safeai </dev/null 2>/dev/null)" = "" ] && ok "safeai does not open a folder without your yes" \
    || bad "safeai opened a folder without asking"
rmdir "$c"
if [ -e /etc/apparmor.d/safeai-agent ]; then
    case "$(cd "$work" && echo 'cat /proc/self/attr/current' | safeai 2>/dev/null | tail -1)" in
        safeai-agent*) ok "the agent runs in the AppArmor profile" ;; *) bad "the agent is not confined" ;;
    esac
fi

echo "Audit log:"
if [ -r /var/log/audit/audit.log ]; then
    safeai log 1 | grep -q "safeai-check-$$/.env" && ok "refusal shows up in safeai log" || bad "safeai log misses the refusal"
else
    skip "audit log not installed"
fi

echo "Services:"
for u in safeai-guard.service safeai-check.timer; do
    [ "$(systemctl is-active "$u")" = active ] && ok "$u" || bad "$u is not active"
done
safeai check >/dev/null && ok "safeai check: all good" || bad "safeai check found problems"

find "$t/repo" -mindepth 1 -delete 2>/dev/null; rmdir "$t/repo" 2>/dev/null
find "$t/proj" -mindepth 1 -delete 2>/dev/null; rmdir "$t/proj" 2>/dev/null
sudo -n -u "$AGENT" find "$t/own" -mindepth 1 -delete 2>/dev/null; rmdir "$t/own" 2>/dev/null
rm -f "$t/.env" "$t/prod.env" "$t/a.txt" "$t/race.env"
rmdir "$t"
rmdir "$work"
safeai check --fix >/dev/null  # forgets the removed scratch folders
[ $fail = 0 ] && echo "All checks passed" || echo "Some checks failed"
exit $fail
