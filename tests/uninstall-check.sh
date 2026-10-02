#!/bin/bash
# Install, use, uninstall - then compare the system with how it was before.
# For a throwaway machine only (tests/vm.sh clean DISTRO runs it): it installs
# and removes safeai and needs sudo without a password.
# Exit code 1 = something was left behind or changed.
#   tests/uninstall-check.sh snap FILE      the state to compare with later (tests/vm.sh crash)
#   tests/uninstall-check.sh compare FILE   the machine now against that state
set -uo pipefail
cd "$(dirname "$0")/.."
H=$HOME
snap() {  # everything safeai may touch, in a comparable form
    sudo find /etc /usr/local /var/lib/safeai "$H" /tmp /var/tmp -xdev \
        -path /etc/ld.so.cache -prune -o -path "$H/.cache" -prune -o -path /var/tmp/systemd-private-\* -prune -o -path /tmp/systemd-private-\* -prune -o \
        -printf '%p %u %g %m\n' 2>/dev/null | sort
    sudo getfacl -R -p -s "$H" 2>/dev/null
    sudo find /etc -xdev -type f ! -name '*-' ! -name .pwd.lock ! -name ld.so.cache -exec md5sum {} + 2>/dev/null | sort -k2
    getent passwd | cut -d: -f1 | sort
    getent group | cut -d: -f1,4 | sort
    systemctl list-unit-files --no-legend 'safeai*' 2>/dev/null
    find "/run/user/$(id -u)" -maxdepth 1 -name 'safeai*' 2>/dev/null
    sudo auditctl -l 2>/dev/null
    [ -d /sys/kernel/security/apparmor ] && sudo grep -c safeai /sys/kernel/security/apparmor/profiles 2>/dev/null
    { dpkg -l 2>/dev/null || rpm -qa 2>/dev/null || pacman -Q 2>/dev/null; } | awk '{print $1, $2}' | sort
}
differences() {  # differences BEFORE AFTER [EXPECTED...] - what changed, but for what comes and goes on its own
    local skip=() e
    for e in "${@:3}"; do skip+=(-e "$e"); done
    diff "$1" "$2" | grep '^[<>]' | grep -vF "${skip[@]}" -e "/etc/.pwd.lock" -e "/etc/gshadow-" -e "/etc/shadow-" \
        -e "/etc/passwd-" -e "/etc/group-" -e "/etc/subuid-" -e "/etc/subgid-" -e "before.txt" -e "after.txt" -e "/var/cache" \
        -e "/etc/pacman.d/gnupg/S."  # the sockets of pacman's gpg-agent, made anew at each boot
}
case "${1:-}" in
    snap) snap >"$2"; sync; exit 0 ;;
    compare)
        snap >/tmp/after.txt  # after a reboot: /tmp starts empty, its entries are not compared
        differences "$2" /tmp/after.txt | grep -v '^[<>] /tmp/' >/tmp/diff.txt
        if [ -s /tmp/diff.txt ]; then echo "Not clean:"; sed 's/^/        /' /tmp/diff.txt; exit 1; fi
        echo "Clean: the system is as before"; exit 0 ;;
esac
mkdir -p "$H/Projects/demo"
snap >/tmp/before.txt
fail=0

# the installer speaks the language asked for, also when it refuses to start
ru=$(sed -n 's/^MSG\[err_sudo\]="\([^:]*\):.*/\1/p' share/i18n/ru)  # the refusal as the translation has it
case "$(SAFEAI_LANG=ru ./install.sh --yes 2>&1)" in *"${ru:?}"*) ;; *) echo "FAIL  a refusal of the installer is not translated"; fail=1 ;; esac
# how it starts (strict or relaxed) has no default: without an answer nothing is installed
sudo ./install.sh --yes >/dev/null 2>&1 && { echo "FAIL  installed without a chosen start (strict or relaxed)"; fail=1; }
[ -e /usr/local/bin/safeai ] && { echo "FAIL  something was installed without a chosen start"; fail=1; }
# an agent user made before safeai: refused unless you say to use it; then it keeps its own instructions,
# and uninstall leaves it as it was
sudo useradd -m -s /bin/bash aiagent
sudo -u aiagent sh -c 'mkdir -p ~/.claude ~/.codex && echo "my own rules" >~/.claude/CLAUDE.md && ln -s /etc/hostname ~/.codex/AGENTS.md'
sudo SAFEAI_MODE=strict ./install.sh --yes >/dev/null 2>&1 && { echo "FAIL  a user made before safeai was taken without asking"; fail=1; }
sudo SAFEAI_MODE=strict SAFEAI_ADOPT_USER=1 ./install.sh --yes >/dev/null || { echo "FAIL  could not use the existing user"; fail=1; }
sudo -u aiagent sh -c 'grep -qx "@~/.claude/safeai.md" ~/.claude/CLAUDE.md && grep -qx "my own rules" ~/.claude/CLAUDE.md &&
    [ -L ~/.codex/AGENTS.md ]' || { echo "FAIL  the agent's own instructions were not kept"; fail=1; }
sudo /usr/local/lib/safeai/uninstall.sh --yes >/dev/null
getent passwd aiagent >/dev/null || { echo "FAIL  uninstall deleted a user it had not made"; fail=1; }
[ "$(sudo -u aiagent sh -c 'cat ~/.claude/CLAUDE.md; ls ~/.claude/safeai.md 2>/dev/null')" = "my own rules" ] ||
    { echo "FAIL  uninstall did not leave the agent's instructions as they were"; fail=1; }
sudo userdel -r aiagent 2>/dev/null; sudo groupdel aiagent 2>/dev/null
# Ctrl+C in the middle of an install, typed into its terminal as soon as the agent user exists:
# everything done so far is undone
rm -f /tmp/ctl; mkfifo /tmp/ctl
( sleep 600 >/tmp/ctl ) & keeper=$!
# a background job ignores SIGINT, a terminal you type in does not: start as from a terminal
python3 -c 'import signal, os, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    script -qec "sudo SAFEAI_MODE=strict ./install.sh --yes" /dev/null </tmp/ctl >/dev/null 2>&1 & typed=$!
for _ in $(seq 600); do sudo grep -q "^created-user" /var/lib/safeai/manifest 2>/dev/null && break; sleep 0.05; done
printf '\003' >/tmp/ctl  # Ctrl+C
wait $typed; kill $keeper 2>/dev/null; rm -f /tmp/ctl
# the terminal here goes away with its shell; the reverting goes on in its own session until done
for _ in $(seq 240); do pgrep -f "install.sh --apply|uninstall.sh" >/dev/null || break; sleep 0.5; done
for f in /usr/local/bin/safeai /usr/local/lib/safeai /etc/safeai.conf /etc/sudoers.d/safeai /var/lib/safeai/manifest; do
    sudo test -e "$f" && { echo "FAIL  an interrupted install left $f"; fail=1; }
done
getent passwd aiagent >/dev/null && { echo "FAIL  an interrupted install left the agent user"; fail=1; }
# a step that fails half way: the fresh install is undone completely
sudo touch /etc/safeai.conf && sudo chattr +i /etc/safeai.conf
sudo SAFEAI_MODE=strict ./install.sh --yes >/dev/null 2>&1 && { echo "FAIL  the install did not fail"; fail=1; }
sudo chattr -i /etc/safeai.conf && sudo rm -f /etc/safeai.conf
getent passwd aiagent >/dev/null && { echo "FAIL  a failed install left the agent user"; fail=1; }
[ -e /usr/local/bin/safeai ] && { echo "FAIL  a failed install left safeai"; fail=1; }
# a failed update puts the version installed before back
sudo SAFEAI_MODE=strict ./install.sh --yes >/dev/null || { echo "install failed"; exit 1; }
sum=$(md5sum </usr/local/bin/safeai)
cp -a . /tmp/newer && echo "# newer" >>/tmp/newer/bin/safeai && echo "# newer" >>/tmp/newer/share/agent-shell.sh
sudo chattr +i /usr/local/share/bash-completion/completions/safeai
sudo /tmp/newer/install.sh --update >/dev/null 2>&1 && { echo "FAIL  the update did not fail"; fail=1; }
sudo chattr -i /usr/local/share/bash-completion/completions/safeai
[ "$(md5sum </usr/local/bin/safeai)" = "$sum" ] || { echo "FAIL  a failed update left the new safeai in place"; fail=1; }
grep -q "# newer" /usr/local/lib/safeai/agent-shell.sh && { echo "FAIL  a failed update left new files"; fail=1; }
systemctl is-active --quiet safeai-guard || { echo "FAIL  the guard does not run after a failed update"; fail=1; }
find /tmp/newer -delete
sudo /usr/local/lib/safeai/uninstall.sh --yes >/dev/null
# the questions of uninstall, answered in a terminal: keep only the rules, then remove everything
cp -a . /tmp/inst  # installed from outside your home: no question about the downloaded copy
mkdir -p "$H/Projects/demo/kept"
sudo SAFEAI_MODE=strict /tmp/inst/install.sh --yes >/dev/null || { echo "install failed"; exit 1; }
safeai close "$H/Projects/demo/kept" >/dev/null
sudo -u aiagent sh -c 'mkdir -p ~/.ssh && echo key >~/.ssh/id_check'
# not completely; keep the rules; the agent and the packages go; its home saved first, as an archive
pk=""; sudo grep -q "^installed-package" /var/lib/safeai/manifest && pk=$'n\n'  # asked about packages only if any
script -qec "sudo /usr/local/lib/safeai/uninstall.sh" /dev/null <<<$'n\ny\nn\n'"$pk"$'y\n~/agent-home.tar.gz' >/dev/null 2>&1
grep -qx "$H/Projects/demo/kept" "$H/.config/safeai/closed" 2>/dev/null || { echo "FAIL  the rules were not kept"; fail=1; }
[ "$(stat -c '%U %a' "$H/agent-home.tar.gz" 2>/dev/null)" = "$(id -un) 600" ] &&
    tar -xzOf "$H/agent-home.tar.gz" aiagent/.ssh/id_check 2>/dev/null | grep -qx key ||
    { echo "FAIL  the agent's home was not saved as an archive only you can read"; fail=1; }
rm -f "$H/agent-home.tar.gz"
[ -z "$(find "$H/.config/safeai" -mindepth 1 ! -name write-dirs ! -name read-only ! -name closed ! -name env-open \
    ! -name mode 2>/dev/null)" ] || { echo "FAIL  more than the rules stayed"; fail=1; }
getent passwd aiagent >/dev/null && { echo "FAIL  the agent user stayed though not kept"; fail=1; }
sudo /tmp/inst/install.sh --yes >/dev/null || { echo "install failed"; exit 1; }
sudo -n -u aiagent ls "$H/Projects/demo/kept" >/dev/null 2>&1 && { echo "FAIL  a kept rule did not come back"; fail=1; }
script -qec "sudo /usr/local/lib/safeai/uninstall.sh" /dev/null <<<$'y\nn' >/dev/null 2>&1
[ -e "$H/.config/safeai" ] && { echo "FAIL  removing completely left your rules"; fail=1; }
[ -e /usr/local/bin/safeai ] && { echo "FAIL  removing completely left safeai"; fail=1; }
find /tmp/inst -delete; rmdir "$H/Projects/demo/kept"
rmdir "$H/.config" 2>/dev/null  # kept across the two installs above, so the second did not count it as its own

sudo SAFEAI_MODE=relaxed ./install.sh --yes >/dev/null || { echo "install failed"; exit 1; }
# some use: the agent writes, you close and open things, VS Code on and off
AG="sudo -n -u aiagent"
$AG sh -c "echo made-by-agent > $H/Projects/demo/agent.txt; mkdir -p $H/Projects/demo/sub $H/Projects/demo/.vscode
    echo '{}' > $H/Projects/demo/.vscode/tasks.json"
safeai check --fix >/dev/null 2>&1  # the agent's .vscode runs as you: moved out of the project
safeai close "$H/Projects/demo/sub" >/dev/null
safeai read "$H/Projects" >/dev/null
safeai settings set mode strict >/dev/null
out=$(sudo ./install.sh --update 2>&1) || { echo "FAIL  an update of an installed safeai failed"; fail=1; }
n=$(grep -c '^== Plan$' <<<"$out")
[ "$n" = 1 ] || { echo "FAIL  an update showed its plan $n times, not once"; fail=1; }
safeai _who me "$H/Projects/demo" >/dev/null 2>&1  # your session's state goes too
sleep 2
# Ctrl+D at any later question cancels, never picks a removal (here: whether to save the agent's home)
out=$(script -qec "sudo /usr/local/lib/safeai/uninstall.sh" /dev/null <<<y 2>&1)
case "$out" in *"Nothing changed"*) ;; *) echo "FAIL  end of input in uninstall's questions did not cancel"; fail=1 ;; esac
[ -e /usr/local/bin/safeai ] && getent passwd aiagent >/dev/null || { echo "FAIL  a cancelled uninstall removed something"; fail=1; }
# "remove completely" names what safeai moved out of your projects, then removes it
out=$(script -qec "sudo /usr/local/lib/safeai/uninstall.sh" /dev/null <<<$'y\nn' 2>&1)
case "$out" in *"moved out of your projects (~/.local/share/safeai-quarantine)"*) ;;
    *) echo "FAIL  uninstall does not say it removes what safeai moved out of your projects"; fail=1 ;; esac
[ -f "$H/src/install.sh" ] || { echo "FAIL  removing completely deleted the copy it was installed from"; fail=1; }
snap >/tmp/after.txt

# what the agent made in your folders stays, as yours
# with the modes this system's umask gives new files (Ubuntu 002, Debian 022)
um=$((8#$(umask)))
expected="$H/Projects/demo/agent.txt $(id -un) $(id -gn) $(printf '%o' $((0666 & ~um)))
$H/Projects/demo/sub $(id -un) $(id -gn) $(printf '%o' $((0777 & ~um)))"
differences /tmp/before.txt /tmp/after.txt "$H/Projects/demo/agent.txt" "$H/Projects/demo/sub" >/tmp/diff.txt
while read -r line; do
    grep -qxF "$line" /tmp/after.txt || { echo "FAIL  missing after: $line"; fail=1; }
done <<<"$expected"
if [ -s /tmp/diff.txt ]; then
    echo "FAIL  left behind or changed:"; sed 's/^/        /' /tmp/diff.txt; fail=1
fi
python3 -c 'import os, sys; sys.exit("system.posix_acl_access" in os.listxattr(sys.argv[1]))' "$H/Projects/demo/agent.txt" \
    || { echo "FAIL  an ACL is left on the agent's file"; fail=1; }
[ $fail = 0 ] && echo "Clean: the system is as before (plus the agent's files, now yours)" || echo "Not clean"
exit $fail
