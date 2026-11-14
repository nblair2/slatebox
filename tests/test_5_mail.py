"""Each vmail.cfg mail server takes IMAPS logins and authenticated SMTP submission."""
import time

import pytest

from conftest import CA, mail_servers

SERVERS = mail_servers()
IDS = [s[0] for s in SERVERS]


def imap(host_ip, user, password, url_path="", extra=""):
    """curl against imaps://imap.topgen.info (its cert name) at host_ip."""
    return (f"curl -sSf -m 30 --cacert {CA} --resolve imap.topgen.info:993:{host_ip} "
            f"--user {user}:{password} {extra} imaps://imap.topgen.info/{url_path}")


def smtp(host_ip, user, password, extra=""):
    """curl against smtp://smtp.topgen.info:587 (STARTTLS required) at host_ip."""
    return (f"curl -sSf -m 30 --ssl-reqd --cacert {CA} --resolve smtp.topgen.info:587:{host_ip} "
            f"--user {user}:{password} {extra} smtp://smtp.topgen.info:587/")


@pytest.mark.parametrize("host,ip,user,password", SERVERS, ids=IDS)
def test_imaps_login(vm, host, ip, user, password):
    """A vmail.cfg user logs in over IMAPS (certificate from the TopGen CA)."""
    r = vm.charlie(imap(ip, user, password))
    assert r.ok, r.out


@pytest.mark.parametrize("host,ip,user,password", SERVERS, ids=IDS)
def test_smtp_submission_auth(vm, host, ip, user, password):
    """A vmail.cfg user authenticates for SMTP submission on port 587."""
    r = vm.charlie(smtp(ip, user, password, "-X NOOP"))
    assert r.ok, r.out


@pytest.mark.skipif(len(SERVERS) < 2, reason="needs two mail domains in vmail.cfg")
def test_mail_crosses_domains(vm):
    """A message submitted on the first domain arrives in a mailbox of the second."""
    (h1, ip1, u1, p1), (h2, ip2, u2, p2) = SERVERS[:2]
    d1, d2 = h1.split(".", 1)[1], h2.split(".", 1)[1]
    subject = f"slatebox-test-{time.time_ns()}"
    r = vm.charlie(f"printf 'From: {u1}@{d1}\\r\\nTo: {u2}@{d2}\\r\\nSubject: {subject}\\r\\n\\r\\nhello\\r\\n' | "
                   + smtp(ip1, u1, p1, f"--mail-from {u1}@{d1} --mail-rcpt {u2}@{d2} -T -"))
    assert r.ok, f"submission failed: {r.out}"
    for _ in range(10):  # delivery is asynchronous
        r = vm.charlie(imap(ip2, u2, p2, "INBOX", f"-X 'SEARCH SUBJECT {subject}'"))
        if r.ok and r.out.split()[2:]:  # "* SEARCH 3"
            return
        time.sleep(3)
    pytest.fail(f"not in {u2}@{d2}'s INBOX after 30 s: {r.out}\n"
                + vm.node("topgen.info", "tail -20 /var/log/mail.log /var/log/dovecot.log").out)
