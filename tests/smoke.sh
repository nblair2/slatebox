#!/bin/bash
# Boot a built image (throwaway snapshot) and check greybox + topgen end to end.
# Usage: tests/smoke.sh [image.qcow2]   env: ACCEL=kvm|tcg  PASSWORD=slatebox
set -uo pipefail

IMG=${1:-build/image/slatebox.qcow2}
ACCEL=${ACCEL:-kvm}
PASSWORD=${PASSWORD:-slatebox}
PORT=${PORT:-2222}
CLIENT=DeltaUser1

command -v sshpass >/dev/null || sudo apt-get install -y sshpass openssh-client

qemu-system-x86_64 -snapshot -machine accel="$ACCEL" -cpu max -smp 4 -m 8192 \
  -drive file="$IMG",if=virtio -display none \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:"$PORT"-:22 &
QEMU=$!
trap 'kill $QEMU 2>/dev/null' EXIT

# Run a command as root inside the VM.
vm() {
  sshpass -p "$PASSWORD" ssh -q -p "$PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 slatebox@127.0.0.1 \
    "sudo -S -p '' bash -c $(printf %q "$1")" <<<"$PASSWORD"
}
# Run a command inside the CORE client node.
node() { vm "greybox-ctl exec $CLIENT sh -c $(printf %q "$1")"; }

FAIL=0
check() {
  local name=$1; shift
  if "$@" >/dev/null; then echo "PASS: $name"; else echo "FAIL: $name"; FAIL=1; fi
}
retry() { # retry <tries> <cmd...>: wait for something to come up
  local n=$1; shift
  until "$@" >/dev/null 2>&1; do ((--n > 0)) || return 1; sleep 10; done
}

echo "waiting for ssh on port $PORT ..."
retry 180 vm true || { echo "FAIL: ssh"; exit 1; }
retry 60 vm "systemctl is-active greybox.service"

check "greybox.service active" vm "systemctl is-active greybox.service"
check "greybox-ctl status" vm "greybox-ctl status"

# First scraped vhost (other than topgen.info) and its IP.
read -r IP VHOST < <(vm "grep -v ' topgen.info$' /var/lib/topgen/etc/hosts.nginx | head -1")
echo "vhost: $VHOST ($IP)"

echo "waiting for BGP convergence ..."
retry 60 node "ping -c1 -W2 $IP"

check "traceroute $IP >= 3 hops" \
  test "$(node "traceroute -n -w1 -q1 $IP" | tail -n +2 | wc -l)" -ge 3
check "https://$VHOST/ (TopGen CA)" \
  node "curl -sf -o /dev/null --cacert /var/lib/topgen/etc/topgen_ca.cer https://$VHOST/"
check "CRL from topgen.info" \
  node "curl -sf http://topgen.info/topgen_ca.crl | openssl crl -inform DER -noout"

exit $FAIL
