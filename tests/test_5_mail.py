"""Mail: accounts written to /etc/topgen/vmail.cfg log in and exchange mail after
`topgen-boot reload-mail`; port 25 takes mail for a mirrored site's domain from
anyone (into the catch-all mailbox) but relays nothing."""

import shlex
import time

import pytest

from conftest import CA

CFG, BAK = "/etc/topgen/vmail.cfg", "/run/vmail.cfg.test-bak"
RELOAD = "greybox-ctl exec topgen.info topgen-boot reload-mail"
# (server, ip, user, password)
ACCOUNTS = [
    ("mail.slatebox-one.lab", "203.0.113.25", "alice", "test-pw1"),
    ("mail.slatebox-two.lab", "203.0.113.26", "bob", "test-pw2"),
]
IDS = [a[0] for a in ACCOUNTS]


def address(account):
    server, _, user, _ = account
    return f"{user}@{server.split('.', 1)[1]}"


def imap(ip, user, password, extra=""):
    """curl against imaps://imap.topgen.info (its cert name) at ip."""
    return (
        f"curl -sSf -m 30 --cacert {CA} --resolve imap.topgen.info:993:{ip} "
        f"--user {user}:{password} {extra} imaps://imap.topgen.info/INBOX"
    )


def smtp(ip, port, frm, rcpt, subject, extra=""):
    """curl sending a short message to rcpt over SMTP at ip:port."""
    msg = f"printf 'From: {frm}\\r\\nTo: {rcpt}\\r\\nSubject: {subject}\\r\\n\\r\\nhello\\r\\n'"
    return (
        f"{msg} | curl -sSf -m 30 --resolve smtp.topgen.info:{port}:{ip} {extra} "
        f"--mail-from {frm} --mail-rcpt {rcpt} -T - smtp://smtp.topgen.info:{port}/"
    )


def submit(vm, account, rcpt, subject):
    """Authenticated submission on port 587 (STARTTLS required)."""
    _, ip, user, password = account
    tls = f"--ssl-reqd --cacert {CA} --user {user}:{password}"
    return vm.charlie(smtp(ip, 587, address(account), rcpt, subject, tls))


def eventually(check, tries=10):
    """Delivery is asynchronous: retry check() for up to 30 s."""
    for _ in range(tries):
        if check():
            return True
        time.sleep(3)
    return False


@pytest.fixture(scope="module", autouse=True)
def accounts(vm):
    """vmail.cfg holds only ACCOUNTS while this module runs."""
    lines = [f"{s} {ip} {u}:{p}" for s, ip, u, p in ACCOUNTS]
    assert vm.sh(f"cp -a {CFG} {BAK} && printf '%s\\n' {shlex.join(lines)} > {CFG}").ok
    try:
        r = vm.sh(RELOAD)
        assert r.ok, r.out
        yield
    finally:
        vm.sh(f"mv {BAK} {CFG} && {RELOAD}")


@pytest.fixture(scope="module")
def site(vhost, mail_domains):
    """(server, ip) of the vhost's generated mail domain."""
    server = "mail." + ".".join(vhost[0].split(".")[-2:])
    ip = dict(mail_domains).get(server)
    assert ip, f"no {server} among {mail_domains}"
    return server, ip


@pytest.mark.parametrize("account", ACCOUNTS, ids=IDS)
def test_imaps_login(vm, account):
    """The account logs in over IMAPS (certificate from the TopGen CA)."""
    _, ip, user, password = account
    r = vm.charlie(imap(ip, user, password))
    assert r.ok, r.out


def test_mail_crosses_domains(vm):
    """Mail submitted by one account arrives in the other's INBOX."""
    sender, rcpt = ACCOUNTS
    subject = f"slatebox-test-{time.time_ns()}"
    r = submit(vm, sender, address(rcpt), subject)
    assert r.ok, f"submission failed: {r.out}"
    _, ip, user, password = rcpt
    search = imap(ip, user, password, f"-X 'SEARCH SUBJECT {subject}'")

    def found():
        r = vm.charlie(search)
        return r.ok and r.out.split()[2:]  # "* SEARCH 3"

    assert eventually(found), vm.node("topgen.info", "tail -n 20 /var/log/mail.log /var/log/dovecot.log").out


def test_site_receives_on_port_25(vm, site):
    """Unauthenticated mail to a mirrored site's domain lands in the catch-all DFLT."""
    server, ip = site
    subject = f"slatebox-test-{time.time_ns()}"
    r = vm.charlie(smtp(ip, 25, "someone@example.net", f"nobody@{server.split('.', 1)[1]}", subject))
    assert r.ok, r.out
    assert eventually(lambda: vm.sh(f"grep -qs {subject} /var/lib/topgen/vmail/DFLT").ok), vm.node(
        "topgen.info", "tail -n 20 /var/log/mail.log"
    ).out


def test_port_25_does_not_relay(vm, site):
    """Unauthenticated mail to an outside domain is refused."""
    r = vm.charlie(smtp(site[1], 25, "someone@example.net", "victim@example.org", "slatebox-test-relay"))
    assert not r.ok and "RCPT" in r.out, r.out
