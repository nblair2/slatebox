"""imn2xml.py against the vendored greybox backbone map (python3 -m pytest tests)."""

import ast
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
import imn2xml

MAPS = ROOT / "vendor/greybox/share/maps"
CORE_PYTHON = Path("/opt/core/venv/bin/python")

# Service names in CORE 9.2.1 (daemon/core/services/defaults) plus ours.
SERVICES = set(
    "FRRzebra FRROSPFv2 FRROSPFv3 FRRBGP FRRRIP FRRRIPNG FRRBabel FRRpimd "
    "MGEN_Sink NHDP SMF OLSR OLSRv2 OLSRORG MgenActor zebra OSPFv2 OSPFv3 "
    "OSPFv3MDR BGP RIP RIPNG Babel Xpimd VPNClient VPNServer IPsec Firewall NAT "
    "DefaultRoute DefaultMulticastRoute StaticRoute IPForward SSH DHCP "
    "DHCPClient FTP pcap radvd atd HTTP UserDefined".split()
)
FILES = {"FRRzebra": "/usr/local/etc/frr/frr.conf", "DHCP": "/etc/dhcp/dhcpd.conf"}


@pytest.fixture(scope="module")
def imn():
    return (MAPS / "backbone.imn").read_text()


@pytest.fixture(scope="module")
def xml(imn):
    return imn2xml.convert(imn)


@pytest.fixture(scope="module")
def root(xml):
    return ET.fromstring(xml.encode())


def links(root):
    return root.findall("links/link")


def test_nodes(root):
    devices = root.findall("devices/device")
    assert sum(d.get("type") == "router" for d in devices) == 69
    assert {d.get("name") for d in devices if d.get("type") != "router"} == {
        "topgen.info",
        "DeltaUser1",
        "CharlieUser1",
    }
    assert [(n.get("id"), n.get("type")) for n in root.findall("networks/network")] == [("300", "SWITCH")]


def test_switch_links(root):
    to_switch = [link.get("node1") for link in links(root) if link.get("node2") == "300"]
    assert len(to_switch) == len(set(to_switch)) == 70


def test_pseudo_links_collapsed(root):
    by_pair = {(link.get("node1"), link.get("node2")): link for link in links(root)}
    for pair, delay in {("111", "160"): "80000", ("115", "136"): "52000", ("126", "151"): "58000"}.items():
        assert by_pair[pair].find("options").get("delay") == delay
        assert by_pair[pair].find("iface1").get("ip4") and by_pair[pair].find("iface2").get("ip4")
    pseudo = {"11", "12", "21", "22", "31", "32"}
    assert not pseudo & {link.get(k) for link in links(root) for k in ("node1", "node2")}
    assert len(links(root)) == 237 - 3


def test_interface_ips_match_hosts_file(root):
    hosts = {line.split()[0] for line in (MAPS / "../etc/backbone.hosts").read_text().splitlines() if line.strip()}
    ips = {i.get("ip4") for link in links(root) for i in link if i.tag.startswith("iface") and i.get("ip4")}
    clients = {"12.0.0.46", "12.0.0.54"}
    assert ips - clients <= hosts and len(ips) > 300


def test_frr_conf_verbatim(imn, root):
    expected = {
        m["host"]: "".join(line.removeprefix("\t") + "\n" for line in m["body"].split("\n"))
        for m in re.finditer(
            r"hostname (?P<host>\S+)(?:(?!\nnode ).)*?service:FRRzebra:/usr/local/etc/frr/frr.conf\n"
            r".*?config \{\n(?P<body>.*?)\n\t\}\n",
            imn,
            re.S,
        )
    }
    names = {d.get("id"): d.get("name") for d in root.findall("devices/device")}
    templates = {
        names[s.get("node")]: t.text
        for s in root.findall("service_configurations/service[@name='FRRzebra']")
        for t in s.findall("templates/template")
    }
    assert len(expected) == 69
    assert templates == {h: f"<%text>{body}</%text>" for h, body in expected.items()}


def test_service_names_and_files(root):
    for device in root.findall("devices/device"):
        assert {s.get("name") for s in device.findall("services/service")} <= SERVICES
    for svc in root.findall("service_configurations/service"):
        name = svc.get("name")
        allowed = {FILES.get(name)}
        files = svc.find("configs/config[@key='files']")
        if files is not None:
            allowed |= set(ast.literal_eval(files.get("value")))
        assert {t.get("name") for t in svc.findall("templates/template")} <= allowed


def test_cdata_roundtrip(xml, root):
    assert "<![CDATA[<%text>#!/bin/sh" in xml
    boot = root.find("service_configurations/service[@node='301']/templates/template").text
    assert "pidof named && pidof nginx" in boot


def test_rj45(tmp_path):
    out = imn2xml.convert((MAPS / "backbone_ext.imn").read_text(), {"ethX": "ens4"})
    root = ET.fromstring(out.encode())
    assert root.find("networks/network[@type='RJ45']").get("name") == "ens4"
    link = root.find("links/link[@node2='410']")
    assert link.find("iface2").get("name") == "ens4"


@pytest.mark.skipif(not CORE_PYTHON.exists(), reason="CORE not installed")
def test_core_loads_xml(xml, tmp_path):
    """CORE's own reader accepts the scenario and renders templates back to the map text."""
    path = tmp_path / "backbone.xml"
    path.write_text(xml)
    script = f"""
from pathlib import Path
from core.emulator.coreemu import CoreEmu
emu = CoreEmu({{"custom_services_dir": "{ROOT}/src/core_services"}})
s = emu.create_session(9999)
try:
    s.open_xml(Path("{path}"))
    for node in s.nodes.values():
        for svc in getattr(node, "services", {{}}).values():
            for name, text in svc.custom_templates.items():
                assert svc.get_rendered_templates()[name] == text[len("<%text>"):-len("</%text>")], name
    print(len(s.nodes))
finally:
    emu.shutdown()
"""
    env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/frr"}
    out = subprocess.run([CORE_PYTHON, "-I", "-c", script], env=env, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert out.stdout.split() == ["73"]
