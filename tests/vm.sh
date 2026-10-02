#!/bin/bash
# Throwaway test VMs (QEMU/KVM, no root needed): boot a cloud image, install
# safeai from this checkout, run tests/check.sh.
#
#   tests/vm.sh up DISTRO      create and boot a VM (ubuntu, debian, fedora, arch)
#   tests/vm.sh test DISTRO [strict|relaxed]
#                              fresh copy of this checkout, install with --yes, run the checks
#   tests/vm.sh clean DISTRO   install, use and uninstall on a fresh VM; nothing may be left
#   tests/vm.sh crash DISTRO   cut the power in the middle of an install, at a few points; after each,
#                              the installer run again must finish (checks pass), or uninstall must
#                              leave the VM as it was
#   tests/vm.sh ssh DISTRO [CMD...]
#   tests/vm.sh down DISTRO    power off
#   tests/vm.sh destroy DISTRO power off and delete the VM disk
#
# Needs qemu-system-x86_64, qemu-img, xorriso, curl and access to /dev/kvm.
# Fedora: set FEDORA_IMAGE_URL to a Fedora Cloud Base qcow2 image.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${SAFEAI_VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/safeai-vm}
cmd=${1:-}; name=${2:-}
case "$name" in
    ubuntu) url=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img port=2231 ;;
    debian) url=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 port=2232 ;;
    fedora) url=${FEDORA_IMAGE_URL:-} port=2233 ;;
    arch) url=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 port=2234 ;;
    *) sed -n '2,18s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac
VM=$DIR/$name
KEY=$DIR/id_ed25519
SSH=(ssh -i "$KEY" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o "SendEnv=-LC_* -LANG" tester@127.0.0.1)

running() { [ -f "$VM/pid" ] && kill -0 "$(cat "$VM/pid")" 2>/dev/null; }
stop() {  # shut down cleanly (a hard power-off can leave empty ssh host keys), then wait
    running || return 0
    "${SSH[@]}" -o ConnectTimeout=3 'sudo sync; sudo systemctl poweroff' >/dev/null 2>&1 || true
    for _ in $(seq 120); do running || return 0; sleep 0.5; done
    kill "$(cat "$VM/pid")"  # no clean shutdown within a minute
    while running; do sleep 0.5; done
}

up() {
    mkdir -p "$VM"
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C safeai-vm -f "$KEY"
    base=$DIR/$(basename "$url")
    if [ ! -f "$base" ]; then
        [ -n "$url" ] || { echo "set FEDORA_IMAGE_URL"; exit 1; }
        echo "downloading $url"
        curl -fL --progress-bar -o "$base.part" "$url" && mv "$base.part" "$base"
    fi
    if [ ! -f "$VM/disk.qcow2" ]; then
        qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$VM/disk.qcow2" 20G
        mkdir -p "$VM/seed"
        printf 'instance-id: safeai-%s\nlocal-hostname: safeai-%s\n' "$name" "$name" >"$VM/seed/meta-data"
        cat >"$VM/seed/user-data" <<EOF
#cloud-config
users:
  - name: tester
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [$(cat "$KEY.pub")]
EOF
        xorriso -as mkisofs -quiet -V cidata -J -r -o "$VM/seed.iso" "$VM/seed/user-data" "$VM/seed/meta-data" 2>/dev/null
    fi
    running && { echo "$name is already running"; return; }
    qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -display none -daemonize -pidfile "$VM/pid" \
        -drive "file=$VM/disk.qcow2,if=virtio" -drive "file=$VM/seed.iso,media=cdrom" \
        -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22" \
        -serial "file:$VM/console.log"  # the boot log, to see why a VM does not come up
    printf 'waiting for ssh'
    for _ in $(seq 90); do
        "${SSH[@]}" -o ConnectTimeout=2 true 2>/dev/null && { echo " ok"; "${SSH[@]}" cloud-init status --wait >/dev/null 2>&1 || true; return; }
        printf .; sleep 2
    done
    echo " timeout"; exit 1
}

case "$cmd" in
    up) up ;;
    ssh) shift 2; "${SSH[@]}" "$@" ;;
    test)
        running || up
        # a folder for the checks, then a fresh copy of this checkout
        "${SSH[@]}" 'mkdir -p ~/Projects/demo && rm -rf ~/src && mkdir ~/src'
        tar --exclude=.git --exclude=__pycache__ -cf - . | "${SSH[@]}" 'tar -xf - -C ~/src'
        "${SSH[@]}" "cd ~/src && sudo SAFEAI_MODE=${3:-strict} ./install.sh --yes && SAFEAI_TEST_VM=1 tests/check.sh"
        ;;
    clean)  # install, use, uninstall on a fresh VM; then compare with the state before
        stop; rm -rf "$VM"; up
        tar --exclude=.git --exclude=__pycache__ -cf - . | "${SSH[@]}" 'mkdir -p ~/src && tar -xf - -C ~/src'
        "${SSH[@]}" 'cd ~/src && tests/uninstall-check.sh'
        ;;
    crash)  # a power cut (QEMU killed) while the installer runs, at the moment the manifest shows a step
        failed=0
        for point in "created-user:remove" "created-lists:again" "created-file /etc/audit:remove" \
                     "created-file /etc/systemd/system/safeai-guard:again"; do
            at=${point%:*} then=${point##*:}
            stop; rm -rf "$VM"; up >/dev/null
            tar --exclude=.git --exclude=__pycache__ -cf - . | "${SSH[@]}" 'mkdir -p ~/src ~/Projects/demo && tar -xf - -C ~/src'
            "${SSH[@]}" 'cd ~/src && tests/uninstall-check.sh snap ~/before.txt'
            "${SSH[@]}" 'cd ~/src && sudo SAFEAI_MODE=strict setsid nohup ./install.sh --yes >/dev/null 2>&1 </dev/null &'
            for _ in $(seq 600); do "${SSH[@]}" "sudo grep -q '^$at' /var/lib/safeai/manifest 2>/dev/null" && break; sleep 0.2; done
            kill -9 "$(cat "$VM/pid")"; while running; do sleep 0.2; done; rm -f "$VM/pid"
            up >/dev/null
            if [ "$then" = again ]; then  # run the installer again: it finishes, and all checks pass
                out=$("${SSH[@]}" 'cd ~/src && sudo SAFEAI_MODE=strict ./install.sh --yes >/dev/null 2>&1 && SAFEAI_TEST_VM=1 tests/check.sh' |
                    grep -E "FAIL|All checks|Some checks" || true)
                printf '%s\n' "${out:-no result}" | sed "s|^|cut at '$at', installed again: |"
                case "$out" in *FAIL*|*"Some checks"*|"") failed=1 ;; esac
            fi
            out=$("${SSH[@]}" 'cd ~/src && sudo ./uninstall.sh --yes >/dev/null 2>&1; tests/uninstall-check.sh compare ~/before.txt' || true)
            printf '%s\n' "${out:-no result}" | sed "s|^|cut at '$at', then $then, removed: |"
            case "$out" in *Clean:*) ;; *) failed=1 ;; esac
        done
        exit $failed
        ;;
    down) stop; rm -f "$VM/pid" ;;
    destroy) stop; rm -rf "$VM" ;;
    *) sed -n '2,16s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac
