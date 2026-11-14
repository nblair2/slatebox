"""Packets cross the simulated internet, inside the sim and from outside."""

import ipaddress
import json

import pytest


@pytest.mark.parametrize("router", ["iap1-rtr.disa.mil", "iap4-rtr.disa.mil", "london-rtr.btplc.com"])
def test_bgp_sessions_established(vm, router):
    """Every BGP neighbor of a sample of routers is Established."""
    r = vm.node(router, "vtysh -c 'show bgp summary json'")
    assert r.ok, r.out
    # skip vtysh's warnings around the JSON
    peers = json.JSONDecoder().raw_decode(r.out[r.out.find("{") :])[0]["ipv4Unicast"]["peers"]
    down = {ip: p["state"] for ip, p in peers.items() if p["state"] != "Established"}
    assert peers and not down, f"{router}: {down or 'no peers'}"


def test_sim_client_pings_vhost(vm, vhost):
    """CharlieUser1 reaches the web vhost's address."""
    r = vm.charlie(f"ping -c3 -W2 {vhost[1]}")
    assert r.ok, r.out


def test_sim_client_traceroute_crosses_routers(vm, vhost):
    """The path from CharlieUser1 to the vhost crosses at least 3 hops."""
    r = vm.charlie(f"traceroute -n -w1 -q1 {vhost[1]}")
    hops = [line for line in r.out.splitlines() if line.strip()[:1].isdigit()]
    assert len(hops) >= 3, r.out


def test_external_dhcp_lease_in_pool(ext):
    """An external machine on ens4 gets a lease in 12.0.0.100-250 from iap1-rtr."""
    ip = ipaddress.ip_address(ext.ip)
    assert ipaddress.ip_address("12.0.0.100") <= ip <= ipaddress.ip_address("12.0.0.250"), ext.lease_log


def test_external_client_pings_gateway(ext):
    """The external client reaches its default gateway 12.0.0.41."""
    r = ext.sh("ping -c3 -W2 12.0.0.41")
    assert r.ok, r.out


def test_external_client_pings_vhost(ext, vhost):
    """The external client reaches the web vhost across the sim."""
    r = ext.sh(f"ping -c3 -W2 {vhost[1]}")
    assert r.ok, r.out + "\n" + ext.sh(f"traceroute -n -w1 -q1 {vhost[1]}").out
