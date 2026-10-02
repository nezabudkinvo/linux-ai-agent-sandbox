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
# what this check tries as the agent is refused on purpose: safeai log leaves this run out. Its time is
# recorded at the end (also when it stops early), so the log checks below still see it.
t0=$(date +%s) ST=$H/.config/safeai/self-tests
ran() { { tail -n 49 "$ST" 2>/dev/null; echo "$t0 $(date +%s)"; } >"$ST.new" && mv "$ST.new" "$ST"; trap - EXIT; }
trap ran EXIT

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

echo "New secret stores:"
# made after the install (aws configure, gh auth login, a copied .npmrc...): closed at once, in both modes.
# Two that are rarely there; one you have is left alone.
for rel in .vnc .config/gcloud; do
    p=$H/$rel
    if [ -e "$p" ] || [ ! -d "$(dirname "$p")" ]; then skip "~/$rel is there already: a store made later"; continue; fi
    mkdir "$p" && chmod 755 "$p" && printf 'SAFEAI-MARK\n' >"$p/creds" && chmod 644 "$p/creds"
    sleep 1
    deny "a secret store made after the install (~/$rel), at once" "cat '$p/creds'"
    safeai check --fix >/dev/null 2>&1
    grep -qx "$p" "$H/.config/safeai/closed" && ok "...and safeai check lists it as closed" \
        || bad "safeai check does not list a new secret store (~/$rel) as closed"
    rm -f "$p/creds"; rmdir "$p"
done
a=$(sed -n '/^SECRETS = (/,/)$/p' /usr/local/bin/safeai); b=$(sed -n '/^SECRETS = (/,/)$/p' "$LIB/safeai-guard")
[ -n "$a" ] && [ "$a" = "$b" ] && ok "the guard knows the same secret stores as safeai" \
    || bad "the guard's list of secret stores differs from safeai's"

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
    # in the agent's own home, where only the profile stands in the way (no guard, its own files)
    case "$($SH -c 'echo X=SAFEAI-MARK >~/.env.preview; cat ~/.env.preview; rm -f ~/.env.preview' 2>/dev/null)" in
        *SAFEAI-MARK*) bad "a .env.preview is not refused by the profile" ;; *) ok "every .env.NAME is refused at open time" ;;
    esac
    [ "$($SH -c 'echo X=sample >~/.env.example && cat ~/.env.example; rm -f ~/.env.example' 2>/dev/null)" = X=sample ] \
        && ok "a sample (.env.example) stays readable" || bad "a sample (.env.example) is refused"
    case "$(safeai open "$t/.env" </dev/null 2>&1)" in *AppArmor*) ok "opening a .env says the profile still refuses it" ;;
        *) bad "opening a .env pretends the agent gets it" ;; esac
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
if [ -e /etc/apparmor.d/safeai-agent ]; then  # the profile: no .git of the agent's in your home
    SH="$AG $LIB/safeai-shell"
    [ -z "$($SH -c "mv '$t/repo/.git' '$t/repo/.g' && echo SAFEAI-MARK" 2>/dev/null)" ] \
        && ok "cannot rename a repository's .git aside" || { bad "renamed a repository's .git aside"; mv "$t/repo/.g" "$t/repo/.git"; }
    [ -z "$($SH -c "mkdir -p '$t/new' && { mkdir '$t/new/.git' || : > '$t/new/.git'; } 2>/dev/null && echo SAFEAI-MARK" 2>/dev/null)" ] \
        && ok "cannot create a repository in your home" || bad "created a .git in your home"
fi
# config the agent authors (a place that runs code as you) is quarantined by the periodic check
$AG sh -c "mkdir -p '$t/proj/.vscode' && echo x > '$t/proj/.vscode/tasks.json' && echo x > '$t/proj/.claude'" 2>/dev/null
safeai check --fix >/dev/null 2>&1
[ -e "$t/proj/.vscode" ] && bad "agent-made .vscode is not quarantined" || ok "agent-made .vscode is quarantined"
[ -e "$t/proj/.claude" ] && bad "agent-made .claude is not quarantined" || ok "agent-made .claude is quarantined"
safeai status | grep -q "Moved out of your projects" && ok "...and safeai status says so" \
    || bad "safeai status does not mention what was moved out of your projects"
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
    f=$H/.safeai-newfile-$$; printf 'SAFEAI-MARK\n' >"$f"; chmod 644 "$f"; sleep 0.5
    deny "a new file in ~ is closed at once" "cat '$f'"; rm -f "$f"
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
[ "$(cd "$work" && safeai id -un </dev/null 2>/dev/null)" = "$AGENT" ] && ok "safeai PROGRAM runs it as the agent" \
    || bad "safeai PROGRAM does not run it as the agent"
case "$(c=$H/safeai-check-typo-$$; mkdir "$c"; safeai close "$c" >/dev/null; cd "$c" && safeai opne x </dev/null 2>&1;
        cd "$H"; rmdir "$c")" in
    *"neither a safeai command"*) ok "a mistyped command stops before anything is opened" ;;
    *) bad "a mistyped command is not stopped" ;;
esac
case "$(cd "$work" && safeai claude </dev/null 2>&1)" in
    *"not installed for the agent"*|*"$AGENT"*) ok "safeai claude: runs it, or says how to install it" ;;
    *) bad "safeai claude: neither runs it nor says how to install it" ;;
esac
if [ -n "${SAFEAI_TEST_VM:-}" ]; then  # a throwaway machine: stop the guard for a moment
    sudo -n systemctl stop safeai-guard
    [ -z "$(cd "$work" && safeai id -un </dev/null 2>/dev/null)$(cd "$work" && $LIB/safeai-run id -un 2>/dev/null)" ] \
        && ok "the agent does not start while the guard service is down" || bad "the agent started without the guard"
    sudo -n systemctl start safeai-guard
fi

echo "Who runs a VS Code chat:"
# a stand-in for the claude binary of the extension: who runs it, with what
fake=$work/claude
printf '#!/bin/sh\necho "$(id -un) $*"\n' >"$fake" && chmod 755 "$fake"
ro=$H/safeai-check-ro-$$
mkdir "$ro" && safeai read "$ro" >/dev/null
me=/run/user/$(id -u)/safeai-me
had_me=$(cat "$me" 2>/dev/null)
chat() {  # no desktop for it: a question would wait on your screen
    (cd "$1" && shift && env -u DISPLAY -u WAYLAND_DISPLAY SAFEAI_HOME="$fh" $LIB/safeai-run "$fake" \
        --output-format stream-json "$@" </dev/null 2>/dev/null)
}
fh=$t/home  # a stand-in for your ~/.claude: chats made up for these checks
mkdir -p "$fh/.claude/projects/-check-you" "$fh/.config/safeai"
yours=11111111-1111-4111-8111-$(printf '%012d' $$)
theirs=22222222-2222-4222-8222-$(printf '%012d' $$)
echo '{"mine":1}' >"$fh/.claude/projects/-check-you/$yours.jsonl"
$AG sh -c "mkdir -p ~/.claude/projects/-safeai-check-$$ && echo '{\"agent\":1}' >~/.claude/projects/-safeai-check-$$/$theirs.jsonl &&
    echo '{\"agent\":2}' >~/.claude/projects/-safeai-check-$$/$yours.jsonl" 2>/dev/null
mkdir -p "$fh/.config/Code/User" && SAFEAI_HOME="$fh" safeai settings set vscode on >/dev/null 2>&1  # the switch is for it
fakecodex=$work/codex; cp "$fake" "$fakecodex"
codexchat() { (cd "$1" && env -u DISPLAY -u WAYLAND_DISPLAY SAFEAI_HOME="$fh" $LIB/safeai-run "$fakecodex" app-server </dev/null 2>/dev/null); }
helper() { (cd "$1" && env -u DISPLAY -u WAYLAND_DISPLAY SAFEAI_HOME="$fh" $LIB/safeai-run "$fake" \
    --output-format stream-json --no-session-persistence </dev/null 2>/dev/null); }
switch() { SAFEAI_HOME="$fh" safeai _who "$@"; }
switch agent "$ro" "$work"
case "$(chat "$ro")" in "$AGENT "*) ok "a new chat runs as the agent" ;; *) bad "a new chat does not run as the agent" ;; esac
case "$(chat "$work")" in "$AGENT "*) ok "...where it can write too, without a question" ;; *) bad "an agent chat asked or failed in an open folder" ;; esac
[ -z "$(chat "$fh")" ] && ok "...not in your home folder itself (it would take your settings)" \
    || bad "a chat as the agent started in your home folder itself"
switch me "$ro"
case "$(chat "$ro")" in "$(id -un) "*--settings*safeai-owner-mark*) ok "a window switched to me: a new chat runs as you, marked" ;;
    *) bad "a window switched to me: a new chat does not run as you (marked)" ;; esac
case "$(chat "$ro")|$(codexchat "$ro")|$(chat "$work")" in "$(id -un) "*"|$(id -un) "*"|$AGENT "*) ok "...every chat there, Codex too; another window stays the agent's" ;;
    *) bad "the switch of one window did not hold, or leaked into another" ;; esac
# Codex starts in your home, not in the project: its window, as the extension tells it, decides
where=$work/codex-where; printf '#!/bin/sh\necho "$(id -un) $(pwd)"\n' >"$where" && chmod 755 "$where"
codexhome() { (cd "$fh" && env -u DISPLAY -u WAYLAND_DISPLAY SAFEAI_HOME="$fh" $LIB/safeai-run "$where" app-server </dev/null 2>/dev/null); }
case "$(codexhome)" in "$AGENT /tmp") ok "Codex started in your home runs as the agent, without a question" ;;
    *) bad "Codex started in your home was refused or ran wrong: $(codexhome)" ;; esac
case "$(SAFEAI_HOME="$fh" safeai _window "$ro"; codexhome; :)" in "$(id -un) $ro") ok "...in a window switched to me: as you, in the window's folder" ;;
    *) bad "Codex did not follow its window" ;; esac
case "$(cd "$ro" && env -u DISPLAY -u WAYLAND_DISPLAY SAFEAI_HOME="$fh" $LIB/safeai-run "$fake" --version </dev/null 2>/dev/null)" in
    "$AGENT "*) ok "a quick call of the extension runs as the agent" ;; *) bad "a quick call of the extension did not run" ;; esac
case "$(chat "$ro" --resume="$theirs")" in "$AGENT "*) ok "the agent's chat continues as the agent, even in a window switched to me" ;;
    *) bad "the agent's chat continued as you" ;; esac
switch me "$work"
sid=33333333-3333-4333-8333-$(printf '%012d' $$)
case "$(helper "$work")|$(chat "$work" --session-id="$sid")" in "$AGENT "*"|$(id -un) "*) ok "...also where the agent writes; a background query of the extension stays the agent's" ;;
    *) bad "a chat as you where the agent writes, or a background query" ;; esac
switch agent "$work"
case "$(chat "$work" --resume="$sid")|$(chat "$work")" in "$(id -un) "*"|$AGENT "*) ok "a chat stays whose it was when restarted, the switch moves only new ones" ;;
    *) bad "a chat changed hands on a restart" ;; esac
mkdir -p "$work/subwin"; switch me "$work"  # the switch is by the exact folder, not a path above or below
case "$(chat "$work/subwin")" in "$AGENT "*) ok "a chat in a subfolder does not inherit a parent window's me" ;;
    *) bad "me leaked from a parent folder into a subfolder" ;; esac
switch agent "$work"; rmdir "$work/subwin"
pj=$work/planted-$$; mkdir -p "$pj/own" && safeai open "$pj" >/dev/null  # the agent's settings, made while open
$AG sh -c "mkdir -p '$pj/.claude' && echo '{}' >'$pj/.claude/settings.json'" 2>/dev/null
command -v git >/dev/null && $AG sh -c "cd '$pj/own' && git init -q && mkdir .claude && echo '{}' >.claude/settings.json" 2>/dev/null
switch me "$pj"
[ -z "$(chat "$pj")" ] && ok "a chat as you does not start next to settings the agent made (they would run as you)" \
    || bad "a chat as you started next to settings the agent made"
safeai read "$pj" >/dev/null
[ ! -e "$pj/.claude/settings.json" ] && ok "read-only: settings the agent made there are moved aside" \
    || bad "read-only kept settings the agent made"
if command -v git >/dev/null; then
    switch me "$pj/own"  # the switch is by exact folder: set it on the repo itself
    [ -z "$(chat "$pj/own")" ] && ok "...and in its own repository, where they stay, a chat as you does not start" \
        || bad "a chat as you started in the agent's own repository"
    switch agent "$pj/own"
else skip "git missing: a chat as you in the agent's own repository"; fi
switch agent "$ro" "$pj"
case "$(switch "$ro")|$(chat "$ro")" in "agent|$AGENT "*) ok "...and back to the agent" ;; *) bad "the switch back to the agent" ;; esac
rm -f "$fakecodex" "$where"
switch me "$ro" && SAFEAI_HOME="$fh" safeai settings set vscode off >/dev/null 2>&1
[ ! -e "/run/user/$(id -u)/safeai-me" ] && ok "switching VS Code off drops the switch" || bad "the switch outlives VS Code off"
case "$(switch me "$ro" 2>&1)" in *"every chat is yours already"*) ok "...and with VS Code not through safeai, the switch says so and sets nothing" ;;
    *) bad "the switch with VS Code not through safeai" ;; esac
[ ! -e "/run/user/$(id -u)/safeai-me" ] || bad "the switch left a hidden mark with VS Code not through safeai"
case "$(chat "$work" --resume="$yours")" in "$(id -un) "*) ok "your chat continues as you, without a question where the agent writes" ;;
    *) bad "your chat did not continue where the agent writes" ;; esac
case "$(chat "$ro" --resume="$yours")" in "$(id -un) "*) ok "your chat continues as you" ;;
    *) bad "your chat did not continue as you" ;; esac
[ -n "$had_me" ] && printf '%s\n' "$had_me" >"$me"
out=$(echo '{"hook_event_name":"SessionStart","session_id":"check"}' | $LIB/safeai-owner-mark)
case "$out" in *systemMessage*) ok "a chat as you is marked as yours" ;; *) bad "a chat as you is not marked" ;; esac
prompt='{"hook_event_name":"UserPromptSubmit","session_id":"check"}'
mymark=$(echo "$prompt" | $LIB/safeai-owner-mark)$(echo "$prompt" | $LIB/safeai-owner-mark)
agentmark=$(echo "$prompt" | $AG $LIB/safeai-owner-mark 2>/dev/null)
case "$mymark|$agentmark" in *"line [safeai:"*"line [safeai:"*"|"*"line [safeai:"*) [ "${mymark%%]*}" != "${agentmark%%]*}" ] \
        && ok "every reply begins with whose chat it is (yours, the agent's)" || bad "your chats and the agent's carry the same mark" ;;
    *) bad "a reply is not marked with whose chat it is" ;; esac
$AG sh -c 'grep -q safeai-owner-mark ~/.claude/settings.json && grep -qF "[safeai:" ~/.codex/AGENTS.md' 2>/dev/null \
    && ok "...set up for the agent's Claude Code and Codex" || bad "the agent's chats are not set up to show whose they are"

echo "Environment the agent gets:"
out=$(cd "$work" && DATABASE_URL=postgres://u:SAFEAI-MARK@db FOO_TOKEN=SAFEAI-MARK https_proxy=http://u:SAFEAI-MARK@p:3128 \
      http_proxy=http://proxy:3128 LANG=C.UTF-8 $LIB/safeai-run --agent env 2>/dev/null)
case "$out" in *SAFEAI-MARK*) bad "your secrets reach the agent through the environment" ;;
    *) ok "connection strings, tokens and proxy logins stay yours" ;; esac
case "$out" in *http_proxy=http://proxy:3128*LANG=C.UTF-8*|*LANG=C.UTF-8*http_proxy=http://proxy:3128*)
        ok "language and a proxy without a login pass" ;; *) bad "language or proxy did not pass" ;; esac
ah=$(getent passwd "$AGENT" | cut -d: -f6)
case "$(cd "$work" && $LIB/safeai-run --agent sh -c 'echo "$HOME|$PATH"' </dev/null 2>/dev/null)" in
    "$ah|$ah/.local/bin:"*) ok "the agent gets its own home, its own programs first" ;;
    *) bad "the agent does not get its home (HOME, PATH)" ;; esac
[ "$(cd "$work" && $LIB/safeai-run --agent bash -lic 'declare -F command_not_found_handle >/dev/null && home && pwd' \
    </dev/null 2>/dev/null)" = "$H" ] && ok "the agent's terminal: install hints, home goes to your home folder" \
    || bad "the agent's terminal does not load safeai's part (~/.bashrc)"
case "$(cd "$H" && safeai claude </dev/null 2>&1)" in
    *"project folder"*|*"folder inside your home"*) ok "an AI tool does not start in your home folder itself (it would take your settings)" ;;
    *) bad "an AI tool starts in your home folder itself" ;; esac
if [ -n "${SAFEAI_TEST_VM:-}" ]; then  # root's file in an open folder (a sudo make install leaves such)
    rf=$work/root-owned-$$; sudo -n sh -c "echo x >'$rf'"
    case "$(safeai setup 2>&1)" in
        *"errors)"*) bad "a file of root in an open folder counts as an error" ;;
        *"belong to another user (root)"*) ok "files of another user in your folders: said once, no error" ;;
        *) bad "a file of root in an open folder is not mentioned" ;; esac
    sudo -n rm -f "$rf"
fi

echo "VS Code settings:"
vh=$t/vshome; mkdir -p "$vh/.config/Code/User"
printf '{\n  // mine\n  "editor.fontSize": 14,\n  "claudeCode.claudeProcessWrapper": "/opt/mine", /* x */\n}\n' \
    >"$vh/.config/Code/User/settings.json"
cp "$vh/.config/Code/User/settings.json" "$t/vs-before"
SAFEAI_HOME=$vh safeai settings set vscode on >/dev/null 2>&1 &&
    grep -q '"claudeCode.claudeProcessWrapper": "/usr/local/lib/safeai/safeai-run"' "$vh/.config/Code/User/settings.json" \
    && ok "settings with comments are switched to the agent" || bad "settings with comments are not switched"
SAFEAI_HOME=$vh safeai settings set vscode off >/dev/null 2>&1
cmp -s "$t/vs-before" "$vh/.config/Code/User/settings.json" && ok "...and switched back exactly as they were, your launcher too" \
    || bad "switching back did not restore your settings"
find "$vh" -delete; rm -f "$t/vs-before"
mkdir -p "$vh/.config/Code"
SAFEAI_HOME=$vh safeai settings set vscode on >/dev/null 2>&1 && [ -f "$vh/.config/Code/User/settings.json" ] \
    && ok "settings are created when VS Code has none yet" || bad "no settings created where VS Code has none yet"
find "$vh" -delete

echo "The agent's chats in the VS Code list:"
flock -w 10 "$fh/.config/safeai/.chats-lock" true  # one the chats above started in the background: done first
SAFEAI_HOME=$fh safeai _chats
copy=$fh/.claude/projects/-safeai-check-$$/$theirs.jsonl
[ "$(cat "$copy" 2>/dev/null)" = '{"agent":1}' ] && [ ! -w "$copy" ] \
    && ok "a read-only copy of the agent's chat" || bad "no read-only copy of the agent's chat"
[ ! -e "$fh/.claude/projects/-safeai-check-$$/$yours.jsonl" ] && [ "$(cat "$fh/.claude/projects/-check-you/$yours.jsonl")" = '{"mine":1}' ] \
    && ok "an agent's chat with the number of yours is not copied" || bad "an agent's chat took the number of yours"
$AG sh -c "rm -f ~/.claude/projects/-safeai-check-$$/*.jsonl && rmdir ~/.claude/projects/-safeai-check-$$" 2>/dev/null
SAFEAI_HOME=$fh safeai _chats
[ ! -e "$copy" ] && ok "a chat the agent deleted leaves the list" || bad "a chat the agent deleted stays in the list"

echo "Read-only by the files' own permissions:"
mkdir "$ro/wx" && setfacl -m "u:$AGENT:-wx" "$ro/wx"  # it may add files there, not list them
case "$(safeai ls "$ro" 2>/dev/null)" in *"write   wx/"*) ok "a folder the agent can add to but not list counts as writable" ;;
    *) bad "a folder the agent can write but not list is not shown as writable" ;; esac
echo x >"$ro/g" && setfacl -m "g:$AGENT:rw" "$ro/g" && safeai read "$ro" >/dev/null
deny "an ACL entry for the agent's group does not let it write in a read-only folder" "echo y >>'$ro/g' && echo SAFEAI-MARK"
mkdir "$ro/da" && setfacl -d -m o::--- "$ro/da" && safeai close "$ro/da" >/dev/null && safeai read "$ro/da" >/dev/null
getfacl -p "$ro/da" 2>/dev/null | grep -q '^default:other::---' && ok "your own default ACL stays through close and read" \
    || bad "your own default ACL was dropped"
# a read-only folder whose default ACL grants the agent's group write: new files must stay read-only to it
mkdir "$ro/gd" && setfacl -d -m "g:$AGENT:rwx" "$ro/gd" && safeai read "$ro" >/dev/null
echo made-by-you >"$ro/gd/new"
deny "new file in a read-only folder with an agent-group default ACL is not writable" "echo x >>'$ro/gd/new' && echo SAFEAI-MARK"
allow "...but the agent can read it" "cat '$ro/gd/new' >/dev/null"
rm -f "$ro/g" "$ro/gd/new"; rmdir "$ro/wx" "$ro/da" "$ro/gd"
# a umask like 077: every file is 600, so the mode says nothing (safeai goes by names and rules)
um="$H/.config/safeai/umask"; had_um=$(cat "$um" 2>/dev/null); echo 0077 >"$um"
u7=$work/umask-$$; mkdir -m 700 "$u7" && (umask 077; echo x >"$u7/f") && safeai open "$u7" >/dev/null
allow "umask 077: a 600 file in a folder you open is open to the agent" "echo y >>'$u7/f'"
safeai read "$u7" >/dev/null
allow "...in a read-only one it reads it" "cat '$u7/f' >/dev/null"
deny "...and cannot change it" "echo z >>'$u7/f' && echo SAFEAI-MARK"
safeai close "$u7" >/dev/null; rm -f "$u7/f"; rmdir "$u7"
if [ -n "$had_um" ]; then printf '%s\n' "$had_um" >"$um"; else rm -f "$um"; fi
find "$fh" -delete 2>/dev/null
safeai close "$ro" >/dev/null 2>&1; rmdir "$ro"; rm -f "$fake"

echo "The agent asks you:"
ask() { $AG /usr/local/bin/safeai ask "$@" 2>&1; }
case "$(ask read "$t/.env" "for the check")" in *"holds secrets"*) ok "a secret is never asked for on screen" ;;
    *) bad "a secret could be asked for on screen" ;; esac
wf=$t/inside.txt; : >"$wf"; safeai close "$wf" >/dev/null
case "$(ask read "$wf" "for the check")" in *"inside a folder you can change"*)
        ok "nothing inside a folder the agent can change is asked for on screen" ;;
    *) bad "a place the agent could swap is asked for on screen" ;; esac
rm -f "$wf"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])' /run/safeai-ask.sock 2>/dev/null \
    && bad "others can put questions on your screen" || ok "only the agent can ask"
if [ -n "${SAFEAI_TEST_VM:-}" ]; then  # a throwaway machine: a stand-in for the window on your screen
    z=/tmp/safeai-zenity
    sudo -n install -m 755 /dev/stdin /usr/local/bin/zenity <<EOF
#!/bin/sh
printf '%s\n' "\$@" >$z.args; echo x >>$z.count
case "\$(cat $z.answer)" in ok) exit 0 ;; readonly) echo "Read only"; exit 1 ;; *) exit 1 ;; esac
EOF
    rm -f "/run/user/$(id -u)/safeai-asked.json" $z.count
    ad=$H/safeai-check-ask-$$; mkdir "$ad"; safeai read "$ad" >/dev/null  # the agent reads it, cannot rearrange it
    af=$ad/asked.txt; printf 'SAFEAI-MARK\n' >"$af"; safeai close "$af" >/dev/null
    case "$(ask read "$af" "for the check")" in *"No answer"*) ok "no desktop: the agent hears there is no answer" ;;
        *) bad "no desktop: the agent was not told there is no answer" ;; esac
    rm -f "/run/user/$(id -u)/safeai-asked.json"
    systemctl --user set-environment DISPLAY=:99
    echo ok >$z.answer
    out=$(ask read "$af" "$(printf 'to check\033[2J it \342\200\256 and \342\200\250 more')")
    case "$out" in *"can now read"*) ok "you allow reading: the agent can read it" ;; *) bad "allowing reading did not work: $out" ;; esac
    $AG cat "$af" 2>/dev/null | grep -q SAFEAI-MARK && ok "...and really reads it" || bad "...but cannot read it"
    grep -q -e "$(printf '\033')" -e "$(printf '\342\200\256')" -e "$(printf '\342\200\250')" $z.args \
        && bad "the agent's reason reaches your screen with control characters" || ok "the agent's reason is shown as plain text"
    od=$ad/asked-dir; mkdir "$od"; safeai close "$od" >/dev/null; echo readonly >$z.answer
    case "$(ask open "$od" "to change it")" in *"allowed reading"*) ok "you can answer read-only to a request to change" ;;
        *) bad "a read-only answer did not work" ;; esac
    $AG touch "$od/x" 2>/dev/null && bad "...but the agent can change it" || ok "...and it cannot change it"
    nf=$ad/asked-no.txt; : >"$nf"; safeai close "$nf" >/dev/null; echo no >$z.answer
    case "$(ask read "$nf" "please")" in *"said no"*) ok "you say no: the agent is told so" ;; *) bad "a no did not reach the agent" ;; esac
    n=$(wc -l <$z.count)
    case "$(ask read "$nf" "please again")" in *"a few minutes ago"*) ;; *) bad "the agent can ask again right after a no" ;; esac
    [ "$(wc -l <$z.count)" = "$n" ] && ok "after a no, the same question does not come back for a while" \
        || bad "after a no, the question came back on screen"
    mkdir -p "$H/go/pkg" && safeai close "$H/go/pkg" >/dev/null
    case "$(ask open "$H/go/pkg" "to build")" in *"code that runs as the owner"*)
            ok "program folders (~/go, ~/bin, ...) are never offered for changing on screen" ;;
        *) bad "a program folder was offered for changing on screen" ;; esac
    rmdir "$H/go/pkg" "$H/go"
    systemctl --user unset-environment DISPLAY
    sudo -n rm -f /usr/local/bin/zenity; rm -f $z.args $z.count $z.answer "/run/user/$(id -u)/safeai-asked.json"
    rm -f "$af" "$nf"; rmdir "$od" "$ad"
fi

echo "Audit log:"
if [ -r /var/log/audit/audit.log ]; then
    safeai log 1 | grep -q "safeai-check-$$/.env" && ok "refusal shows up in safeai log" || bad "safeai log misses the refusal"
    lf=$t/review.txt; echo x >"$lf"; safeai close "$lf" >/dev/null; $AG cat "$lf" >/dev/null 2>&1; sleep 1
    safeai log review 1 </dev/null | grep -q "safeai-check-$$/review.txt " && ok "log review offers the very file, not its folder" \
        || bad "log review does not offer the very file"
    rm -f "$lf"
else
    skip "audit log not installed"
fi

echo "Explaining refusals to the agent:"
out=$(echo "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$t/.env\"},\"tool_error\":\"EACCES: permission denied\"}" \
    | $AG "$LIB/safeai-explain" 2>/dev/null)
case "$out" in *additionalContext*secret*) ok "Claude Code hears why a .env is refused" ;; *) bad "no explanation for a refused .env" ;; esac
$AG sh -c 'grep -q safeai-explain ~/.claude/settings.json' 2>/dev/null && ok "the hook is in the agent's Claude Code settings" \
    || bad "the hook is missing from the agent's Claude Code settings"
$AG sh -c 'grep -qx "@~/.claude/safeai.md" ~/.claude/CLAUDE.md && [ -s ~/.claude/safeai.md ]' 2>/dev/null \
    && ok "the agent's instructions bring in safeai's notes" || bad "the agent's instructions miss safeai's notes"

echo "Rules inside folders (the nearest rule decides, the last action on a folder wins):"
D=$work/nested; mkdir -p "$D/sub" && for f in F G sub/H; do echo SAFEAI-MARK >"$D/$f"; done
safeai close "$D" >/dev/null && safeai open "$D/F" >/dev/null
allow "opening a file inside a closed folder: it is open" "grep -q SAFEAI-MARK '$D/F' && echo x >>'$D/F'"
deny "...the rest of the folder stays closed" "cat '$D/G'"
deny "...and the folder cannot be listed" "ls '$D' && echo SAFEAI-MARK"
case "$(safeai why "$D")" in *"partly open"*) ok "...and the folder is shown as partly open" ;;
    *) bad "a closed folder with something open inside is not shown as partly open" ;; esac
case "$(safeai status)" in *"partly open"*nested*) ok "...also in safeai status" ;; *) bad "safeai status does not show it" ;; esac
safeai check >/dev/null && ok "...and safeai check agrees" || bad "safeai check disagrees with a partly open folder"
case "$(safeai close "$D")" in *"closed now"*"F (was open)"*) ok "closing the folder again closes what was open inside, and says so" ;;
    *) bad "closing the folder did not say what else it closed" ;; esac
deny "...the file is closed" "cat '$D/F'"
mkdir -p "$D/ww" "$D/.vscode" && chmod 777 "$D/ww"
safeai read "$D" >/dev/null && safeai open "$D/F" >/dev/null
allow "a file opened inside a read-only folder can be changed" "echo x >>'$D/F'"
deny "...the rest stays read-only" "echo x >>'$D/G' && echo SAFEAI-MARK"
case "$(safeai read "$D")" in *"read-only now"*"F (was open)"*) ok "making the folder read-only again makes that file read-only too" ;;
    *) bad "read-only on the folder left an open file inside" ;; esac
deny "...it cannot be changed" "echo x >>'$D/F' && echo SAFEAI-MARK"
[ -z "$(getfacl -p "$D/G" 2>/dev/null | grep "^user:$AGENT:")" ] \
    && ok "read-only: nothing is written on each file inside (fast on big folders)" || bad "read-only: an entry on every file"
allow "...the agent reads by the files' own permissions" "grep -q . '$D/G'"
deny "...a folder in it that anyone may write stays read-only" "touch '$D/ww/x' && echo SAFEAI-MARK"
echo y >"$D/later"
allow "...a file made there later: the agent reads it" "grep -q y '$D/later'"
deny "...and cannot change it" "echo x >>'$D/later' && echo SAFEAI-MARK"
chmod 666 "$D/later" && safeai check --fix >/dev/null
deny "...a file anyone may write since: safeai check makes it read-only to the agent" "echo x >>'$D/later' && echo SAFEAI-MARK"
case "$(safeai check)" in *"$D/.vscode"*) bad "safeai check keeps finding a read-only folder's .vscode not read-only" ;;
    *) ok "...and safeai check agrees with it (also on a .vscode inside)" ;; esac
safeai open "$D" >/dev/null && safeai close "$D/sub" >/dev/null
printf 'SECRET=SAFEAI-MARK\n' >"$D/.env"; echo SAFEAI-MARK >"$D/mine"; chmod 600 "$D/mine"; sleep 1
out=$(safeai open "$D" </dev/null)
case "$out" in *"also what you had set there"*"sub (was closed)"*) ok "opening the folder opens everything inside, also what you closed, and says so" ;;
    *) bad "opening the folder did not open (or did not say) what you had closed inside" ;; esac
allow "...it is open" "grep -q SAFEAI-MARK '$D/sub/H'"
case "$out" in *"still protected inside"*".env"*"private to you"*) ok "...and it says what stays protected" ;;
    *) bad "opening the folder does not say what stays protected" ;; esac
deny "...a .env file stays closed" "cat '$D/.env'"
deny "...a file private to you stays closed" "cat '$D/mine'"
ext=$(dirname "$0")/../share/nautilus/safeai_nautilus.py
[ -f "$ext" ] || ext=$H/.local/share/nautilus-python/extensions/safeai_nautilus.py
if [ -f "$ext" ]; then  # the emblems in Files: what the agent can do with that very item
    safeai close "$D" >/dev/null && safeai open "$D/F" >/dev/null && safeai read "$D/sub" >/dev/null
    o=$work/open-with-closed; mkdir -p "$o" && echo x >"$o/kept" && echo x >"$o/shut"
    safeai open "$o" >/dev/null && safeai close "$o/shut" >/dev/null
    ext_says() {  # ext_says agent_access|emblem_of PATH...: the extension's answer for each path
        python3 -B - "$ext" "$@" <<'EOF'
import importlib.util, os, sys, types
gi, rep = types.ModuleType("gi"), types.ModuleType("gi.repository")
rep.Gio, rep.GObject = types.SimpleNamespace(), types.SimpleNamespace(GObject=type("G", (), {}))
rep.Nautilus = types.SimpleNamespace(MenuProvider=type("M", (), {}), InfoProvider=type("I", (), {}))
gi.repository = rep
sys.modules.update({"gi": gi, "gi.repository": rep})
spec = importlib.util.spec_from_file_location("ext", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(os.environ.get("SEP", " ").join(str(getattr(m, sys.argv[2])(p)) for p in sys.argv[3:]))
EOF
    }
    got=$(ext_says agent_access "$D" "$D/F" "$D/G" "$D/sub" "$o" "$o/shut" "$D/.env")
    want="pass full none read full none none"
    [ "$got" = "$want" ] && ok "emblems in Files show what is true of each item" \
        || bad "emblems in Files: $got (expected $want: partly open, open, closed, read-only, open, closed, closed)"
    # two colors, left the folder, right inside: open or read-only with something you closed inside
    r=$work/read-with-closed; mkdir -p "$r/x" && safeai read "$r" >/dev/null && safeai close "$r/x" >/dev/null
    po=$work/plain-open; e=$work/env-only; mkdir -p "$po" "$e" && echo S=1 >"$e/.env"
    safeai open "$po" >/dev/null && safeai open "$e" >/dev/null  # its .env closed by safeai itself
    dp=$work/deep; mkdir -p "$dp/a/b" && safeai open "$dp" >/dev/null && safeai close "$dp/a/b" >/dev/null
    got=$(ext_says emblem_of "$o" "$r" "$dp" "$dp/a" "$po" "$e" "$D" "$o/shut" "$o/kept")
    want="full+closed read+closed full+closed full+closed None None pass none None"
    [ "$got" = "$want" ] && ok "a folder with something you closed inside, at any depth, shows it (a .env does not count)" \
        || bad "emblems for what is closed inside: $got (expected $want)"
    got=$(SEP=" | " ext_says status_of "$o" "$r" "$D" "$po" "$o/shut")
    want="Now: open, something closed inside | Now: read-only, something closed inside | Now: closed, something open inside | Now: open | Now: closed"
    [ "$got" = "$want" ] && ok "the right-click menu says what the emblem says" || bad "right-click status: $got (expected $want)"
    rmdir "$dp/a/b"
    [ "$(ext_says emblem_of "$dp" "$dp/a")" = "None None" ] && ok "...and stops once that is gone" \
        || bad "a folder still shows something closed inside after it was deleted"
    safeai close "$o" "$r" "$po" "$e" "$dp" >/dev/null; rm -f "$o/kept" "$o/shut" "$e/.env"
    rmdir "$o" "$r/x" "$r" "$po" "$e" "$dp/a" "$dp"
else
    skip "Files extension not here: emblems"
fi
safeai close "$D" >/dev/null; rm -f "$D/F" "$D/G" "$D/sub/H" "$D/.env" "$D/mine" "$D/later"; rmdir "$D/sub" "$D/ww" "$D/.vscode" "$D"

echo "Rules:"
case "$(touch "$t/report draft.txt"; safeai why "$t/report draft.txt")" in *"'$t/report draft.txt'"*)
        ok "commands to copy quote the path" ;; *) bad "a path with a space is not quoted in the command to copy" ;; esac
rm -f "$t/report draft.txt"
safeai check --typo >/dev/null 2>&1 && bad "safeai check accepts a mistyped option" || ok "a mistyped option is refused"
python3 -B - /usr/local/bin/safeai <<'EOF' && ok "a working copy (X.Y.Z-dev) counts as older than its release, for updates" \
    || bad "versions compare wrong: a working copy would not update to its release"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("safeai", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("safeai", loader))
loader.exec_module(m)
v = m.vtuple
sys.exit(not (v("v0.2.0") < v("0.2.1-dev") < v("v0.2.1") < v("0.3.0-dev") and v("x") is None))
EOF
safeai read "$t/.env" </dev/null >/dev/null 2>&1 && bad "a secret opened without asking" \
    || ok "reading a secret needs your yes in a terminal"
p=$t/bypass; mkdir "$p" && safeai close "$p" >/dev/null && setfacl -m "u:$AGENT:rwx" "$p" && safeai check --fix >/dev/null 2>&1
[ "$(getfacl -p "$p" 2>/dev/null | sed -n "s/^user:$AGENT://p")" = "---" ] && ok "a setfacl around safeai is undone by the check" \
    || bad "a setfacl around safeai stays"
rmdir "$p"
p=$t/locked; mkdir "$p"
flock "$H/.config/safeai/.lock" sleep 3 & held=$!
sleep 0.5
timeout 1 safeai close "$p" >/dev/null 2>&1
[ $? = 124 ] && ok "rule changes wait for each other" || bad "a rule change did not wait for the one under way"
wait $held; rmdir "$p"

echo "Services:"
for u in safeai-guard.service safeai-check.timer; do
    [ "$(systemctl is-active "$u")" = active ] && ok "$u" || bad "$u is not active"
done
safeai check >/dev/null && ok "safeai check: all good" || bad "safeai check found problems"

find "$t/repo" -mindepth 1 -delete 2>/dev/null; rmdir "$t/repo" 2>/dev/null
find "$t/new" -mindepth 1 -delete 2>/dev/null; rmdir "$t/new" 2>/dev/null
find "$t/proj" -mindepth 1 -delete 2>/dev/null; rmdir "$t/proj" 2>/dev/null
sudo -n -u "$AGENT" find "$t/own" -mindepth 1 -delete 2>/dev/null; rmdir "$t/own" 2>/dev/null
safeai open "$pj" >/dev/null 2>&1; sudo -n -u "$AGENT" find "$pj" -mindepth 1 -delete 2>/dev/null
find "$pj" -mindepth 1 -delete 2>/dev/null; rmdir "$pj" 2>/dev/null
rm -f "$t/.env" "$t/prod.env" "$t/a.txt" "$t/race.env"
rmdir "$t"
rmdir "$work"
safeai check --fix >/dev/null  # forgets the removed scratch folders
# what this run moved out of its scratch projects goes too (yours stays)
Q=$H/.local/share/safeai-quarantine
for who in "" "sudo -n -u $AGENT"; do
    $who find "$Q" -depth \( -path "*/safeai-check-work-$$" -o -path "*/safeai-check-work-$$/*" \) -delete 2>/dev/null
done
find "$Q" -mindepth 1 -type d -empty -delete 2>/dev/null
[ -z "$(find "$Q" -path "*/safeai-check-work-$$*" -print -quit 2>/dev/null)" ] && ok "nothing of this check is left in the quarantine" \
    || bad "this check left files in the quarantine"
ran
if [ -r /var/log/audit/audit.log ]; then
    safeai log 1 | grep -q "safeai-check-work-$$" && bad "safeai log shows what this check tried as the agent" \
        || ok "safeai log leaves out what this check tried as the agent"
fi
[ $fail = 0 ] && echo "All checks passed" || echo "Some checks failed"
exit $fail
