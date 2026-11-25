#!/usr/bin/env python3
"""Checks that a published FiveT release can really be downloaded: the right installer, the right version,
the bytes the feed promises. It never installs or runs what it downloads (files go to a temporary folder
and are deleted). Python 3 standard library only. Run it with --help; the design is in docs/RELEASE-CHECK.md (private).

  Tools/check-downloads.py [--platform mac|windows|all (default mac)] [--version V] [--windows-version W] [--tag TAG]
                           [--site URL] [--extra-feed URL ...] [--wait SECONDS] [--json]

  --tag      what a release event gives: v1.25.4 = Mac 1.25.4, windows-v2.3.2 = Windows 2.3.2, windows-feed = the
             Windows feed changed (checks the newest Windows release against it). Any other tag is a mistake: exit 2
  --version / --windows-version  the expected version, from the release that was just made. Without any of
             them the newest published release found through the GitHub API is used, which only shows that the
             newest release is consistent. The live website and feeds are NEVER the source of the expected version.
  --site     the website to check too (or environment FIVET_SITE_URL); its address is not kept in this repository
  --extra-feed  one more feed that must name the same Mac version (the feed old copies of the app read)
  --wait     keep retrying a wrong-looking result (release missing, old feed, old file) for this many seconds,
             because a feed or CDN can lag a publication (default 60)

Exit codes: 0 everything required passed, 1 a required check failed, 2 bad arguments, 3 could not verify
(network or API down for the whole time). 3 means "unknown", never "broken".
"""
import argparse
import datetime
import hashlib
import html.parser
import http.client
import json
import os
import re
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "fivet-check-downloads/1"
MIN_BYTES = 1_000_000            # an installer smaller than this is an error page or a stub
MAX_BYTES = 600 * 1024 * 1024
DOWNLOAD_LIMIT = 900             # seconds for one download
PASS, FAIL, UNKNOWN, NOTE = "PASS", "FAIL", "UNKNOWN", "NOTE"
TRANSIENT = (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError, http.client.HTTPException)


class Unreachable(Exception):
    """A request kept failing (timeout, connection error, 5xx, rate limit) after its retries."""


def vt(s):
    return tuple(int(x) for x in s.split("."))


class Ctx:
    def __init__(self, a):
        self.repo = a.repo
        self.github = a.github_url.rstrip("/")
        self.api = a.api_url.rstrip("/")
        self.site = (a.site or os.environ.get("FIVET_SITE_URL") or "").strip()
        self.extra_feeds = a.extra_feed or []
        self.timeout, self.retries, self.pause = a.timeout, a.retries, a.retry_pause
        self.wait, self.interval = a.wait, a.interval
        self.token = os.environ.get("GITHUB_TOKEN", "")
        self.dl = {}                 # downloads of the current attempt, so one file is fetched once
        self.api_down = ""           # why the GitHub API is not used any more in this run (rate limit, outage)

    def headers(self, url):
        h = {"User-Agent": UA, "Accept": "application/json, */*"}
        if self.token and url.startswith(self.api):     # the token goes to the API only, never to a download host
            h["Authorization"] = "Bearer " + self.token
        return h


def request(ctx, url):
    """GET a small document -> (status, headers, body). Retries timeouts, connection errors, 5xx, 429 and a
    rate-limited 403; any other HTTP status is returned as it is. Raises Unreachable."""
    last = None
    for i in range(ctx.retries + 1):
        if i:
            time.sleep(ctx.pause * 2 ** (i - 1))
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=ctx.headers(url)), timeout=ctx.timeout) as r:
                return r.status, r.headers, r.read(5_000_000)
        except urllib.error.HTTPError as e:
            limited = e.code == 403 and e.headers.get("X-RateLimit-Remaining") == "0"
            if e.code in (429, 500, 502, 503, 504) or limited:
                last = "HTTP %d" % e.code
                continue
            return e.code, e.headers, e.read(200_000)
        except TRANSIENT as e:
            last = getattr(e, "reason", e)
    raise Unreachable("%s (%s)" % (url, last))


def final_url(ctx, url):
    """The address a GET of url ends at after its redirects (retries like request()); raises Unreachable."""
    last = None
    for i in range(ctx.retries + 1):
        if i:
            time.sleep(ctx.pause * 2 ** (i - 1))
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=ctx.timeout) as r:
                return r.geturl()
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504):
                last = "HTTP %d" % e.code
                continue
            return e.geturl()
        except TRANSIENT as e:
            last = getattr(e, "reason", e)
    raise Unreachable("%s (%s)" % (url, last))


def get_json(ctx, url):
    """-> (status, parsed or None, problem or None)"""
    status, _, body = request(ctx, url)
    if status != 200:
        return status, None, "HTTP %d" % status
    try:
        return status, json.loads(body.decode("utf-8")), None
    except ValueError:
        return status, None, "not JSON (an HTML page served with HTTP 200?)"


class Download:
    def __init__(self, url):
        self.url, self.status, self.size, self.sha256, self.problem = url, None, 0, "", None


def looks_html(ctype, head):
    h = head[:2048].lstrip().lower()
    return "text/html" in ctype.lower() or h.startswith((b"<!doctype html", b"<html", b"<head", b"<body")) or b"<html" in h


def download(ctx, url, kind):
    """Fetch url into a temporary file (never run), hash it, check it looks like an installer (kind dmg|exe)."""
    d = Download(url)
    with tempfile.TemporaryDirectory(prefix="fivet-check-") as tmp:
        path = os.path.join(tmp, "download")
        for i in range(ctx.retries + 1):
            if i:
                time.sleep(ctx.pause * 2 ** (i - 1))
            d.problem, d.size = None, 0
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=ctx.timeout) as r:
                    d.status, ctype = r.status, r.headers.get("Content-Type", "")
                    want = r.headers.get("Content-Length")
                    sha, start = hashlib.sha256(), time.time()
                    with open(path, "wb") as f:
                        while True:
                            chunk = r.read(1 << 20)
                            if not chunk:
                                break
                            f.write(chunk); sha.update(chunk); d.size += len(chunk)
                            if d.size > MAX_BYTES or time.time() - start > DOWNLOAD_LIMIT:
                                raise ValueError("too large or too slow")
                d.sha256 = sha.hexdigest()
            except urllib.error.HTTPError as e:
                d.status = e.code
                if e.code in (429, 500, 502, 503, 504):
                    d.problem = "HTTP %d" % e.code
                    continue
                d.problem = "HTTP %d (no file there)" % e.code
                return d
            except TRANSIENT as e:
                d.problem = "network error: %s" % getattr(e, "reason", e)
                d.status = None
                continue
            except ValueError as e:
                d.problem = "download stopped: %s" % e
                return d
            if want is not None and want.isdigit() and int(want) != d.size:
                d.problem = "incomplete download: %d of %s bytes arrived" % (d.size, want)
                continue
            with open(path, "rb") as f:
                head = f.read(2048)
                f.seek(max(0, d.size - 512))
                tail = f.read()
            if d.size == 0:
                d.problem = "empty file"
            elif looks_html(ctype, head):
                d.problem = "an HTML page, not an installer (served with HTTP 200)"
            elif d.size < MIN_BYTES:
                d.problem = "only %d bytes: too small to be an installer" % d.size
            elif kind == "dmg" and tail[:4] != b"koly":
                d.problem = "not a disk image (no 'koly' trailer)"
            elif kind == "exe" and head[:2] != b"MZ":
                d.problem = "not a Windows program (no 'MZ' header)"
            return d
    if d.problem and (d.problem.startswith("network") or d.problem in ("HTTP 429", "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504")):
        raise Unreachable("%s (%s)" % (url, d.problem))
    return d


class Report:
    def __init__(self, platform, expected):
        self.platform, self.expected, self.steps, self.degraded = platform, expected, [], []

    def add(self, status, text, code=""):
        self.steps.append((status, text, code))

    def status(self):
        s = [x[0] for x in self.steps]
        return FAIL if FAIL in s else UNKNOWN if UNKNOWN in s else PASS


def fetch_installer(ctx, r, url, kind):
    """One download per distinct address in an attempt; reports the file's own checks. -> Download or None"""
    if url not in ctx.dl:
        try:
            ctx.dl[url] = download(ctx, url, kind)
        except Unreachable as e:
            ctx.dl[url] = None
            r.add(UNKNOWN, "could not download: %s" % e, "unreachable")
            return None
        d = ctx.dl[url]
        if d.problem:
            r.add(FAIL, "download of %s failed: %s" % (url, d.problem), "download")
        else:
            r.add(PASS, "downloaded %s: %s bytes, SHA-256 %s..." % (url.rsplit("/", 1)[-1], format(d.size, ","), d.sha256[:12]))
    d = ctx.dl[url]
    return d if d and not d.problem else None


def same(r, d, name, expected):
    if not expected and name.startswith("the digest GitHub recorded") and not r.degraded:
        r.add(NOTE, "GitHub recorded no digest for this file: that comparison was skipped")
    if expected:
        ok = d.sha256 == expected.lower()
        r.add(PASS if ok else FAIL, "SHA-256 equals %s" % name if ok else
              "SHA-256 differs from %s: file %s, expected %s (the old file is still served?)" % (name, d.sha256, expected),
              "" if ok else "sha")


def release_record(ctx, r, tag, names, mac):
    """The GitHub release record: published, assets present. -> {asset name: sha256 digest or ''}, or None."""
    if ctx.api_down:
        r.degraded.append("GitHub API not used: release record and asset digests not checked")
        r.add(NOTE, "GitHub API not used (%s): release record and asset digests not checked" % ctx.api_down)
        return None
    try:
        status, rel, bad = get_json(ctx, "%s/repos/%s/releases/tags/%s" % (ctx.api, ctx.repo, tag))
    except Unreachable as e:
        ctx.api_down = str(e)[:120]
        r.degraded.append("GitHub API not used: release record and asset digests not checked")
        r.add(NOTE, "GitHub API not reachable, so the release record and asset digests were not checked (%s)" % e)
        return None
    if status == 404:
        r.add(FAIL, "release %s not found on GitHub (not published yet, or deleted)" % tag, "release_missing")
        return None
    if bad:
        ctx.api_down = "answered " + bad
        r.degraded.append("GitHub API not used: release record and asset digests not checked")
        r.add(NOTE, "GitHub API answered %s: release record and asset digests not checked" % bad)
        return None
    if rel.get("draft"):
        r.add(FAIL, "release %s is still a draft" % tag, "release_draft")
    elif mac and rel.get("prerelease"):
        r.add(FAIL, "release %s is marked pre-release, so it is not the Mac update feed" % tag, "release_prerelease")
    assets = {a["name"]: a for a in rel.get("assets", [])}
    missing = [n for n in names if n not in assets]
    notup = [n for n in names if n in assets and (assets[n].get("state") != "uploaded" or not assets[n].get("size"))]
    if missing:
        r.add(FAIL, "release %s lacks: %s" % (tag, ", ".join(missing)), "asset_missing")
    elif notup:
        r.add(FAIL, "release %s: asset not fully uploaded: %s" % (tag, ", ".join(notup)), "asset_incomplete")
    elif not rel.get("draft"):
        r.add(PASS, "release %s is published with %s" % (tag, " + ".join(names)))
    return {n: (assets[n].get("digest") or "").replace("sha256:", "") for n in names if n in assets}


def feed_version(r, label, feed_v, v):
    """Compare a feed's version with the expected one. -> True when the feed is for v."""
    if feed_v == v:
        r.add(PASS, "%s says %s" % (label, v))
        return True
    try:
        older = vt(feed_v) < vt(v)
    except (ValueError, AttributeError):
        r.add(FAIL, "%s has no usable version (%r)" % (label, feed_v), "feed_bad")
        return False
    if older:
        r.add(FAIL, "%s still says %s, expected %s (not updated yet, or an old copy is served)" % (label, feed_v, v), "feed_stale")
    else:
        r.add(NOTE, "%s already says %s, newer than %s: fine for an older release" % (label, feed_v, v))
    return False


def dmg_links(page, base):
    out = []

    class P(html.parser.HTMLParser):
        def handle_starttag(self, tag, attrs):
            h = dict(attrs).get("href")
            if tag == "a" and h and urllib.parse.urlparse(h).path.lower().endswith(".dmg"):
                out.append(urllib.parse.urljoin(base, h))
    P().feed(page)
    return out


def site_steps(ctx, r, v, dmg, gh_sha, download_now):
    base = ctx.site.rstrip("/") + "/"
    try:
        status, _, body = request(ctx, base)
    except Unreachable as e:
        r.add(UNKNOWN, "website not reachable: %s" % e, "unreachable")
        return
    links = dmg_links(body.decode("utf-8", "replace"), base) if status == 200 else []
    if status != 200:
        r.add(FAIL, "website %s answered HTTP %d" % (base, status), "site")
    elif not links:
        r.add(FAIL, "website page has no .dmg download button", "site")
    else:
        names = sorted({u.rsplit("/", 1)[-1] for u in links})
        if names == [dmg]:
            r.add(PASS, "website: %d download button(s), all lead to %s" % (len(links), dmg))
        else:
            r.add(FAIL, "website buttons lead to %s, expected only %s (the page shows an old release?)" % (", ".join(names), dmg), "site")
    sha_expect, urls = None, set(links)
    try:
        status, feed, bad = get_json(ctx, base + "latest.json")
    except Unreachable as e:
        r.add(UNKNOWN, "website latest.json not reachable: %s" % e, "unreachable")
        feed, bad = None, "unreachable"
    if bad and feed is None and bad != "unreachable":
        r.add(FAIL, "website latest.json: %s" % bad, "site")
    elif feed:
        if feed_version(r, "website latest.json", feed.get("version"), v):
            sha_expect = feed.get("sha256")
            want_url = urllib.parse.urljoin(base, dmg)
            if feed.get("url") != want_url:
                r.add(FAIL, "website latest.json points at %s, expected %s" % (feed.get("url"), want_url), "site")
            urls.add(want_url)
    if download_now:
        for u in sorted(urls):
            d = fetch_installer(ctx, r, u, "dmg")
            if d:
                same(r, d, "website latest.json", sha_expect)
                same(r, d, "the GitHub download (the same file)", gh_sha)


def check_mac(ctx, v, download_now):
    r = Report("Mac", v)
    tag, dmg = "v" + v, "FiveT-%s.dmg" % v
    url = "%s/%s/releases/download/%s/%s" % (ctx.github, ctx.repo, tag, dmg)
    digests = release_record(ctx, r, tag, [dmg, "latest.json"], True) or {}
    sha_feed = None
    try:
        status, feed, bad = get_json(ctx, "%s/%s/releases/latest/download/latest.json" % (ctx.github, ctx.repo))
        if bad:
            r.add(FAIL, "public feed (releases/latest/download/latest.json): %s" % bad, "feed_bad")
        elif feed_version(r, "public feed", feed.get("version"), v):
            sha_feed = feed.get("sha256")
            if feed.get("url") != url:
                r.add(FAIL, "public feed points at %s, expected %s" % (feed.get("url"), url), "feed_url")
    except Unreachable as e:
        r.add(UNKNOWN, "public feed not reachable: %s" % e, "unreachable")
    for extra in ctx.extra_feeds:
        try:
            status, feed, bad = get_json(ctx, extra)
            if bad:
                r.add(FAIL, "extra feed %s: %s" % (extra, bad), "extra_feed")
            elif feed_version(r, "extra feed " + extra, feed.get("version"), v) and sha_feed and feed.get("sha256") != sha_feed:
                r.add(FAIL, "extra feed %s has another SHA-256 than the public feed" % extra, "extra_feed")
        except Unreachable as e:
            r.add(UNKNOWN, "extra feed not reachable: %s" % e, "unreachable")
    if download_now:
        d = fetch_installer(ctx, r, url, "dmg")
        if d:
            same(r, d, "the public feed", sha_feed)
            same(r, d, "the digest GitHub recorded", digests.get(dmg))
        gh_sha = d.sha256 if d else digests.get(dmg)
    else:
        gh_sha = digests.get(dmg)
    if ctx.site:
        site_steps(ctx, r, v, dmg, gh_sha, download_now)
    return r


def check_windows(ctx, w, download_now):
    r = Report("Windows", w)
    tag = "windows-v" + w
    files = {"x64": "FiveT-Setup-%s.exe" % w, "arm64": "FiveT-Setup-%s-arm64.exe" % w}
    base = "%s/%s/releases/download/%s/" % (ctx.github, ctx.repo, tag)
    digests = release_record(ctx, r, tag, list(files.values()), False) or {}
    try:                      # GitHub's "latest" slot belongs to the Mac feed; read it from the public redirect, not the API
        where = final_url(ctx, "%s/%s/releases/latest" % (ctx.github, ctx.repo))
        tag_now = where.rstrip("/").rsplit("/", 1)[-1] if "/releases/tag/" in where else ""
        if tag_now and not re.fullmatch(r"v\d+(\.\d+)+", tag_now):
            r.add(FAIL, "release %s is marked 'latest' on GitHub: the Mac update feed no longer points at a Mac release" % tag_now, "latest_slot")
    except Unreachable as e:
        r.add(UNKNOWN, "could not read which release is 'latest': %s" % e, "unreachable")
    feed_sha = {}
    try:
        status, feed, bad = get_json(ctx, "%s/%s/releases/download/windows-feed/latest-windows.json" % (ctx.github, ctx.repo))
        if bad:
            r.add(FAIL, "Windows feed (release windows-feed, latest-windows.json): %s" % bad, "feed_bad")
        elif feed_version(r, "Windows feed", feed.get("version"), w):
            for arch, name in files.items():
                a = (feed.get("assets") or {}).get(arch) or {}
                if a.get("url") != base + name:
                    r.add(FAIL, "Windows feed %s entry points at %s, expected %s" % (arch, a.get("url"), base + name), "feed_url")
                elif not re.fullmatch(r"[0-9a-fA-F]{64}", a.get("sha256") or ""):
                    r.add(FAIL, "Windows feed %s entry has no valid SHA-256" % arch, "feed_bad")
                else:
                    feed_sha[arch] = a["sha256"]
                    r.add(PASS, "Windows feed %s entry: %s with a SHA-256" % (arch, name))
    except Unreachable as e:
        r.add(UNKNOWN, "Windows feed not reachable: %s" % e, "unreachable")
    if download_now:
        for arch, name in files.items():
            d = fetch_installer(ctx, r, base + name, "exe")
            if d:
                same(r, d, "the Windows feed (%s)" % arch, feed_sha.get(arch))
                same(r, d, "the digest GitHub recorded (%s)" % arch, digests.get(name))
    if ctx.site:
        try:
            status, _, body = request(ctx, ctx.site.rstrip("/") + "/")
            page = body.decode("utf-8", "replace").lower()
            has = status == 200 and (".exe" in page or "windows" in page)
            r.add(NOTE, "website offers a Windows download" if has else
                  "website has no Windows download link: Windows installers are only on the GitHub Releases page")
        except Unreachable:
            pass
    else:
        r.add(NOTE, "website not checked for a Windows link (no --site)")
    return r


NOT_VERIFIED = {
    "Mac": "feed signature (Ed25519), Gatekeeper / notarization, and whether the app opens",
    "Windows": "feed signature (ECDSA P-256), SmartScreen, and whether the installer runs",
}


def run(ctx, fn, version):
    """Check one platform, retrying wrong-looking results until ctx.wait seconds have passed. The pause grows
    (15 s, 22 s, 34 s ... at most 2 minutes) so a long wait does not hammer GitHub."""
    deadline, full, polls = time.time() + ctx.wait, 0, 0
    while True:
        ctx.dl = {}
        r = fn(ctx, version, False)                  # cheap pass first: no bytes until the metadata is right
        if r.status() == PASS:
            ctx.dl = {}
            r = fn(ctx, version, True)
            full += 1
        if r.status() == PASS or time.time() >= deadline or full >= 4:
            return r
        time.sleep(max(0, min(ctx.interval * 1.5 ** polls, 120, deadline - time.time())))
        polls += 1


def newest(ctx, prefix):
    """The newest published release tag starting with prefix, by version number (not by date)."""
    status, rels, bad = get_json(ctx, "%s/repos/%s/releases?per_page=100" % (ctx.api, ctx.repo))
    if bad:
        raise Unreachable("release list: %s" % bad)
    pat = re.compile(re.escape(prefix) + r"(\d+(?:\.\d+)+)$")
    found = [m.group(1) for x in rels if not x.get("draft") for m in [pat.match(x.get("tag_name", ""))] if m]
    return max(found, key=vt) if found else None


def parse_tag(tag):
    """-> ("mac"|"windows", version or None) for a release tag, ("none", None) for nothing, or None for a mistake."""
    m = re.fullmatch(r"(windows-)?v(\d+(?:\.\d+)+)", tag)
    if m:
        return ("windows" if m.group(1) else "mac"), m.group(2)
    return ("windows", None) if tag == "windows-feed" else None


def main(argv=None):
    started = time.time()
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--platform", choices=["mac", "windows", "all"], default="mac", help="default mac: Windows is only checked when asked for")
    p.add_argument("--version", help="expected Mac version, e.g. 1.25.4")
    p.add_argument("--windows-version", help="expected Windows version, e.g. 2.3.2")
    p.add_argument("--tag", help="a release tag from a release event: v1.25.4, windows-v2.3.2 or windows-feed")
    p.add_argument("--site", help="website address to check too (or FIVET_SITE_URL)")
    p.add_argument("--extra-feed", action="append", help="another feed that must name the same Mac version")
    p.add_argument("--wait", type=int, default=60, help="seconds to keep retrying a wrong-looking result (default 60)")
    p.add_argument("--json", action="store_true", help="print a JSON summary after the text")
    p.add_argument("--json-file", help="write the JSON summary to this file (the text output stays clean)")
    p.add_argument("--repo", default="FiveT-Gate/FiveT", help=argparse.SUPPRESS)
    p.add_argument("--github-url", default="https://github.com", help=argparse.SUPPRESS)      # tests point these at a fake
    p.add_argument("--api-url", default="https://api.github.com", help=argparse.SUPPRESS)
    p.add_argument("--timeout", type=int, default=30, help=argparse.SUPPRESS)
    p.add_argument("--retries", type=int, default=3, help=argparse.SUPPRESS)
    p.add_argument("--retry-pause", type=float, default=2, help=argparse.SUPPRESS)
    p.add_argument("--interval", type=float, default=15, help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    for v in (a.version, a.windows_version):
        if v and not re.fullmatch(r"\d+(\.\d+)+", v):
            p.error("a version looks like 1.25.4, not %r" % v)
    ctx = Ctx(a)
    todo, trigger = [], ""      # (platform, function, version or None = find the newest)
    if a.tag:
        t = parse_tag(a.tag)
        if t is None:
            p.error("unknown release tag %r: expected v<version>, windows-v<version> or windows-feed" % a.tag)
        name, version = t
        trigger = "release tag %s" % a.tag
        todo = [("Windows", check_windows, version)] if name == "windows" else [("Mac", check_mac, version)]
    else:
        if a.platform in ("mac", "all"):
            todo.append(("Mac", check_mac, a.version))
        if a.platform in ("windows", "all"):
            todo.append(("Windows", check_windows, a.windows_version))
    print("FiveT download check, %s" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ"))
    scope = "GitHub releases and feeds" + ("; website checked" if ctx.site else "; website NOT checked (no --site)")
    print("Scope: %s%s" % (scope, "; " + trigger if trigger else ""))
    reports = []
    for name, fn, version in todo:
        derived = False
        if version is None:
            try:
                version = newest(ctx, "v" if name == "Mac" else "windows-v")
            except Unreachable as e:
                r = Report(name, "?")
                r.add(UNKNOWN, "cannot find the newest %s release to check: %s" % (name, e), "unreachable")
                reports.append(r)
                continue
            if version is None:
                r = Report(name, "-")
                r.add(FAIL, "no published %s release found on GitHub" % name, "release_missing")
                reports.append(r)
                continue
            derived = True
        r = run(ctx, fn, version)
        if derived:
            r.add(NOTE, "expected version taken from the newest published release (not from a feed): this shows it is "
                        "consistent, not that it is the release you just made (pass --%s)" % ("version" if name == "Mac" else "windows-version"))
        reports.append(r)
    for r in reports:
        print("\n%s  expected %s  %s" % (r.platform, r.expected, r.status()))
        for status, text, code in r.steps:
            print("  %-7s %s" % (status, text))
        print("  %-7s %s" % ("NOT", "verified here: " + NOT_VERIFIED[r.platform]))
    states = [r.status() for r in reports]
    code = 1 if FAIL in states else 3 if UNKNOWN in states else 0
    degraded = sorted({m for r in reports for m in r.degraded})
    label = {0: "PASS" + (" (degraded: %s)" % "; ".join(degraded) if degraded else ""), 1: "FAIL (published, verification failed)", 3: "COULD NOT VERIFY (network or API unavailable; run it again later)"}[code]
    seconds = round(time.time() - started, 1)
    print("\nRESULT: %s  (%.1f s)" % (label, seconds))
    summary = json.dumps({"result": {0: "pass", 1: "fail", 3: "unknown"}[code], "exit": code, "seconds": seconds,
                          "scope": scope, "trigger": trigger, "degraded": degraded, "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                          "platforms": [
            {"platform": r.platform, "expected": r.expected, "status": r.status().lower(),
             "steps": [{"status": s.lower(), "code": c, "text": t} for s, t, c in r.steps]} for r in reports]})
    if a.json:
        print(summary)
    if a.json_file:
        with open(a.json_file, "w") as f:
            f.write(summary + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
