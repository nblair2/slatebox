"""Mirrored sites are served over HTTPS with certificates from the TopGen CA."""
import json
import os
import sys
from pathlib import Path

import pytest

from conftest import CA


def curl(vhost, path="/", ca=CA):
    """curl command fetching https://VHOST/PATH, validating against the TopGen CA."""
    return f"curl -sSf -m 30 --cacert {ca} https://{vhost}{path}"


def test_sim_client_fetches_vhost(vm, vhost, expect):
    """From CharlieUser1, https://VHOST/ validates against the TopGen CA and shows the site."""
    r = vm.charlie(curl(vhost[0]))
    assert r.ok and expect.lower() in r.out.lower(), r.out[-2000:]


def test_apex_alias_served(vm, vhost):
    """https://example.org/ validates too when www.example.org has an apex alias."""
    apex = vhost[0].removeprefix("www.")
    if apex == vhost[0] or not vm.sh(f"grep -q ' {apex}$' /var/lib/topgen/etc/hosts.nginx").ok:
        pytest.skip(f"no apex alias for {vhost[0]}")
    r = vm.charlie(curl(apex) + " -o /dev/null")
    assert r.ok, r.out


def test_cert_has_crl_distribution_point(vm, vhost):
    """The vhost certificate points to the CRL on topgen.info."""
    r = vm.charlie(f"openssl s_client -connect {vhost[0]}:443 -servername {vhost[0]} </dev/null 2>/dev/null"
                   " | openssl x509 -noout -ext crlDistributionPoints")
    assert "http://topgen.info/topgen_ca.crl" in r.out, r.out


def test_crl_is_published_and_signed_by_ca(vm):
    """http://topgen.info/topgen_ca.crl downloads and verifies against the TopGen CA."""
    r = vm.charlie(f"curl -sSf -m 30 http://topgen.info/topgen_ca.crl | openssl crl -inform DER -CAfile {CA} -noout")
    assert r.ok and "verify OK" in r.out, r.out


def test_landing_page_lists_vhost(vm, vhost):
    """https://topgen.info/ lists the mirrored site."""
    r = vm.charlie(curl("topgen.info"))
    assert r.ok and vhost[0] in r.out, r.out[-2000:]


def test_external_client_downloads_ca(ext, ca_file):
    """External clients can fetch the CA certificate from http://topgen.info/topgen_ca.cer."""
    r = ext.sh("curl -sSf -m 30 http://topgen.info/topgen_ca.cer")
    assert r.ok and r.out.strip() == ca_file.read_text().strip(), r.out[-2000:]


def test_external_client_fetches_vhost(ext, vhost, expect, ca_file):
    """From outside, https://VHOST/ (resolved via 8.8.8.8) validates against the TopGen CA."""
    r = ext.sh(curl(vhost[0], ca=ca_file))
    assert r.ok and expect.lower() in r.out.lower(), r.out[-2000:]


def test_browser_renders_vhost_from_external_client(ext, vhost, expect, ca_file):
    """Headless Chromium outside the sim, trusting only the TopGen CA, renders the site:
    title or text mentions EXPECT, its same-site pages, styles and scripts load (other
    failures, e.g. images the mirror missed, are only printed), and an internal link works.
    Screenshots: browser-home.png, browser-link.png in --out."""
    pytest.importorskip("playwright")
    browse = Path(__file__).with_name("browse.py")
    env = {"PLAYWRIGHT_BROWSERS_PATH": os.environ.get("PLAYWRIGHT_BROWSERS_PATH",
                                                      Path.home() / ".cache/ms-playwright")}
    r = ext.as_user(f"{sys.executable} {browse} https://{vhost[0]}/ {ca_file} {ca_file.parent}", **env)
    assert r.ok, r.out
    res = json.loads(r.out.splitlines()[-1])
    assert "error" not in res, res["error"]
    home = res["home"]
    print(f"home: {home['status']} {home['title']!r}, {home['requests']} same-site responses,"
          f" failed: {home['failed']}")
    assert home["status"] == 200
    assert expect.lower() in (home["title"] + home["text"]).lower(), home["title"]
    assert not broken(home), "\n".join(home["failed"])
    assert "link" in res, "no internal link on the home page"
    link = res["link"]
    print(f"link: {link['status']} {link['url']} {link['title']!r}, failed: {link['failed']}")
    assert link["status"] == 200 and not broken(link), "\n".join(link["failed"])


def broken(visit):
    """Failed same-site requests that break a page (each is "STATUS-OR-ERROR TYPE URL")."""
    return [f for f in visit["failed"] if f.split()[1] in ("document", "stylesheet", "script")]
