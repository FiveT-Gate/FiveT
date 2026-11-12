#!/usr/bin/env python3
"""Watches the programs FiveT bundles: Xray, OpenVPN, openfortivpn, OpenSSL, LZO and LZ4.

  Tools/cores.py check [--json] [--gate]   compare every pinned version with the newest upstream release
  Tools/cores.py bump [core ...]           download the newest release inside each core's line, check it
                                           against the project's own signature or digests, rewrite the pins

check exits 0 when everything is current, 10 when an update is available, 3 when a lookup failed.
OpenVPN and OpenSSL follow their release line (2.6.x, 3.5.x LTS): a newer line is only reported.
No AI and no packages: python3, and gpg for OpenVPN's signature. Run by release.sh and cores-watch.sh.
"""
import datetime
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GH = "https://api.github.com/repos/%s/releases?per_page=100"
OPENVPN_KEY_URL = "https://swupdate.openvpn.net/community/keys/security.key.asc"
OPENVPN_KEY_FPR = "F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7"   # the project's security key, pinned

# line = how many leading version numbers make a release line (2.6.x -> 2); 0 = always follow the newest.
CORES = {
    "xray": dict(name="Xray", file="fetch-xray.sh", ver="XRAY_VERSION", sha="XRAY_SHA256", repo="XTLS/Xray-core",
                 tag=r"v(\d+\.\d+\.\d+)", line=0, asset="Xray-macos-arm64-v8a.zip",
                 url="https://github.com/XTLS/Xray-core/releases/download/v{v}/Xray-macos-arm64-v8a.zip"),
    "openvpn": dict(name="OpenVPN", file="build-openvpn.sh", ver="OVPN_VERSION", sha="OVPN_SHA256", repo="OpenVPN/openvpn",
                    tag=r"v(\d+\.\d+\.\d+)", line=2, asset="openvpn-{v}.tar.gz",
                    url="https://github.com/OpenVPN/openvpn/releases/download/v{v}/openvpn-{v}.tar.gz"),
    "openfortivpn": dict(name="openfortivpn", file="build-openfortivpn.sh", ver="OFV_VERSION", sha="OFV_SHA256",
                         repo="adrienverge/openfortivpn", tag=r"v(\d+\.\d+\.\d+)", line=0, brew="openfortivpn", tags_only=True,
                         url="https://github.com/adrienverge/openfortivpn/archive/refs/tags/v{v}.tar.gz"),
    # 3.5 is OpenSSL's long-term-support line: newer lines are not wanted, only 3.5.x patch releases.
    "openssl": dict(name="OpenSSL", file="build-openfortivpn.sh", ver="SSL_VERSION", sha="SSL_SHA256", repo="openssl/openssl",
                    tag=r"openssl-(\d+\.\d+\.\d+)", line=2, lts=True, asset="openssl-{v}.tar.gz",
                    url="https://github.com/openssl/openssl/releases/download/openssl-{v}/openssl-{v}.tar.gz"),
    "lzo": dict(name="LZO", file="build-openvpn.sh", ver="LZO_VERSION", sha="LZO_SHA256", brew="lzo", line=0,
                url="https://www.oberhumer.com/opensource/lzo/download/lzo-{v}.tar.gz"),
    "lz4": dict(name="LZ4", file="build-openvpn.sh", ver="LZ4_VERSION", sha="LZ4_SHA256", brew="lz4", line=0,
                url="https://github.com/lz4/lz4/archive/refs/tags/v{v}.tar.gz"),
}


def get(url, binary=False):
    req = urllib.request.Request(url, headers={"User-Agent": "fivet-cores/1"})
    if "api.github.com" in url and os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    last = None
    for _ in range(2):
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                data = r.read()
            return data if binary else data.decode("utf-8", "replace")
        except Exception as e:  # network, rate limit, 404: retried, then reported by the caller
            last = e
    raise RuntimeError("%s: %s" % (url, last))


def vt(s):
    return tuple(int(x) for x in s.split("."))


def vs(t):
    return ".".join(str(x) for x in t)


# macOS does not let a background job (launchd) read ~/Documents, where the repository lives, so the daily
# watcher runs from a copy of this file with the pinned versions mirrored here (FIVET_CORES_PINS points at it).
# Every run inside the repository refreshes the mirror, so it is as current as the last check, bump or release.
MIRROR_DIR = os.path.expanduser("~/Library/Application Support/fivet-cores")
MIRROR = os.path.join(MIRROR_DIR, "pins.json")


def pinned(c, key):
    if os.environ.get("FIVET_CORES_PINS") and key == "ver":
        return json.load(open(os.environ["FIVET_CORES_PINS"]))[c["ver"]]
    text = open(os.path.join(ROOT, "Tools", c["file"])).read()
    m = re.search(r"^%s=(\S+)" % c[key], text, re.M)
    if not m:
        raise RuntimeError("%s: %s= not found in Tools/%s" % (c["name"], c[key], c["file"]))
    return m.group(1)


def releases(c):
    """Stable releases of a GitHub project: {version tuple: release dict}."""
    out = {}
    if c.get("tags_only"):   # a project that publishes git tags but no GitHub releases
        listing = [dict(tag_name=t["name"], prerelease=False, draft=False, assets=[])
                   for t in json.loads(get("https://api.github.com/repos/%s/tags?per_page=100" % c["repo"]))]
    else:
        listing = json.loads(get(GH % c["repo"]))
    for r in listing:
        m = re.fullmatch(c["tag"], r["tag_name"])
        if m and not r["prerelease"] and not r["draft"] and not re.search(r"alpha|beta|rc", r["tag_name"], re.I):
            out[vt(m.group(1))] = r
    return out


def brew(name):
    return json.loads(get("https://formulae.brew.sh/api/formula/%s.json" % name))


def newest(key, c):
    """(newest release in the pinned line, newest overall) as version tuples, plus the release data."""
    cur = vt(pinned(c, "ver"))
    if c.get("repo"):
        rel = releases(c)
        versions = sorted(rel)
    else:
        rel = {}
        versions = [vt(brew(c["brew"])["versions"]["stable"])]
    n = c["line"]
    in_line = [v for v in versions if not n or v[:n] == cur[:n]] or [cur]
    return max(in_line), max(versions), rel


def check_one(item):
    key, c = item
    row = dict(core=key, name=c["name"], status="?")
    try:
        row["pinned"] = pinned(c, "ver")
        best, top, _ = newest(key, c)
        row["latest"] = vs(best)
        row["status"] = "UPDATE" if vt(row["pinned"]) < best else "ok"
        if c["line"] and top[:c["line"]] > vt(row["pinned"])[:c["line"]] and not c.get("lts"):
            row["newer_line"] = vs(top)
    except Exception as e:
        row["status"], row["error"] = "error", str(e)[:200]
    return row


def check():
    with ThreadPoolExecutor(len(CORES)) as pool:   # six independent lookups: one slow server does not queue the rest
        rows = list(pool.map(check_one, CORES.items()))
    return rows, any(r["status"] == "error" for r in rows)


def show(rows):
    print("%-13s %-10s %-10s %s" % ("core", "pinned", "newest", ""))
    for r in rows:
        note = {"ok": "current", "UPDATE": "UPDATE AVAILABLE", "error": "lookup failed: " + r.get("error", "")}[r["status"]]
        if r.get("newer_line"):
            note += "  (a newer line exists: %s, needs a manual test)" % r["newer_line"]
        print("%-13s %-10s %-10s %s" % (r["name"], r.get("pinned", "?"), r.get("latest", "?"), note))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def asset(rel, name):
    for a in rel.get("assets", []):
        if a["name"] == name:
            return a
    return None


def verify(key, c, v, path, rel):
    """Returns the sources that agree with the download's SHA-256; raises when one disagrees or none exists."""
    got = sha256(path)
    agree = ["download"]
    def must(label, want):
        if want and want.lower() != got:
            raise RuntimeError("%s says %s, the download is %s" % (label, want, got))
        if want:
            agree.append(label)
    if c.get("asset"):
        a = asset(rel, c["asset"].format(v=v))
        if a and a.get("digest", "").startswith("sha256:"):
            must("GitHub digest", a["digest"][7:])
    if key == "xray":
        a = asset(rel, c["asset"] + ".dgst")
        m = a and re.search(r"SHA2?-?256\s*=\s*([0-9a-f]{64})", get(a["browser_download_url"]), re.I)
        must(".dgst file", m.group(1) if m else None)
        if ".dgst file" not in agree:
            raise RuntimeError("no .dgst file with a SHA2-256 line")
    elif key == "openssl":
        a = asset(rel, "openssl-%s.tar.gz.sha256" % v)
        m = a and re.match(r"\s*([0-9a-f]{64})", get(a["browser_download_url"]))
        must("openssl .sha256 file", m.group(1) if m else None)
        if "openssl .sha256 file" not in agree:
            raise RuntimeError("no .sha256 file in the release")
    elif key == "openvpn":
        asc = asset(rel, "openvpn-%s.tar.gz.asc" % v)
        if not asc:
            raise RuntimeError("no .asc signature in the release")
        gpg_check(path, get(asc["browser_download_url"], binary=True))
        agree.append("GPG signature (OpenVPN security key)")
    else:
        f = brew(c["brew"])
        if f["versions"]["stable"] == v:
            must("Homebrew formula", f["urls"]["stable"]["checksum"])
        else:
            agree.append("WARNING: only the download itself (Homebrew still has %s)" % f["versions"]["stable"])
    return got, agree


def gpg_check(path, sig):
    home = tempfile.mkdtemp()
    env = dict(os.environ, GNUPGHOME=home)
    with open(os.path.join(home, "key.asc"), "wb") as f:
        f.write(get(OPENVPN_KEY_URL, binary=True))
    with open(os.path.join(home, "sig.asc"), "wb") as f:
        f.write(sig)
    subprocess.run(["gpg", "--batch", "--import", os.path.join(home, "key.asc")], env=env, capture_output=True, check=True)
    p = subprocess.run(["gpg", "--batch", "--status-fd", "1", "--verify", os.path.join(home, "sig.asc"), path],
                       env=env, capture_output=True, text=True)
    valid = [l.split() for l in p.stdout.splitlines() if "VALIDSIG" in l]
    if p.returncode != 0 or not valid or valid[0][-1] != OPENVPN_KEY_FPR:
        raise RuntimeError("the GPG signature is not valid for OpenVPN's pinned security key")


def set_pin(c, var, value, today):
    path = os.path.join(ROOT, "Tools", c["file"])
    lines = open(path).read().split("\n")
    idx = next(i for i, l in enumerate(lines) if l.startswith(var + "="))
    lines[idx] = "%s=%s" % (var, value)
    if var == c["sha"]:   # the "checked on <date>" note above a pin
        for j in range(max(0, idx - 6), idx):
            lines[j] = re.sub(r"(?i)(checked on )\d{4}-\d\d-\d\d", r"\g<1>" + today, lines[j])
    open(path, "w").write("\n".join(lines))


def bump(wanted):
    today = datetime.date.today().isoformat()
    status = 0
    for key, c in CORES.items():
        if wanted and key not in wanted:
            continue
        try:
            best, _, rel = newest(key, c)
            old = pinned(c, "ver")
            if vt(old) >= best:
                print("%-13s %s is current" % (c["name"], old))
                continue
            v = vs(best)
            tmp = tempfile.mkdtemp()
            path = os.path.join(tmp, "download")
            with open(path, "wb") as f:
                f.write(get(c["url"].format(v=v), binary=True))
            got, agree = verify(key, c, v, path, rel.get(best, {}))
            set_pin(c, c["ver"], v, today)
            set_pin(c, c["sha"], got, today)
            print("%-13s %s -> %s  verified by: %s" % (c["name"], old, v, "; ".join(agree)))
        except Exception as e:
            print("%-13s NOT updated: %s" % (c["name"], e), file=sys.stderr)
            status = 1
    return status


def write_mirror(create=False):
    """The pinned versions, for the daily watcher that cannot read the repository (see MIRROR)."""
    if os.environ.get("FIVET_CORES_PINS") or not (create or os.path.isdir(MIRROR_DIR)):
        return
    os.makedirs(MIRROR_DIR, exist_ok=True)
    with open(MIRROR, "w") as f:
        json.dump({c["ver"]: pinned(c, "ver") for c in CORES.values()}, f)


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("check", "bump", "sync-pins"):
        print(__doc__)
        return 2
    if args[0] == "sync-pins":
        write_mirror(create=True)
        print("pins written to", MIRROR)
        return 0
    if args[0] == "bump":
        status = bump([a for a in args[1:] if not a.startswith("-")])
        write_mirror()
        return status
    write_mirror()
    rows, failed = check()
    if "--json" in args:
        print(json.dumps(rows))
    else:
        show(rows)
    if any(r["status"] == "UPDATE" for r in rows):
        return 10
    return 3 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
