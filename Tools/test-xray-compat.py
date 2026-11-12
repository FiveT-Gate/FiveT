"""Does the new Xray accept every config shape FiveT's V2RayConfig.forLaunch writes?
Builds FiveT's TUN config around one dummy outbound per protocol and transport (dummy IDs and keys, no real
server) and runs `xray run -test` with the old and the new binary. Prints any difference; exits 1 if the new one rejects a shape the old one accepted.
Usage: python3 -I Tools/test-xray-compat.py <old xray> <new xray> <dir holding geoip-lite.dat>"""
import base64
import copy
import json
import os
import re
import subprocess
import sys
import tempfile

old, new, assets = sys.argv[1], sys.argv[2], sys.argv[3]
UUID = "11111111-2222-4333-8444-555555555555"
PBK = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode()
SS2022 = base64.b64encode(bytes(range(16))).decode()
SRV = {"address": "server.example.com", "port": 443}


def vless(stream, flow=None):
    user = {"id": UUID, "encryption": "none"}
    if flow:
        user["flow"] = flow
    return {"protocol": "vless", "settings": {"vnext": [dict(SRV, users=[user])]}, "streamSettings": stream}


def tls(**more):
    return dict({"serverName": "server.example.com", "fingerprint": "chrome", "alpn": ["h2", "http/1.1"]}, **more)


REALITY = {"publicKey": PBK, "fingerprint": "chrome", "serverName": "www.example.com", "shortId": "ab12", "spiderX": "/"}
HOSTPATH = {"path": "/p", "host": "cdn.example.com"}

VARIANTS = {
    "vless reality tcp vision": vless({"network": "tcp", "security": "reality", "realitySettings": REALITY}, "xtls-rprx-vision"),
    "vless reality grpc": vless({"network": "grpc", "grpcSettings": {"serviceName": "svc", "multiMode": True}, "security": "reality", "realitySettings": REALITY}),
    "vless reality xhttp": vless({"network": "xhttp", "xhttpSettings": {"path": "/x", "mode": "auto"}, "security": "reality", "realitySettings": REALITY}),
    "vless tls ws": vless({"network": "ws", "wsSettings": HOSTPATH, "security": "tls", "tlsSettings": tls()}),
    "vless tls httpupgrade": vless({"network": "httpupgrade", "httpupgradeSettings": HOSTPATH, "security": "tls", "tlsSettings": tls()}),
    "vless tls xhttp": vless({"network": "xhttp", "xhttpSettings": dict(HOSTPATH, mode="stream-up"), "security": "tls", "tlsSettings": tls()}),
    "vless tls grpc": vless({"network": "grpc", "grpcSettings": {"serviceName": "svc", "authority": "a.example.com"}, "security": "tls", "tlsSettings": tls()}),
    "vless tls http (h2)": vless({"network": "http", "httpSettings": {"path": "/h", "host": ["a.example.com"]}, "security": "tls", "tlsSettings": tls()}),
    "vmess tcp http header": {"protocol": "vmess", "settings": {"vnext": [dict(SRV, users=[{"id": UUID, "security": "auto"}])]},
                              "streamSettings": {"network": "tcp", "tcpSettings": {"header": {"type": "http", "request": {"path": ["/"], "headers": {"Host": ["a.example.com"]}}}}}},
    "vmess kcp": {"protocol": "vmess", "settings": {"vnext": [dict(SRV, users=[{"id": UUID, "security": "auto"}])]},
                  "streamSettings": {"network": "kcp", "kcpSettings": {"header": {"type": "wechat-video"}, "seed": "abc"}}},
    "vless tls pinned": vless({"network": "tcp", "security": "tls", "tlsSettings": tls(pinnedPeerCertificateChainSha256=[base64.b64encode(bytes(32)).decode()])}),
    "vless reality mldsa65Verify": vless({"network": "tcp", "security": "reality", "realitySettings": dict(REALITY)}, "xtls-rprx-vision"),
    "vmess ws tls": {"protocol": "vmess", "settings": {"vnext": [dict(SRV, users=[{"id": UUID, "alterId": 0, "security": "auto"}])]},
                      "streamSettings": {"network": "ws", "wsSettings": HOSTPATH, "security": "tls", "tlsSettings": tls()}},
    "vmess tcp": {"protocol": "vmess", "settings": {"vnext": [dict(SRV, users=[{"id": UUID, "security": "auto"}])]}, "streamSettings": {"network": "tcp"}},
    "trojan tls tcp": {"protocol": "trojan", "settings": {"servers": [dict(SRV, password="pw")]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": tls()}},
    "trojan tls ws": {"protocol": "trojan", "settings": {"servers": [dict(SRV, password="pw")]},
                      "streamSettings": {"network": "ws", "wsSettings": HOSTPATH, "security": "tls", "tlsSettings": tls()}},
    "shadowsocks aead": {"protocol": "shadowsocks", "settings": {"servers": [dict(SRV, method="chacha20-ietf-poly1305", password="pw")]}},
    "shadowsocks 2022": {"protocol": "shadowsocks", "settings": {"servers": [dict(SRV, method="2022-blake3-aes-128-gcm", password=SS2022)]}},
    "hysteria2": {"protocol": "hysteria", "settings": {"version": 2, "address": "server.example.com", "port": 443},
                  "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": tls(alpn=["h3"]), "hysteriaSettings": {"version": 2, "auth": "pw"}}},
    "hysteria2 salamander": {"protocol": "hysteria", "settings": {"version": 2, "address": "server.example.com", "port": 443},
                             "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": tls(alpn=["h3"]), "hysteriaSettings": {"version": 2, "auth": "pw"},
                                                "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "obfs"}}]}}},
}


def config(proxy, iran_direct, names):
    proxy = copy.deepcopy(proxy)
    proxy["tag"] = "proxy"
    rules = [
        {"inboundTag": ["tun"], "network": "udp", "port": "53", "outboundTag": "dns-out"},
        {"inboundTag": ["tun"], "network": "udp", "outboundTag": "block"},
        {"ip": ["ext:geoip-lite.dat:private"], "outboundTag": "direct"},
        {"ip": ["203.0.113.7"], "outboundTag": "direct"},
    ]
    servers = []
    if iran_direct:
        rules.append({"domain": ["domain:ir"], "outboundTag": "direct"})
        rules.append({"ip": ["ext:geoip-lite.dat:ir"], "outboundTag": "direct"})
        servers.append({"address": "192.168.1.1", "domains": ["domain:ir"], "skipFallback": True})
    servers += ["tcp://1.1.1.1", "tcp://8.8.8.8"]
    if iran_direct:
        servers.append({"address": "192.168.1.1", "expectIPs": ["ext:geoip-lite.dat:ir"]})
    dns = {"tag": "dns-internal", "queryStrategy": "UseIPv4", "servers": servers}
    if names:
        dns["hosts"] = {"full:server.example.com": ["203.0.113.7"]}
    rules.append({"network": "tcp,udp", "outboundTag": "proxy"})
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"tag": "tun", "protocol": "tun",
                      "settings": {"name": "utun199", "mtu": 1500, "gateway": ["198.18.0.1/30"],
                                   "autoSystemRoutingTable": ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2", "::/2", "4000::/2", "8000::/2", "c000::/2"],
                                   "autoOutboundsInterface": "auto"},
                      "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True}}],
        "outbounds": [proxy, {"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"},
                      {"protocol": "dns", "tag": "dns-out", "settings": {"rules": [{"action": "hijack", "qType": "1,28"}, {"action": "return", "rCode": 0}]}}],
        "dns": dns,
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


def run(binary, path):
    env = dict(os.environ, XRAY_LOCATION_ASSET=assets)
    p = subprocess.run([binary, "run", "-test", "-c", path], capture_output=True, text=True, env=env, timeout=60)
    out = (p.stdout + p.stderr).strip().splitlines()
    notes = [re.sub(r"^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d\.\d+ ", "", l) for l in out if "Warning" in l or "deprecat" in l.lower() or "remove" in l.lower() or "fail" in l.lower() or "error" in l.lower()]
    notes = [re.sub(r"\[/var/folders/[^]]*\]", "[config]", l) for l in notes]
    return p.returncode, notes


worse = 0
regressed = 0
with tempfile.TemporaryDirectory() as d:
    for name, outbound in VARIANTS.items():
        for iran, names in ((True, True), (False, False)):
            path = os.path.join(d, "c.json")
            with open(path, "w") as f:
                json.dump(config(outbound, iran, names), f)
            ro, no = run(old, path)
            rn, nn = run(new, path)
            tag = "same" if (ro == rn and no == nn) else "DIFFERENT"
            if tag == "DIFFERENT" or rn != 0:
                worse += 1
            if ro == 0 and rn != 0:
                regressed += 1
            if tag == "DIFFERENT" or rn != 0 or (iran and names):
                print("%-30s ir=%d host=%d  old rc=%d  new rc=%d  %s  (warnings: %d)" % (name, iran, names, ro, rn, tag, len(nn)))
                if (tag == "DIFFERENT" or rn != 0) and iran:
                    for l in nn[-1:]:
                        print("     new:", l[-330:])
                    if tag == "DIFFERENT":
                        for l in no[-1:]:
                            print("     old:", l[-330:])
print("variants x modes:", len(VARIANTS) * 2, "| problems:", worse, "| accepted by the old Xray but rejected by the new:", regressed)
sys.exit(1 if regressed else 0)
