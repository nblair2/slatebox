"""The VM boots into a running greybox simulation."""

import pytest


@pytest.mark.parametrize("unit", ["core-daemon", "greybox"])
def test_service_active(vm, unit):
    """The CORE daemon and the greybox map service are running."""
    r = vm.sh(f"systemctl is-active {unit}")
    assert r.out == "active", vm.sh(f"systemctl --no-pager status {unit}").out


# The units ansible/tasks/packages.yml disables; their daemons run inside CORE nodes.
HOST_UNITS = [
    "frr",
    "nginx",
    "named",
    "postfix",
    "dovecot",
    "isc-dhcp-server",
    "isc-dhcp-server6",
    "keepalived",
    "networkd-dispatcher",
]


def test_host_daemons_inactive(vm):
    """The simulated services' daemons do not run as host units."""
    r = vm.sh("systemctl is-active " + " ".join(HOST_UNITS))
    states = r.out.splitlines()
    assert len(states) == len(HOST_UNITS) and "active" not in states, r.out


def test_resolv_conf(vm):
    """/etc/resolv.conf is a regular file that names only the simulated 8.8.8.8."""
    r = vm.sh("test -f /etc/resolv.conf && ! test -L /etc/resolv.conf && cat /etc/resolv.conf")
    assert r.ok and r.out == "nameserver 8.8.8.8", vm.sh("ls -l /etc/resolv.conf; cat /etc/resolv.conf").out


def test_sim_in_runtime(vm):
    """greybox-ctl reports the CORE session in RUNTIME."""
    r = vm.sh("greybox-ctl status")
    assert r.ok and "RUNTIME" in r.out, r.out


@pytest.mark.parametrize("daemon", ["named", "nginx", "master", "dovecot"])
def test_topgen_daemon_running(vm, daemon):
    """topgen.info runs DNS (named), web (nginx) and mail (postfix master, dovecot)."""
    r = vm.node("topgen.info", f"pidof {daemon}")
    assert r.ok, vm.node("topgen.info", "ps -ef").out


def test_dhcpd_on_edge_router(vm):
    """iap1-rtr.disa.mil serves DHCP to the external network."""
    r = vm.node("iap1-rtr.disa.mil", "pidof dhcpd")
    assert r.ok, r.out
