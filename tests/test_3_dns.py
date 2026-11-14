"""DNS works like the real thing: root -> TLD -> answer, through the in-sim resolver 8.8.8.8."""

import pytest

from conftest import REPO, mail_servers

ROOT, TLD, RESOLVER = "198.41.0.4", "4.4.4.8", "8.8.8.8"  # a.root-servers.net, ns.level3.net
BACKBONE = [l.split() for l in (REPO / "files/etc/greybox/backbone.hosts").read_text().splitlines() if l.strip()]
# the first router name, and the gateway external clients see (12.0.0.41)
ROUTERS = [BACKBONE[0], next(h for h in BACKBONE if h[0] == "12.0.0.41")]


def dig(vm, args):
    """Answers of `dig +short args`, from CharlieUser1, as a list of lines."""
    return vm.charlie(f"dig +short +time=3 +tries=2 {args}").out.splitlines()


def test_root_server_refers_to_tld_servers(vm, vhost):
    """a.root-servers.net delegates the vhost's TLD to the in-sim TLD servers."""
    tld = vhost[0].rsplit(".", 1)[1]
    r = vm.charlie(f"dig +norec +time=3 @{ROOT} {tld}. NS")
    assert "ns.level3.net." in r.out, r.out


def test_tld_server_answers_vhost(vm, vhost):
    """ns.level3.net answers the vhost's A record authoritatively."""
    assert dig(vm, f"+norec @{TLD} {vhost[0]} A") == [vhost[1]]


def test_resolver_answers_vhost(vm, vhost):
    """The caching resolver 8.8.8.8 resolves the vhost (recursively, from the root)."""
    assert dig(vm, f"@{RESOLVER} {vhost[0]} A") == [vhost[1]]


def test_vhost_reverse_lookup(vm, vhost):
    """The vhost's address has a PTR record back to its name."""
    assert f"{vhost[0]}." in dig(vm, f"@{RESOLVER} -x {vhost[1]}")


def test_apex_alias(vm, vhost):
    """www.example.org is also served as example.org (when the apex resolves)."""
    name, _ = vhost
    apex = name.removeprefix("www.")
    ip = vm.sh(f"awk '$2 == \"{apex}\" {{ print $1 }}' /var/lib/topgen/etc/hosts.nginx").out
    if apex == name or not ip:
        pytest.skip(f"no apex alias for {name} in hosts.nginx")
    assert dig(vm, f"@{RESOLVER} {apex} A") == [ip]


@pytest.mark.parametrize("ip,name", ROUTERS, ids=[h[1] for h in ROUTERS])
def test_router_names(vm, ip, name):
    """Router interfaces from backbone.hosts resolve forward and reverse (traceroute shows names)."""
    assert dig(vm, f"@{RESOLVER} {name} A") == [ip]
    assert f"{name}." in dig(vm, f"@{RESOLVER} -x {ip}")


@pytest.mark.parametrize("host,ip,user,password", mail_servers(), ids=[m[0] for m in mail_servers()])
def test_mail_domain_mx(vm, host, ip, user, password):
    """Each vmail.cfg domain has an MX record naming its mail server, which resolves."""
    domain = host.split(".", 1)[1]
    assert dig(vm, f"@{RESOLVER} {domain} MX") == [f"10 {host}."]
    assert dig(vm, f"@{RESOLVER} {host} A") == [ip]


def test_user_record_from_hosts_custom(vm):
    """A line appended to /etc/topgen/hosts.custom resolves (A and PTR, made-up TLD
    included) after `topgen-boot reload-dns`. The file is restored afterwards."""
    if not vm.sh("grep -q reload-dns /usr/local/sbin/topgen-boot").ok:
        pytest.skip("this image has no topgen-boot reload-dns")
    ip, name = "12.0.0.77", "slatebox-test.range.lab"
    f, bak = "/etc/topgen/hosts.custom", "/run/hosts.custom.test-bak"
    reload = "greybox-ctl exec topgen.info topgen-boot reload-dns"
    assert vm.sh(f"touch {f} && cp -a {f} {bak} && echo '{ip} {name}' >> {f}").ok
    try:
        r = vm.sh(reload)
        assert r.ok, r.out
        assert dig(vm, f"@{RESOLVER} {name} A") == [ip]
        assert f"{name}." in dig(vm, f"@{RESOLVER} -x {ip}")
    finally:
        vm.sh(f"mv {bak} {f} && {reload}")


def test_external_client_resolves_vhost(ext, vhost):
    """An external client using 8.8.8.8 gets the sim's answer for the vhost."""
    r = ext.sh(f"dig +short +time=3 +tries=2 @{RESOLVER} {vhost[0]} A")
    assert r.out.splitlines() == [vhost[1]], r.out
