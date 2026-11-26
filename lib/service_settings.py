"""Read managed deployment settings without executing the environment file."""
import json
import re
import sys
from pathlib import Path

KEYS = (
    "FT_SERVICE_MODE", "FT_VLESS_PUBLIC_PORT", "FT_HTTPS_PROXY_PORT",
    "FT_SOCKS_TLS_PORT", "FT_HTTP_PLAIN_PORT", "FT_SOCKS_PLAIN_PORT",
)
FLAGS = {"ENABLE_PUBLIC_PROXY", "ENABLE_PROXY_TLS", "PROXY_NOTLS_ENABLED"}


def read_fields(path):
    fields = {}
    for line in path.read_text().splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in (*KEYS, *FLAGS):
            continue
        if key in fields and fields[key] != value:
            raise ValueError(f"{path}: conflicting {key}")
        fields[key] = value
    return fields


def legacy_settings(xray, nginx, flags):
    receivers = json.loads(xray.read_text())["inbounds"]
    tags = {r.get("tag"): r for r in receivers}
    if len(tags) != len(receivers):
        raise ValueError(f"{xray}: duplicate receiver tag")
    expected = tags.keys() & {"http-proxy", "socks5-proxy"}
    vpn = "vless-reality" in tags
    if expected and len(expected) != 2 or not (expected or vpn):
        raise ValueError(f"{xray}: incomplete legacy receiver set")
    public = flags.get("ENABLE_PUBLIC_PROXY", str(bool(expected)).lower())
    if public != str(bool(expected)).lower():
        raise ValueError(f"{xray}: receiver tags conflict with ENABLE_PUBLIC_PROXY")
    for tag, protocol, port in (("http-proxy", "http", 18118), ("socks5-proxy", "socks", 10800),
                                 ("vless-reality", "vless", 8443)):
        if tag in tags and (tags[tag].get("protocol"), tags[tag].get("port")) != (protocol, port):
            raise ValueError(f"{xray}: conflicting protocol or port for {tag}")
    values = dict.fromkeys(KEYS, "")
    values["FT_SERVICE_MODE"] = ("both" if vpn else "proxy") if expected else "vpn"
    content = re.sub(r"#[^\n]*", "", nginx.read_text())
    if re.search(r"\binclude\s|\bdeny\s|\ballow\s+(?!all;)", content):
        raise ValueError(f"{nginx}: unrecognized include or access restriction")
    stream = re.search(r"\bstream\s*\{(.*?)^\}", content, re.M | re.S)
    if not stream:
        raise ValueError(f"{nginx}: missing managed stream block")
    blocks = re.findall(r"\bserver\s*\{([^{}]*)\}", stream[1], re.S)
    for block in blocks:
        target = re.search(r"\bproxy_pass\s+(\$backend_addr|127\.0\.0\.1:(?:18118|10800))\s*;", block)
        if not target:
            raise ValueError(f"{nginx}: unrecognized stream backend")
        listeners = re.findall(r"\blisten\s+([^;]+);", block)
        match = re.fullmatch(r"(\d+)(\s+ssl)?", listeners[0].strip()) if len(listeners) == 1 else None
        if not match or re.search(r"\b(?:deny|allow|include|access_by_lua_block)\b", block):
            raise ValueError(f"{nginx}: unrecognized listener or access restriction")
        port, tls = match.groups()
        if target[1] == "$backend_addr":
            if not re.search(r"default\s+127\.0\.0\.1:8443;", content) or tls:
                raise ValueError(f"{nginx}: conflicting Reality backend")
            if not vpn and port == "443":
                continue
            field = "FT_VLESS_PUBLIC_PORT"
        elif not expected:
            conventional = {"127.0.0.1:18118": ("8118", "8119"), "127.0.0.1:10800": ("1080", "1081")}
            if port not in conventional[target[1]]:
                raise ValueError(f"{nginx}: custom unused proxy listener {port}")
            continue
        elif target[1].endswith(":18118"):
            field = "FT_HTTPS_PROXY_PORT" if tls else "FT_HTTP_PLAIN_PORT"
        else:
            field = "FT_SOCKS_TLS_PORT" if tls else "FT_SOCKS_PLAIN_PORT"
        if values[field]:
            raise ValueError(f"{nginx}: duplicate listener for {field}")
        values[field] = port
    if expected:
        tls = flags.get("ENABLE_PROXY_TLS", str(bool(values["FT_HTTPS_PROXY_PORT"])).lower())
        if tls not in ("true", "false") or (tls == "true") != bool(values["FT_HTTPS_PROXY_PORT"]):
            raise ValueError(f"{nginx}: HTTP transport conflicts with ENABLE_PROXY_TLS")
        socks = values["FT_SOCKS_TLS_PORT"] if tls == "true" else values["FT_SOCKS_PLAIN_PORT"]
        if not socks:
            raise ValueError(f"{nginx}: missing public SOCKS receiver")
        if bool(values["FT_HTTP_PLAIN_PORT"]) != bool(values["FT_SOCKS_PLAIN_PORT"]):
            raise ValueError(f"{nginx}: incomplete legacy plaintext endpoints")
        if tls == "true" and "PROXY_NOTLS_ENABLED" in flags:
            if flags["PROXY_NOTLS_ENABLED"] != str(bool(values["FT_HTTP_PLAIN_PORT"])).lower():
                raise ValueError(f"{nginx}: plaintext listeners conflict with PROXY_NOTLS_ENABLED")
    return values


def read_settings(root):
    fields = read_fields(root / ".env")
    legacy = not any(key in fields for key in KEYS)
    if legacy:
        values = legacy_settings(root / "config/xray_config.json", root / "config/nginx/nginx.conf", fields)
    else:
        for key in KEYS:
            if key not in fields:
                raise ValueError(f".env: missing {key}")
        values = {key: fields[key] for key in KEYS}
        compatibility = {
            "ENABLE_PUBLIC_PROXY": values["FT_SERVICE_MODE"] in ("proxy", "both"),
            "ENABLE_PROXY_TLS": bool(values["FT_HTTPS_PROXY_PORT"]),
            "PROXY_NOTLS_ENABLED": bool(values["FT_HTTP_PLAIN_PORT"]),
        }
        for flag, enabled in compatibility.items():
            if flag in fields and fields[flag] != str(enabled).lower():
                raise ValueError(f".env: {flag} conflicts with saved service ports")
    values["FT_LEGACY_SERVICE_SETTINGS"] = "true" if legacy else "false"
    return values


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--legacy-health":
            endpoints = legacy_settings(Path(sys.argv[2]), Path(sys.argv[3]), {})
            for field in KEYS[1:]:
                if endpoints[field]:
                    print(int(endpoints[field]))
            if endpoints["FT_VLESS_PUBLIC_PORT"]:
                print(8443)
            if endpoints["FT_HTTPS_PROXY_PORT"] or endpoints["FT_HTTP_PLAIN_PORT"]:
                print(18118)
            if endpoints["FT_SOCKS_TLS_PORT"] or endpoints["FT_SOCKS_PLAIN_PORT"]:
                print(10800)
        else:
            for key, value in read_settings(Path(sys.argv[1])).items():
                print(f"{key}={value}")
    except (OSError, KeyError, TypeError, ValueError) as error:
        sys.exit(str(error))
