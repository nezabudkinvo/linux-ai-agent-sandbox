#!/bin/bash
# Install, use, uninstall - then compare the system with how it was before.
# For a throwaway machine only (tests/vm.sh clean DISTRO runs it): it installs
# and removes safeai and needs sudo without a password.
# Exit code 1 = something was left behind or changed.
set -uo pipefail
cd "$(dirname "$0")/.."
H=$HOME
snap() {  # everything safeai may touch, in a comparable form
    sudo find /etc /usr/local /var/lib/safeai "$H" /tmp /var/tmp -xdev \
        -path /etc/ld.so.cache -prune -o -path "$H/.cache" -prune -o -path /var/tmp/systemd-private-\* -prune -o \
        -printf '%p %u %g %m\n' 2>/dev/null | sort
    sudo getfacl -R -p -s "$H" 2>/dev/null
    sudo find /etc -xdev -type f ! -name '*-' ! -name .pwd.lock ! -name ld.so.cache -exec md5sum {} + 2>/dev/null | sort -k2
    getent passwd | cut -d: -f1 | sort
    getent group | cut -d: -f1,4 | sort
    systemctl list-unit-files --no-legend 'safeai*' 2>/dev/null
    sudo auditctl -l 2>/dev/null
    [ -d /sys/kernel/security/apparmor ] && sudo grep -c safeai /sys/kernel/security/apparmor/profiles 2>/dev/null
    { dpkg -l 2>/dev/null || rpm -qa 2>/dev/null || pacman -Q 2>/dev/null; } | awk '{print $1, $2}' | sort
}
mkdir -p "$H/Projects/demo"
snap >/tmp/before.txt

sudo SAFEAI_MODE=relaxed ./install.sh --yes >/dev/null || { echo "install failed"; exit 1; }
# some use: the agent writes, you close and open things, VS Code on and off
AG="sudo -n -u aiagent"
$AG sh -c "echo made-by-agent > $H/Projects/demo/agent.txt; mkdir -p $H/Projects/demo/sub"
safeai close "$H/Projects/demo/sub" >/dev/null
safeai read "$H/Projects" >/dev/null
safeai settings set mode strict >/dev/null
sleep 2
sudo /usr/local/lib/safeai/uninstall.sh --yes >/dev/null
snap >/tmp/after.txt

# what the agent made in your folders stays, as yours
# with the modes this system's umask gives new files (Ubuntu 002, Debian 022)
um=$((8#$(umask)))
expected="$H/Projects/demo/agent.txt $(id -un) $(id -gn) $(printf '%o' $((0666 & ~um)))
$H/Projects/demo/sub $(id -un) $(id -gn) $(printf '%o' $((0777 & ~um)))"
diff /tmp/before.txt /tmp/after.txt | grep '^[<>]' | grep -vF -e "$H/Projects/demo/agent.txt" -e "$H/Projects/demo/sub" \
    -e "/etc/.pwd.lock" -e "/etc/gshadow-" -e "/etc/shadow-" -e "/etc/passwd-" -e "/etc/group-" -e "/etc/subuid-" \
    -e "/etc/subgid-" -e "/tmp/before.txt" -e "/tmp/after.txt" -e "/var/cache" >/tmp/diff.txt
fail=0
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
