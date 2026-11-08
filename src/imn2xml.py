#!/usr/bin/env python3
"""Convert a legacy CORE .imn map (as shipped by greybox) to a CORE 9 XML scenario.

usage: imn2xml.py in.imn out.xml [--rj45 ethX=ens4 ...]

Routers/hosts/PCs become devices, lanswitches SWITCH networks, rj45 nodes RJ45
networks named after the given host NIC. Pseudo node pairs (links drawn across
the canvas edge) collapse into one direct link. Custom service files are kept
verbatim as templates; legacy UserDefined configs are passed through to the
slatebox UserDefined service. Anything not understood is an error.
"""
import argparse
import ast
import sys
import xml.etree.ElementTree as ET

DEVICE_MODELS = {"router", "host", "PC"}
DEFAULT_SERVICES = {"host": ["DefaultRoute"], "PC": ["DefaultRoute"]}
NETWORK_TYPES = {"lanswitch": "SWITCH", "rj45": "RJ45"}
LINK_OPTIONS = ("delay", "bandwidth")  # same units (us, bps) in .imn and CORE 9 XML
LINK_IGNORED = {"label", "color", "width", "mirror"}
TOP_IGNORED = {"canvas", "option", "annotation"}


def commands(text):
    """Split Tcl-ish text into commands (lists of words); {braced} words keep their raw text."""
    cmds, words, i = [], [], 0
    while i < len(text):
        c = text[i]
        if c == "\n":
            if words:
                cmds.append(words)
                words = []
            i += 1
        elif c.isspace():
            i += 1
        elif c == "{":
            depth, j = 1, i + 1
            while depth:
                depth += {"{": 1, "}": -1}.get(text[j], 0)
                j += 1
            words.append(text[i + 1 : j - 1])
            i = j
        else:
            j = i
            while j < len(text) and not text[j].isspace():
                j += 1
            words.append(text[i:j])
            i = j
    if words:
        cmds.append(words)
    return cmds


def config_body(raw):
    """Content of a `config {...}` block: lines between the braces, minus one leading tab."""
    return "".join(line.removeprefix("\t") + "\n" for line in raw.split("\n")[1:-1])


def network_config(raw):
    """Hostname and {ifname: 'addr/len'} from a network-config block (skips `!` lines)."""
    hostname, ips, iface = None, {}, None
    for words in map(str.split, raw.splitlines()):
        if words[:1] == ["hostname"]:
            hostname = words[1]
        elif words[:1] == ["interface"]:
            iface = words[1]
        elif words[:2] == ["ip", "address"]:
            ips[iface] = words[2]
    return hostname, ips


def parse_node(name, raw):
    node = {"name": name, "peers": [], "ips": {}, "services": None, "configs": {}, "files": {}}
    for key, *vals in commands(raw):
        if key == "network-config":
            node["hostname"], node["ips"] = network_config(vals[0])
        elif key == "interface-peer":
            node["peers"].append(tuple(vals[0].split()))
        elif key == "services":
            node["services"] = vals[0].split()
        elif key == "iconcoords":
            node["xy"] = vals[0].split()[:2]
        elif key == "custom-config":
            cc = {k: v[0] for k, *v in commands(vals[0])}
            kind, svc, *fname = cc["custom-config-id"].split(":", 2)
            if kind != "service":
                sys.exit(f"{name}: unsupported custom-config {cc['custom-config-id']}")
            if fname:
                node["files"][(svc, fname[0])] = config_body(cc["config"])
            else:
                node["configs"][svc] = config_body(cc["config"])
        else:
            node[key] = vals[0] if vals else None
    return node


def parse(text):
    nodes, links = {}, []
    for kind, *rest in commands(text):
        if kind == "node":
            nodes[rest[0]] = parse_node(*rest)
        elif kind == "link":
            link = {"name": rest[0]}
            for key, *vals in commands(rest[1]):
                if key not in {*LINK_OPTIONS, *LINK_IGNORED, "nodes"}:
                    sys.exit(f"link {rest[0]}: unsupported option {key}")
                link[key] = vals[0]
            links.append(link)
        elif kind not in TOP_IGNORED:
            sys.exit(f"unsupported top-level block: {kind}")
    return nodes, links


def node_id(name):
    return name.removeprefix("n")


def userdefined_configs(text):
    """Legacy UserDefined `key=('a', 'b',)` lines, checked and passed through verbatim."""
    configs = {}
    for line in text.splitlines():
        key, _, value = line.partition("=")
        ast.literal_eval(value)
        configs[key] = value
    return configs


def convert(text, rj45=None):
    rj45 = rj45 or {}
    nodes, links = parse(text)
    scenario = ET.Element("scenario", name="greybox")
    networks = ET.SubElement(scenario, "networks")
    devices = ET.SubElement(scenario, "devices")
    xml_links = ET.SubElement(scenario, "links")
    service_cfgs = ET.SubElement(scenario, "service_configurations")
    cdata = []  # template texts, put back as CDATA after serializing

    def rj45_nic(n):
        if n["hostname"] not in rj45:
            sys.exit(f"{n['name']}: no --rj45 {n['hostname']}=<host nic> given")
        return rj45[n["hostname"]]

    for n in nodes.values():
        kind, model, nid = n["type"], n.get("model"), node_id(n["name"])
        if kind == "pseudo":
            continue
        if kind == "router" and model in DEVICE_MODELS:
            el = ET.SubElement(devices, "device", id=nid, name=n["hostname"], type=model)
        elif kind in NETWORK_TYPES:
            name = rj45_nic(n) if kind == "rj45" else n["hostname"]
            el = ET.SubElement(networks, "network", id=nid, name=name, type=NETWORK_TYPES[kind])
        else:
            sys.exit(f"{n['name']}: unsupported node type {kind}/{model}")
        if "xy" in n:
            ET.SubElement(el, "position", x=n["xy"][0], y=n["xy"][1])
        if el.tag == "network":
            continue
        services = n["services"] if n["services"] is not None else DEFAULT_SERVICES.get(model, [])
        svc_list = ET.SubElement(el, "services")
        for s in services:
            ET.SubElement(svc_list, "service", name=s)
            cfg = ET.Element("service", name=s, node=nid)
            if s == "UserDefined" and s in n["configs"]:
                configs = ET.SubElement(cfg, "configs")
                for key, value in userdefined_configs(n["configs"][s]).items():
                    ET.SubElement(configs, "config", key=key, value=value)
            files = [(f, body) for (svc, f), body in n["files"].items() if svc == s]
            if files:
                templates = ET.SubElement(cfg, "templates")
                for f, body in files:
                    # CORE dedents/expands tabs (inspect.cleandoc), then renders
                    # with Mako; <%text> keeps the content literal.
                    if "\t" in body or "</%text>" in body:
                        sys.exit(f"{n['name']}: {f} has a tab or </%text>, CORE would alter it")
                    cdata.append(f"<%text>{body}</%text>")
                    ET.SubElement(templates, "template", name=f).text = f"@CDATA{len(cdata)}@"
            if len(cfg):
                service_cfgs.append(cfg)

    ports = {}  # (node, peer) -> node's ports facing peer
    for n in nodes.values():
        for port, peer in dict.fromkeys(n["peers"]):  # drops duplicated switch ports
            ports.setdefault((n["name"], peer), []).append(port)

    def ends(a, b):
        """Both real ends of link a-b as (node, peer it faces); a pseudo node
        stands for the node attached to its mirror."""
        result = []
        for x, y in ((a, b), (b, a)):
            if nodes[x]["type"] == "pseudo":
                mirror = nodes[x]["mirror"]
                x, y = nodes[mirror]["peers"][0][1], mirror
            result.append((x, y))
        # devices first: CORE gives iface1 to node1, and switches take no iface
        return sorted(result, key=lambda e: nodes[e[0]]["type"] != "router")

    def iface(tag, name, peer):
        n, port = nodes[name], ports[(name, peer)].pop(0)
        if n["type"] == "rj45":
            return ET.Element(tag, id="0", name=rj45_nic(n))
        if n["type"] != "router":
            return None
        attrs = {"id": port.removeprefix("eth"), "name": port}
        if port in n["ips"]:
            attrs["ip4"], attrs["ip4_mask"] = n["ips"][port].split("/")
        return ET.Element(tag, attrs)

    seen = set()
    for link in links:
        pair = ends(*link["nodes"].split())
        if frozenset(pair) in seen:  # the mirror half of a pseudo pair
            continue
        seen.add(frozenset(pair))
        el = ET.SubElement(xml_links, "link", node1=node_id(pair[0][0]), node2=node_id(pair[1][0]))
        for tag, end in zip(("iface1", "iface2"), pair):
            i = iface(tag, *end)
            if i is not None:
                el.append(i)
        opts = {k: link[k] for k in LINK_OPTIONS if k in link}
        if opts:
            ET.SubElement(el, "options", opts)

    ET.indent(scenario)
    xml = ET.tostring(scenario, encoding="unicode", xml_declaration=True) + "\n"
    for i, t in enumerate(cdata, 1):
        xml = xml.replace(f"@CDATA{i}@", "<![CDATA[" + t.replace("]]>", "]]]]><![CDATA[>") + "]]>", 1)
    return xml


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("imn")
    ap.add_argument("xml")
    ap.add_argument("--rj45", action="append", default=[], metavar="MAPNAME=HOSTNIC")
    args = ap.parse_args()
    with open(args.imn) as f:
        xml = convert(f.read(), dict(m.split("=", 1) for m in args.rj45))
    with open(args.xml, "w") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
