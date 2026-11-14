#!/bin/bash
# Boot a built image (throwaway snapshot, KVM) and check greybox + topgen end to
# end, from a sim node and from an external client on the runner's tap0.
# usage: tests/smoke.sh IMAGE.qcow2
# env: PASSWORD (slatebox), VHOST (www.cmu.edu), EXPECT (carnegie: text on its
#      home page), DIAG (smoke-diag.txt). Writes serial-smoke.log in the cwd.
set -uo pipefail

IMG=${1:?usage: tests/smoke.sh IMAGE.qcow2}
PASSWORD=${PASSWORD:-slatebox}
VHOST=${VHOST:-www.cmu.edu}
EXPECT=${EXPECT:-carnegie}
DIAG=${DIAG:-smoke-diag.txt}
CA=/var/lib/topgen/etc/topgen_ca.cer
PORT=2222

cleanup() { kill "$QEMU" 2>/dev/null; sudo ip netns del ext 2>/dev/null; sudo ip link del tap0 2>/dev/null; }
sudo ip tuntap add dev tap0 mode tap user "$(id -un)" || exit 1
# explicit PCI slots: the external NIC at 0x4 is ens4 in the guest
qemu-system-x86_64 -machine accel=kvm -cpu host -smp 4 -m 8192 -snapshot -display none \
  -serial file:serial-smoke.log \
  -drive file="$IMG",if=none,id=d0 -device virtio-blk-pci,drive=d0,addr=0x5 \
  -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=mgmt,addr=0x3 \
  -netdev tap,id=ext,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=ext,addr=0x4 &
QEMU=$!
trap cleanup EXIT

# vm CMD: run CMD as root in the VM (at most 120 s)
vm() {
  timeout 120 sshpass -p "$PASSWORD" ssh -q -p $PORT -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 slatebox@127.0.0.1 \
    "sudo -S -p '' bash -c $(printf %q "$1")" <<<"$PASSWORD"
}
# node NAME CMD: run CMD in a CORE node
node() { vm "greybox-ctl exec $1 sh -c $(printf %q "$2")"; }
charlie() { node CharlieUser1 "$1"; }
ext() { sudo ip netns exec ext "$@"; }

diag() {
  echo "=== diagnostics (also in $DIAG)"
  vm "set -x
    systemctl --no-pager status greybox core-daemon
    journalctl -b --no-pager -u core-daemon -u greybox | tail -300
    journalctl -k --no-pager | grep -i denied | tail -50
    greybox-ctl status; cat /etc/default/greybox; ip -br link | head -20; ip -s link show ens4
    cat /var/lib/topgen/etc/hosts.nginx
    greybox-ctl exec topgen.info ps -ef
    greybox-ctl exec iap1-rtr.disa.mil sh -c 'ps -ef | grep [d]hcpd; ip -br addr'
    greybox-ctl exec iap4-rtr.disa.mil vtysh -c 'show bgp summary'
    ls -d /tmp/pycore.*" 2>&1 | tee "$DIAG"
  echo "=== runner side of tap0 (check 12)"; ext ip -s addr show tap0 2>&1 | tee -a "$DIAG"
  echo "=== tail serial-smoke.log"; tail -100 serial-smoke.log | tee -a "$DIAG"
}
die() { echo "FAIL: $*"; diag; exit 1; }
FAILED=()
check() { # check NAME CMD...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $name"; else echo "FAIL: $name"; FAILED+=("$name"); fi
}
# wait_for TRIES CMD...: retry every 10 s
wait_for() { local n=$1; shift; until "$@" >/dev/null 2>&1; do ((--n > 0)) || return 1; sleep 10; done; }
runtime() { vm "greybox-ctl status" | grep -q RUNTIME; }
hops() { charlie "traceroute -n -w1 -q1 $IP" | grep -c '^ *[0-9]'; }
in_pool() { [[ $1 =~ ^12\.0\.0\.([0-9]+)$ ]] && ((BASH_REMATCH[1] >= 100 && BASH_REMATCH[1] <= 250)); }
ext_https() { ext curl -sf -m 30 --cacert ca.cer --resolve "$VHOST:443:$IP" "https://$VHOST/" | grep -qi "$EXPECT"; }

echo "waiting for ssh (5 min) ..."
wait_for 30 vm true || die "no ssh on port $PORT"
echo "waiting for greybox.service (20 min) ..."
for ((i = 0; ; i++)); do
  state=$(vm "systemctl is-active greybox.service")
  case $state in active) break ;; failed) die "greybox.service failed" ;; esac
  ((i < 120)) || die "greybox.service still '$state' after 20 min"
  sleep 10
done
echo "greybox.service active after about $((i * 10)) s"

IP=$(vm "awk -v h=$VHOST '\$2 == h { print \$1 }' /var/lib/topgen/etc/hosts.nginx")
[ -n "$IP" ] || die "$VHOST not in hosts.nginx"
echo "vhost: $VHOST ($IP); waiting for BGP convergence (10 min) ..."
wait_for 60 charlie "ping -c1 -W2 $IP" || echo "FAIL: CharlieUser1 cannot ping $IP"

check "1 greybox-ctl status RUNTIME" runtime
check "2 ens4 is a real NIC" vm "test -e /sys/class/net/ens4/device"
check "3 named nginx postfix dovecot on topgen.info" node topgen.info "pidof named && pidof nginx && pidof master && pidof dovecot"
check "4 dhcpd on iap1-rtr.disa.mil" node iap1-rtr.disa.mil "pidof dhcpd"
check "5 DNS: $VHOST = $IP" test "$(charlie "dig +short @8.8.8.8 $VHOST")" = "$IP"
check "6a ping $IP" charlie "ping -c3 -W2 $IP"
check "6b traceroute $IP >= 3 hops" test "$(hops)" -ge 3
check "7 https://$VHOST/ (TopGen CA)" charlie "curl -sf -m 30 --cacert $CA https://$VHOST/ | grep -qi $EXPECT"
check "8 https://topgen.info/ lists $VHOST" charlie "curl -sf -m 30 --cacert $CA https://topgen.info/ | grep -q $VHOST"
check "9 CRL from topgen.info" charlie "curl -sf -m 30 http://topgen.info/topgen_ca.crl | openssl crl -inform DER -noout"
check "10 $VHOST cert has a CRL distribution point" charlie "openssl s_client -connect $VHOST:443 \
  -servername $VHOST </dev/null 2>/dev/null | openssl x509 -noout -ext crlDistributionPoints | grep -q topgen_ca.crl"
# first vmail.cfg entry: "<host> <ip> user:pass ..."
read -r _ MIP CRED _ < <(vm "grep -v '^#' /etc/topgen/vmail.cfg | grep . | head -1")
check "11a IMAPS login ${CRED%%:*}@$MIP" charlie "curl -sf -m 30 --cacert $CA \
  --resolve imap.topgen.info:993:$MIP --user $CRED imaps://imap.topgen.info/"
check "11b SMTP submission AUTH on $MIP:587" charlie "curl -sf -m 30 --ssl-reqd --cacert $CA \
  --resolve smtp.topgen.info:587:$MIP --user $CRED smtp://smtp.topgen.info:587/ -X NOOP"

# 12: the runner as an external client on the RJ45 network (12.0.0.0/24 behind
# iap1-rtr). The tap stays attached to qemu while it moves into its own netns.
vm "cat $CA" > ca.cer
sudo ip netns add ext && sudo ip link set tap0 netns ext &&
  ext ip link set lo up && ext ip link set tap0 up || echo "FAIL: cannot move tap0 into a netns"
lease=$(ext timeout 60 busybox udhcpc -i tap0 -f -q -n -t 10 -T 3 -s /bin/true 2>&1)
echo "$lease"
EIP=$(grep -o 'lease of [0-9.]*' <<<"$lease" | awk '{ print $3 }')
check "12a external DHCP lease in 12.0.0.100-250 (${EIP:-none})" in_pool "$EIP"
if [ -n "$EIP" ]; then
  ext ip addr add "$EIP/24" dev tap0 && ext ip route add default via 12.0.0.41
fi
check "12b external ping 12.0.0.41" ext ping -c3 -W2 12.0.0.41
check "12c external DNS: $VHOST = $IP" test "$(ext dig +short +time=3 +tries=2 @8.8.8.8 "$VHOST")" = "$IP"
check "12d external https://$VHOST/" ext_https

if [ ${#FAILED[@]} -gt 0 ]; then
  printf 'FAILED: %s\n' "${FAILED[@]}"
  diag
  exit 1
fi
echo "all smoke checks passed"
