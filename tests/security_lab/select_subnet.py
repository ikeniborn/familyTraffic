"""Choose an unused internal lab subnet without changing daemon configuration."""
import ipaddress
import json
import subprocess


def output(args):
    return subprocess.check_output(args, text=True)


used = []
identifiers = output(["docker", "network", "ls", "-q"]).split()
if identifiers:
    for network in json.loads(output(["docker", "network", "inspect", *identifiers])):
        for config in network.get("IPAM", {}).get("Config") or []:
            if config.get("Subnet"):
                used.append(ipaddress.ip_network(config["Subnet"]))
for route in json.loads(output(["ip", "-j", "-4", "route", "show"])):
    if route.get("dst") not in (None, "default"):
        used.append(ipaddress.ip_network(route["dst"], strict=False))
for candidate in ipaddress.ip_network("198.18.0.0/15").subnets(new_prefix=24):
    if not any(candidate.version == network.version and candidate.overlaps(network) for network in used):
        print(candidate)
        break
else:
    raise SystemExit("No unused isolated benchmarking subnet available")
