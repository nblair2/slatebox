"""Boot (or attach to) a slatebox VM once per session and share helpers.

    pytest tests --image build/image/slatebox.qcow2    boot a throwaway snapshot
    pytest tests --image IMG --keep                    ... and leave it running
    pytest tests --attach                              reuse a VM left by --keep

The VM's second NIC (ens4, the sim's RJ45 link to iap1-rtr.disa.mil) is the
tap device --tap on this machine. The `ext` fixture moves it into the network
namespace "ext" and makes it an external client of the sim (DHCP lease,
default route via 12.0.0.41, resolver 8.8.8.8).

Artifacts go to --out: serial.log, qemu.log, diag.txt (written when anything fails, the
run times out, or the sim never comes up) and the browser screenshots.
"""

import getpass
import os
import re
import shlex
import signal
import subprocess
import time
from collections import namedtuple
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
CA = "/var/lib/topgen/etc/topgen_ca.cer"  # TopGen CA cert, in the VM
EXT_GW, RESOLVER = "12.0.0.41", "8.8.8.8"

Result = namedtuple("Result", "rc out")
Result.ok = property(lambda r: r.rc == 0)


def pytest_addoption(parser):
    add = parser.addoption
    add("--image", help="qcow2 to boot (a -snapshot, nothing is written to it)")
    add("--attach", action="store_true", help="use an already running VM instead of booting one")
    add("--keep", action="store_true", help="leave the booted VM running (for --attach later)")
    add("--ssh-port", type=int, default=2222, help="host port forwarded to the VM's ssh")
    add("--tap", default="tap0", help="tap device connected to the VM's ens4")
    add("--password", default="slatebox", help="password of the slatebox user")
    add("--vhost", default="www.cmu.edu", help="mirrored site to test")
    add("--expect", default="Carnegie Mellon", help="text on the vhost's home page")
    add("--out", default="test-output", help="directory for logs, diagnostics and screenshots")
    add("--deadline", type=int, default=60, help="minutes before the run is stopped with diagnostics")


def sh(cmd, timeout=120, **kw):
    """Run a local shell command, returning Result(rc, combined output)."""
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout, check=False, **kw)
        return Result(p.returncode, (p.stdout + p.stderr).strip())
    except subprocess.TimeoutExpired as e:
        return Result(124, f"timed out after {timeout} s: {cmd}\n{e.stdout or ''}{e.stderr or ''}")


def log(msg):
    """Print a progress line live, past pytest's output capture."""
    with _state["config"].pluginmanager.getplugin("capturemanager").global_and_fixture_disabled():
        print(msg, flush=True)


def retry(fn, tries, delay=10):
    """Call fn() until its result is ok, at most `tries` times; return the last result."""
    for i in range(tries):
        r = fn()
        if r.ok or i == tries - 1:
            return r
        time.sleep(delay)


class VM:
    def __init__(self, cfg):
        self.port = cfg.getoption("ssh_port")
        self.password = cfg.getoption("password")
        self.tap = cfg.getoption("tap")
        self.out = Path(cfg.getoption("out"))
        self.qemu = None

    def sh(self, cmd, timeout=120):
        """Run cmd as root in the VM (bash, via ssh + sudo)."""
        ssh = (
            "sshpass -e ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
            f"-o ConnectTimeout=10 -p {self.port} slatebox@127.0.0.1"
        )
        remote = "sudo -S -p '' bash -c " + shlex.quote(cmd)
        env = dict(os.environ, SSHPASS=self.password)
        return sh(f"{ssh} {shlex.quote(remote)}", timeout, input=self.password + "\n", env=env)

    def node(self, name, cmd, timeout=120):
        """Run cmd (sh) in the CORE node `name`."""
        return self.sh(f"greybox-ctl exec {shlex.quote(name)} sh -c {shlex.quote(cmd)}", timeout)

    def charlie(self, cmd, timeout=120):
        """Run cmd on CharlieUser1, the in-sim client (12.0.1.54)."""
        return self.node("CharlieUser1", cmd, timeout)

    def boot(self, image):
        """Start qemu: user-net NIC (ssh on --ssh-port) and --tap as ens4 (PCI slot 4)."""
        user = getpass.getuser()
        sh(f"sudo ip link del {self.tap}")  # left over from an interrupted run
        r = sh(f"sudo ip tuntap add dev {self.tap} mode tap user {user} && sudo ip link set {self.tap} up")
        assert r.ok, f"cannot create {self.tap}: {r.out}"
        mem_mib = int(Path("/proc/meminfo").read_text().split()[1]) // 1024
        mem = min(mem_mib - 2048, 8192)  # leave 2 GiB for the host
        qemu_log = open(self.out / "qemu.log", "w")  # noqa: SIM115 (qemu writes to it until it exits)
        # fmt: off
        self.qemu = subprocess.Popen([
            "qemu-system-x86_64", "-machine", "accel=kvm", "-cpu", "host",
            "-smp", str(os.cpu_count()), "-m", str(mem), "-snapshot", "-display", "none",
            "-serial", f"file:{self.out}/serial.log",
            "-drive", f"file={image},if=none,id=d0", "-device", "virtio-blk-pci,drive=d0,addr=0x5",
            "-netdev", f"user,id=mgmt,hostfwd=tcp:127.0.0.1:{self.port}-:22",
            "-device", "virtio-net-pci,netdev=mgmt,addr=0x3",
            "-netdev", f"tap,id=ext,ifname={self.tap},script=no,downscript=no",
            "-device", "virtio-net-pci,netdev=ext,addr=0x4",
        ], stdout=qemu_log, stderr=subprocess.STDOUT, start_new_session=True)  # survives Ctrl-C, for --keep
        # fmt: on
        time.sleep(3)
        assert self.qemu.poll() is None, f"qemu exited: {(self.out / 'qemu.log').read_text()}"

    def wait_ready(self):
        """Wait for ssh (5 min), greybox.service (20 min) and the CORE session in RUNTIME."""
        r = retry(lambda: self.sh("true"), 30)
        assert r.ok, f"no ssh on port {self.port} after 5 min: {r.out}"
        log("ssh is up; waiting for greybox.service")
        t0 = time.monotonic()
        while (state := self.sh("systemctl is-active greybox.service").out) != "active":
            assert state != "failed", "greybox.service failed"
            assert time.monotonic() - t0 < 1200, f"greybox.service still '{state}' after 20 min"
            time.sleep(10)
        log(f"greybox.service active after {time.monotonic() - t0:.0f} s")
        r = self.sh("greybox-ctl status")
        assert "RUNTIME" in r.out, f"CORE session not in RUNTIME: {r.out}"

    def stop(self):
        if self.qemu:
            self.qemu.terminate()
            self.qemu.wait(30)
            sh(f"sudo ip link del {self.tap}")


class External:
    """This machine as a client on the sim's RJ45 network (12.0.0.0/24 behind iap1-rtr)."""

    NS = "ext"

    def __init__(self, tap):
        self.tap = tap
        self.ip, self.lease_log, self.last_state = None, "", ""

    def sh(self, cmd, timeout=120):
        """Run cmd as root in the ext namespace."""
        return sh(f"sudo ip netns exec {self.NS} sh -c {shlex.quote(cmd)}", timeout)

    def as_user(self, cmd, timeout=300, **env):
        """Run cmd as the invoking user in the ext namespace, with a clean environment."""
        user = os.environ.get("SUDO_USER") or getpass.getuser()
        envs = " ".join(f"{k}={shlex.quote(str(v))}" for k, v in env.items())
        return sh(f"sudo ip netns exec {self.NS} sudo -u {user} env -i PATH=/usr/bin:/bin {envs} {cmd}", timeout)

    def setup(self):
        self.teardown()  # left over from an interrupted run (--attach)
        # ip netns exec bind-mounts these over /etc: the sim's resolver, and DNS
        # only (no systemd-resolved, which would answer from the real internet)
        etc = Path(f"/etc/netns/{self.NS}")
        sh(f"sudo mkdir -p {etc}")
        sh(f"echo 'nameserver {RESOLVER}' | sudo tee {etc}/resolv.conf")
        sh(f"printf 'hosts: files dns\\n' | sudo tee {etc}/nsswitch.conf")
        r = sh(f"sudo ip netns add {self.NS} && sudo ip link set {self.tap} netns {self.NS}")
        assert r.ok, f"cannot move {self.tap} into netns {self.NS}: {r.out}"
        self.sh(f"ip link set lo up && ip link set {self.tap} up")
        r = self.sh(f"busybox udhcpc -i {self.tap} -f -q -n -t 10 -T 3 -s /bin/true", 90)
        self.lease_log = r.out
        m = re.search(r"lease of ([\d.]+)", r.out)
        assert m, f"no DHCP lease on {self.tap} from the sim:\n{r.out}"
        self.ip = m.group(1)
        r = self.sh(f"ip addr add {self.ip}/24 dev {self.tap} && ip route add default via {EXT_GW}")
        assert r.ok, r.out
        log(f"external client: {self.ip} on {self.tap} in netns {self.NS}")

    def state(self):
        return self.sh("ip -s addr; ip route; cat /etc/resolv.conf").out

    def teardown(self):
        if self.ip:
            self.last_state = self.state()  # for write_diag, which runs later
        # hand the tap back (deleting the netns would destroy it, breaking --attach)
        sh(f"sudo ip -n {self.NS} link set {self.tap} netns 1; sudo ip netns del {self.NS}")


# ---- session state, diagnostics, deadline ----

_state = {"vm": None, "ext": None, "diag": None, "config": None}


def write_diag(reason):
    """Collect what explains most failures into OUT/diag.txt (once per run)."""
    vm, ext = _state["vm"], _state["ext"]
    if vm is None or _state["diag"]:
        return
    path = vm.out / "diag.txt"
    _state["diag"] = path
    # Known-benign AppArmor denials, repeated for every router, that would push a
    # real one out of the kernel log tail: bgpd looks for a config file in
    # /usr/local/etc/frr (CORE passes it each node's own) and names its threads
    # in /proc; `who` cannot read passwd and nsswitch.conf. Both work regardless.
    benign = r'profile="bgpd" name="(/usr/local/etc/frr/frr\.conf|/proc/[0-9]+/task/[0-9]+/comm)"|profile="who"'
    script = f"""BENIGN={shlex.quote(benign)}
set -x
systemctl --no-pager status greybox core-daemon
journalctl -b --no-pager -u core-daemon -u greybox | tail -300
journalctl -k --no-pager | grep -i denied | grep -Ev "$BENIGN" | tail -50
greybox-ctl status; cat /etc/default/greybox; ip -br link | head -20; ip -s link show ens4
cat /var/lib/topgen/etc/hosts.nginx
greybox-ctl exec topgen.info ps -ef
greybox-ctl exec topgen.info tail -n 50 /var/log/dovecot.log /var/log/nginx/error.log
journalctl -b --no-pager -t named | tail -50
greybox-ctl exec iap1-rtr.disa.mil sh -c 'ps -ef | grep [d]hcpd; ip -br addr'
greybox-ctl exec iap4-rtr.disa.mil vtysh -c 'show bgp summary'
ls -d /tmp/pycore.*"""
    parts = [f"reason: {reason}", "=== VM", vm.sh(script, 300).out]
    if ext:
        parts += ["=== external client (netns ext)", ext.last_state or ext.state(), ext.lease_log]
    serial = vm.out / "serial.log"
    if serial.exists():
        parts += ["=== tail serial.log", "\n".join(serial.read_text(errors="replace").splitlines()[-100:])]
    path.write_text("\n".join(parts) + "\n")


def _stop_run(signum, _frame):
    write_diag(f"stopped by signal {signum} (deadline?)")
    pytest.exit(f"stopped by signal {signum} (deadline or timeout); see diag.txt", returncode=1)


def pytest_configure(config):
    _state["config"] = config
    if hasattr(config.option, "deadline"):  # not for --help
        signal.signal(signal.SIGTERM, _stop_run)
        signal.signal(signal.SIGALRM, _stop_run)
        signal.alarm(config.getoption("deadline") * 60)


def pytest_terminal_summary(terminalreporter):
    if _state["diag"]:
        terminalreporter.section(f"diagnostics ({_state['diag']})")
        terminalreporter.write(_state["diag"].read_text())


# ---- fixtures ----


@pytest.fixture(scope="session")
def vm(request):
    """The VM, booted (or attached to), with the sim in RUNTIME."""
    cfg = request.config
    v = VM(cfg)
    v.out.mkdir(parents=True, exist_ok=True)
    _state["vm"] = v
    try:
        if not cfg.getoption("attach"):
            image = cfg.getoption("image")
            assert image, "give --image IMAGE.qcow2 (or --attach)"
            if not cfg.getoption("keep"):
                request.addfinalizer(v.stop)
            v.boot(image)
            if cfg.getoption("keep"):
                log(f"--keep: qemu pid {v.qemu.pid} stays up; rerun with --attach")
        log(f"waiting for the VM (ssh port {v.port}, tap {v.tap})")
        v.wait_ready()
    except AssertionError as e:
        reason = f"the sim never came up: {str(e).splitlines()[0]}"
        write_diag(reason)
        pytest.exit(reason, returncode=1)
    yield v
    if request.session.testsfailed:
        write_diag(f"{request.session.testsfailed} test(s) failed")


@pytest.fixture(scope="session")
def vhost(vm, request):
    """(name, ip) of the mirrored site under test, from the VM's hosts.nginx."""
    name = request.config.getoption("vhost")
    ip = vm.sh(f"awk '$2 == \"{name}\" {{ print $1 }}' /var/lib/topgen/etc/hosts.nginx").out
    assert ip, f"{name} is not in hosts.nginx"
    return name, ip


@pytest.fixture(scope="session", autouse=True)
def converged(vm, vhost):
    """Before any test, wait (up to 10 min) for BGP to converge: CharlieUser1 can
    ping the vhost. Never fails by itself; test_2_routing reports it."""
    r = retry(lambda: vm.charlie(f"ping -c1 -W2 {vhost[1]}"), 60)
    log(f"routing {'converged' if r.ok else 'did NOT converge in 10 min'}")


@pytest.fixture(scope="session")
def expect(request):
    return request.config.getoption("expect")


@pytest.fixture(scope="session")
def ca_file(vm):
    """Local copy of the TopGen CA certificate."""
    path = (vm.out / "topgen_ca.cer").resolve()
    r = vm.sh(f"cat {CA}")
    assert "BEGIN CERTIFICATE" in r.out, r.out
    path.write_text(r.out + "\n")
    return path


@pytest.fixture(scope="session")
def ext(vm, converged, request):
    """This machine as an external client of the sim (see External)."""
    e = External(vm.tap)
    _state["ext"] = e
    request.addfinalizer(e.teardown)
    e.setup()
    return e


def mail_servers():
    """(host, ip, user, password) of the first account of each vmail.cfg server."""
    rows = []
    for line in (REPO / "files/etc/topgen/vmail.cfg").read_text().splitlines():
        f = line.split()
        if f and not f[0].startswith("#"):
            user, password = f[2].split(":", 1)
            rows.append((f[0], f[1], user, password))
    return rows
