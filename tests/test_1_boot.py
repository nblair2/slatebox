"""The VM boots into a running greybox simulation."""
import pytest


@pytest.mark.parametrize("unit", ["core-daemon", "greybox"])
def test_service_active(vm, unit):
    """The CORE daemon and the greybox map service are running."""
    r = vm.sh(f"systemctl is-active {unit}")
    assert r.out == "active", vm.sh(f"systemctl --no-pager status {unit}").out


def test_sim_in_runtime(vm):
    """greybox-ctl reports the CORE session in RUNTIME."""
    r = vm.sh("greybox-ctl status")
    assert r.ok and "RUNTIME" in r.out, r.out


def test_ext_nic_is_real(vm):
    """ens4 is the VM's second NIC, not the dummy greybox substitutes when it is missing."""
    r = vm.sh("test -e /sys/class/net/ens4/device")
    assert r.ok, vm.sh("ip -d link show ens4").out


@pytest.mark.parametrize("daemon", ["named", "nginx", "master", "dovecot"])
def test_topgen_daemon_running(vm, daemon):
    """topgen.info runs DNS (named), web (nginx) and mail (postfix master, dovecot)."""
    r = vm.node("topgen.info", f"pidof {daemon}")
    assert r.ok, vm.node("topgen.info", "ps -ef").out


def test_dhcpd_on_edge_router(vm):
    """iap1-rtr.disa.mil serves DHCP to the external network."""
    r = vm.node("iap1-rtr.disa.mil", "pidof dhcpd")
    assert r.ok, r.out
