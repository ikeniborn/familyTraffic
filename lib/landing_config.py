"""Add the local website to the managed combined-mode Nginx configuration."""
import fnmatch
import json
import re
import sys
from pathlib import Path

SOCKET = "unix:/run/familytraffic-landing.sock"
MAP = "    map $ssl_preread_server_name $backend_addr {\n"
HTTP = "\nhttp {\n"


def check_names(domain, xray_path, transports):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*", domain):
        raise ValueError("Invalid landing page domain")
    inbounds = json.loads(Path(xray_path).read_text())["inbounds"]
    receivers = [i for i in inbounds if i.get("tag") == "vless-reality"]
    if len(receivers) != 1:
        raise ValueError("Expected one configured Reality receiver")
    names = receivers[0]["streamSettings"]["realitySettings"]["serverNames"]
    for name in [*names, *transports]:
        if fnmatch.fnmatchcase(domain, name.lower().rstrip(".")):
            raise ValueError(f"Landing page domain {domain} conflicts with VPN name {name}")


def render(text, domain, port):
    if text.count(MAP) != 1 or text.count(HTTP) != 1:
        raise ValueError("Cannot identify the managed stream map and HTTP block")
    # Replace only our own two blocks on repeated reconciliation.
    text = re.sub(r"(?ms)^ *# BEGIN FT LANDING\n.*?^ *# END FT LANDING\n", "", text)
    routes = text.split(MAP, 1)[1].split("}", 1)[0]
    for row in routes.splitlines():
        fields = row.partition("#")[0].split()
        if fields and fields[0].lower().rstrip(".") == domain:
            raise ValueError(f"Landing page domain {domain} already has a stream route")
    if not (port.isascii() and port.isdecimal() and 0 < int(port) <= 65535):
        raise ValueError("Invalid public VPN port")
    route = f"        # BEGIN FT LANDING\n        {domain} {SOCKET};\n        # END FT LANDING\n"
    authority = f"        {domain}:{port} 1;\n"
    if port == "443":
        authority += f"        {domain} 1;\n"
    block = f"""    # BEGIN FT LANDING
    map $http_host $landing_authority {{
        default 0;
{authority}    }}
    server {{
        listen {SOCKET} ssl;
        server_name {domain};
        ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
        ssl_protocols TLSv1.3;
        root /usr/share/familytraffic;
        default_type text/html;
        charset utf-8;
        if ($landing_authority = 0) {{ return 404; }}
        if ($request_method !~ ^(GET|HEAD)$) {{ return 405; }}
        location = / {{
            if ($request !~ "^(GET|HEAD) /([?][^ ]*)? HTTP/") {{ return 404; }}
            try_files /landing.html =404;
        }}
        location / {{ return 404; }}
    }}
    # END FT LANDING
"""
    return text.replace(MAP, MAP + route, 1).replace(HTTP, HTTP + block, 1)


if __name__ == "__main__":
    try:
        action, domain, port, xray, *transports = sys.argv[1:]
        domain = domain.lower()
        check_names(domain, xray, transports)
        if action == "render":
            sys.stdout.write(render(sys.stdin.read(), domain, port))
    except (ValueError, OSError, KeyError, TypeError) as error:
        sys.exit(str(error))
