"""Load a page in headless Chromium the way a user would and report what happened.

usage: browse.py URL CA_CERT OUT_DIR
Prints one JSON object. CA_CERT is trusted through an NSS database in a fresh
$HOME (Chromium on Linux reads ~/.pki/nssdb), so the TLS chain is validated
for real; certificate errors are not ignored. Run by test_4_web.py as the
invoking user inside the "ext" network namespace.
"""

import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlsplit

from playwright.sync_api import sync_playwright


def trust(ca):
    home = tempfile.mkdtemp(prefix="browse-")
    db = f"sql:{home}/.pki/nssdb"
    os.makedirs(f"{home}/.pki/nssdb")
    subprocess.run(["certutil", "-N", "-d", db, "--empty-password"], check=True)
    subprocess.run(["certutil", "-A", "-d", db, "-t", "C,,", "-n", "topgen_ca", "-i", ca], check=True)
    os.environ["HOME"] = home


def visit(page, url, shot, host):
    """Load url; return status, title, text, and same-site request URLs and failures."""
    requested, failed = set(), {}

    def on_request(req):
        if urlsplit(req.url).hostname == host:
            requested.add(req.url)

    def on_response(resp):
        if resp.url in requested and resp.status >= 400:
            failed[resp.url] = f"{resp.status} {resp.request.resource_type}"

    def on_failed(req):
        if req.url in requested:
            failed.setdefault(req.url, f"{req.failure} {req.resource_type}")

    page.on("request", on_request)
    page.on("response", on_response)
    page.on("requestfailed", on_failed)
    resp = page.goto(url, wait_until="load", timeout=60_000)
    try:
        page.wait_for_load_state("networkidle", timeout=15_000)
    except Exception:  # noqa: BLE001, S110
        pass  # pages with pollers never go idle; "load" is enough
    page.screenshot(path=shot, full_page=True)
    for event, fn in (("request", on_request), ("response", on_response), ("requestfailed", on_failed)):
        page.remove_listener(event, fn)
    return {
        "url": page.url,
        "status": resp.status if resp else None,
        "title": page.title(),
        "text": page.inner_text("body")[:20000],
        "requested": len(requested),
        "failed": [f"{why} {u}" for u, why in failed.items()],
    }


def main(url, ca, out):
    trust(ca)
    host = urlsplit(url).hostname
    result = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        try:
            result["home"] = visit(page, url, f"{out}/browser-home.png", host)
            links = page.eval_on_selector_all("a[href]", "as => as.map(a => a.href)")
            internal = [
                l
                for l in links
                if urlsplit(l).hostname == host and urlsplit(l).path not in ("", "/", urlsplit(url).path)
            ]
            if internal:
                result["link"] = visit(page, urljoin(url, internal[0]), f"{out}/browser-link.png", host)
        except Exception as e:  # noqa: BLE001 (reported in the JSON), e.g. net::ERR_CERT_AUTHORITY_INVALID
            result["error"] = str(e).splitlines()[0]
        browser.close()
    print(json.dumps(result))


if __name__ == "__main__":
    main(*sys.argv[1:])
