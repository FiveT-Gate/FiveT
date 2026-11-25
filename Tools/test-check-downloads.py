#!/usr/bin/env python3
"""Self-test for Tools/check-downloads.py. A fake GitHub and a fake website listen on 127.0.0.1; each test
makes one thing go wrong the way a real release can (broken link, an HTML page served as the installer,
a wrong checksum, the old installer after a new release, an old page and manifest that agree with each
other, a truncated file, a feed that lags, the network down) and checks that the checker FAILS, with the
right exit code. Nothing on the internet is touched, no FiveT release is made.

  python3 Tools/test-check-downloads.py
"""
import hashlib
import http.server
import json
import os
import subprocess
import sys
import threading
import unittest

CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-downloads.py")
REPO = "/FiveT-Gate/FiveT"


def dmg(seed):
    return bytes([seed]) * 1_200_000 + b"koly" + bytes(508)


def exe(seed):
    return b"MZ" + bytes([seed]) * 1_200_000


def sha(b):
    return hashlib.sha256(b).hexdigest()


class Fake:
    """A route is a path -> (status, content type, body[, extra headers]) or a function returning that."""

    def __init__(self):
        self.routes, self.hits = {}, {}
        fake = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                fake.hits[self.path] = fake.hits.get(self.path, 0) + 1
                r = fake.routes.get(self.path)
                r = r(fake.hits[self.path]) if callable(r) else r
                if r is None:
                    r = (404, "text/plain", b"not found")
                status, ctype, body = r[0], r[1], r[2]
                headers = dict(r[3]) if len(r) > 3 else {}
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(headers.pop("Content-Length", len(body))))
                for k, v in headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def json(self, path, obj, status=200):
        self.routes[path] = (status, "application/json", json.dumps(obj).encode())

    def file(self, path, body, ctype="application/octet-stream"):
        self.routes[path] = (200, ctype, body)

    def release(self, tag, assets, **extra):
        """assets: {name: bytes}; the API record carries each size and SHA-256 digest."""
        rec = {"tag_name": tag, "draft": False, "prerelease": False, "assets": [
            {"name": n, "size": len(b), "state": "uploaded", "digest": "sha256:" + sha(b)} for n, b in assets.items()]}
        rec.update(extra)
        self.json("/api/repos%s/releases/tags/%s" % (REPO, tag), rec)
        return rec


def good(f, mac="1.2.4", win="2.3.2"):
    """A healthy world: Mac and Windows releases, feeds, and a website with three buttons for one file."""
    B = f.base
    d, s = dmg(4), None
    f.release("v" + mac, {"FiveT-%s.dmg" % mac: d, "latest.json": b"{}"})
    f.routes["%s/releases/latest" % REPO] = (302, "text/plain", b"", {"Location": "%s/releases/tag/v%s" % (REPO, mac)})
    f.routes["%s/releases/tag/v%s" % (REPO, mac)] = (200, "text/html", b"<html>the latest release</html>")
    f.json("/api/repos%s/releases?per_page=100" % REPO, [
        {"tag_name": "v" + mac, "draft": False}, {"tag_name": "v1.2.3", "draft": False},
        {"tag_name": "windows-v" + win, "draft": False}, {"tag_name": "windows-feed", "draft": False}])
    f.json("%s/releases/latest/download/latest.json" % REPO,
           {"version": mac, "build": 9, "sha256": sha(d), "url": "%s%s/releases/download/v%s/FiveT-%s.dmg" % (B, REPO, mac, mac)})
    f.routes["%s/releases/download/v%s/FiveT-%s.dmg" % (REPO, mac, mac)] = (302, "text/plain", b"", {"Location": "/objects/mac"})
    f.file("/objects/mac", d)
    # website
    f.routes["/site/"] = (200, "text/html", ('<html><body>' + ''.join('<a href="/site/FiveT-%s.dmg">Download</a>' % mac for _ in range(3))
                                              + '<a href="/features.html">x</a></body></html>').encode())
    f.json("/site/latest.json", {"version": mac, "build": 9, "sha256": sha(d), "url": "%s/site/FiveT-%s.dmg" % (B, mac)})
    f.file("/site/FiveT-%s.dmg" % mac, d)
    # Windows
    wa, wb = exe(5), exe(6)
    names = {"x64": "FiveT-Setup-%s.exe" % win, "arm64": "FiveT-Setup-%s-arm64.exe" % win}
    f.release("windows-v" + win, {names["x64"]: wa, names["arm64"]: wb})
    base = "%s%s/releases/download/windows-v%s/" % (B, REPO, win)
    f.json("%s/releases/download/windows-feed/latest-windows.json" % REPO, {"version": win, "assets": {
        "x64": {"url": base + names["x64"], "sha256": sha(wa), "signature": "x"},
        "arm64": {"url": base + names["arm64"], "sha256": sha(wb), "signature": "x"}}})
    f.file("%s/releases/download/windows-v%s/%s" % (REPO, win, names["x64"]), wa)
    f.file("%s/releases/download/windows-v%s/%s" % (REPO, win, names["arm64"]), wb)
    return d


class Checker(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.f = Fake()

    def setUp(self):
        self.f.routes.clear(); self.f.hits.clear()
        self.mac_bytes = good(self.f)

    def run_check(self, *args, base=None):
        b = base or self.f.base
        p = subprocess.run([sys.executable, "-I", CHECK, "--github-url", b, "--api-url", b + "/api", "--wait", "0",
                            "--retries", "1", "--retry-pause", "0", "--timeout", "5", *args],
                           capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout + p.stderr

    def failing(self, out, code, *needles):
        rc, text = out
        self.assertEqual(rc, code, text)
        for n in needles:
            self.assertIn(n, text)

    # ---- the healthy cases
    def test_mac_passes_with_the_website_and_downloads_each_file_once(self):
        rc, text = self.run_check("--tag", "v1.2.4", "--site", self.f.base + "/site")
        self.assertEqual(rc, 0, text)
        self.assertIn("all lead to FiveT-1.2.4.dmg", text)
        self.assertEqual(self.f.hits["/site/FiveT-1.2.4.dmg"], 1)       # three buttons, one file, one download
        self.assertEqual(self.f.hits["/objects/mac"], 1)                # the GitHub download followed its redirect

    def test_windows_passes_and_says_the_website_has_no_windows_link(self):
        rc, text = self.run_check("--tag", "windows-v2.3.2", "--site", self.f.base + "/site")
        self.assertEqual(rc, 0, text)
        self.assertIn("website has no Windows download link", text)

    def test_mac_only_by_default_and_both_platforms_on_request(self):
        rc, text = self.run_check()
        self.assertEqual(rc, 0, text)
        self.assertNotIn("Windows  expected", text)

    def test_both_platforms_with_the_newest_release_when_no_version_is_given(self):
        rc, text = self.run_check("--platform", "all")
        self.assertEqual(rc, 0, text)
        self.assertIn("taken from the newest published release", text)

    def test_the_feed_tag_checks_the_newest_windows_release(self):
        rc, text = self.run_check("--tag", "windows-feed")
        self.assertEqual(rc, 0, text)
        self.assertIn("Windows  expected 2.3.2", text)

    def test_a_feed_change_that_is_still_wrong_fails(self):
        feed = json.loads(self.f.routes["%s/releases/download/windows-feed/latest-windows.json" % REPO][2])
        feed["version"] = "2.3.1"
        self.f.json("%s/releases/download/windows-feed/latest-windows.json" % REPO, feed)
        self.failing(self.run_check("--tag", "windows-feed"), 1, "Windows feed still says 2.3.1, expected 2.3.2")

    def test_a_mistyped_tag_is_an_error_not_a_pass(self):
        for tag in ("windows-2.3.2", "V1.25.4", "v1.25.4-rc1", "random"):
            rc, text = self.run_check("--tag", tag)
            self.assertEqual(rc, 2, tag + text)
            self.assertIn("unknown release tag", text)

    def test_json_summary(self):
        rc, text = self.run_check("--tag", "v1.2.4", "--json")
        self.assertEqual(json.loads(text.strip().splitlines()[-1])["result"], "pass")

    # ---- the ways a Mac release goes wrong
    def test_broken_link(self):
        del self.f.routes["/objects/mac"]
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "HTTP 404")

    def test_html_error_page_served_as_the_installer(self):
        self.f.routes["/objects/mac"] = (200, "text/html", b"<!doctype html><title>Not found</title>")
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "an HTML page, not an installer")

    def test_html_page_with_an_installer_content_type_and_a_big_body(self):
        self.f.file("/objects/mac", b"<html><body>" + b"x" * 1_300_000 + b"</body></html>")
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "an HTML page, not an installer")

    def test_wrong_checksum_in_the_feed(self):
        feed = json.loads(self.f.routes["%s/releases/latest/download/latest.json" % REPO][2])
        feed["sha256"] = "0" * 64
        self.f.json("%s/releases/latest/download/latest.json" % REPO, feed)
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "SHA-256 differs from the public feed")

    def test_old_installer_served_after_a_new_release(self):
        self.f.file("/objects/mac", dmg(3))                              # the digest GitHub recorded belongs to the new file
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "differs from the digest GitHub recorded", "differs from the public feed")

    def test_old_feed_after_a_new_release(self):
        feed = json.loads(self.f.routes["%s/releases/latest/download/latest.json" % REPO][2])
        feed["version"] = "1.2.3"
        self.f.json("%s/releases/latest/download/latest.json" % REPO, feed)
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "public feed still says 1.2.3, expected 1.2.4")

    def test_old_page_and_old_manifest_that_agree_with_each_other_do_not_pass(self):
        old = dmg(3)
        self.f.routes["/site/"] = (200, "text/html", b'<a href="/site/FiveT-1.2.3.dmg">Download</a>')
        self.f.json("/site/latest.json", {"version": "1.2.3", "build": 8, "sha256": sha(old), "url": self.f.base + "/site/FiveT-1.2.3.dmg"})
        self.f.file("/site/FiveT-1.2.3.dmg", old)
        self.failing(self.run_check("--tag", "v1.2.4", "--site", self.f.base + "/site"), 1,
                     "website latest.json still says 1.2.3", "buttons lead to FiveT-1.2.3.dmg")

    def test_website_without_a_download_button(self):
        self.f.routes["/site/"] = (200, "text/html", b"<html><body>coming soon</body></html>")
        self.failing(self.run_check("--tag", "v1.2.4", "--site", self.f.base + "/site"), 1, "no .dmg download button")

    def test_website_file_differs_from_the_github_file(self):
        self.f.file("/site/FiveT-1.2.4.dmg", dmg(9))
        self.failing(self.run_check("--tag", "v1.2.4", "--site", self.f.base + "/site"), 1, "differs from website latest.json")

    def test_truncated_download(self):
        self.f.routes["/objects/mac"] = (200, "application/octet-stream", self.mac_bytes[:500_000], {"Content-Length": str(len(self.mac_bytes))})
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "incomplete download")

    def test_empty_file(self):
        self.f.file("/objects/mac", b"")
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "empty file")

    def test_release_not_published(self):
        del self.f.routes["/api/repos%s/releases/tags/v1.2.4" % REPO]
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "release v1.2.4 not found")

    def test_release_still_a_draft(self):
        self.f.release("v1.2.4", {"FiveT-1.2.4.dmg": self.mac_bytes, "latest.json": b"{}"}, draft=True)
        self.failing(self.run_check("--tag", "v1.2.4"), 1, "still a draft")

    def test_a_lagging_feed_is_waited_for(self):
        good_feed = self.f.routes["%s/releases/latest/download/latest.json" % REPO]
        stale = json.loads(good_feed[2]); stale["version"] = "1.2.3"
        self.f.routes["%s/releases/latest/download/latest.json" % REPO] = lambda n: (
            (200, "application/json", json.dumps(stale).encode()) if n < 3 else good_feed)
        rc, text = self.run_check("--tag", "v1.2.4", "--wait", "20", "--interval", "0.2")
        self.assertEqual(rc, 0, text)

    # ---- Windows
    def test_windows_feed_not_updated_after_the_release(self):
        feed = json.loads(self.f.routes["%s/releases/download/windows-feed/latest-windows.json" % REPO][2])
        feed["version"] = "2.3.1"
        self.f.json("%s/releases/download/windows-feed/latest-windows.json" % REPO, feed)
        self.failing(self.run_check("--tag", "windows-v2.3.2"), 1, "Windows feed still says 2.3.1, expected 2.3.2")

    def test_windows_release_marked_latest(self):
        self.f.routes["%s/releases/latest" % REPO] = (302, "text/plain", b"", {"Location": "%s/releases/tag/windows-v2.3.2" % REPO})
        self.f.routes["%s/releases/tag/windows-v2.3.2" % REPO] = (200, "text/html", b"<html>windows</html>")
        self.failing(self.run_check("--tag", "windows-v2.3.2"), 1, "marked 'latest'")

    def test_the_latest_slot_is_still_checked_when_the_github_api_is_down(self):
        self.f.routes["/api/repos%s/releases/tags/windows-v2.3.2" % REPO] = (503, "application/json", b"{}")
        self.f.routes["%s/releases/latest" % REPO] = (302, "text/plain", b"", {"Location": "%s/releases/tag/windows-v2.3.2" % REPO})
        self.f.routes["%s/releases/tag/windows-v2.3.2" % REPO] = (200, "text/html", b"<html>windows</html>")
        self.failing(self.run_check("--tag", "windows-v2.3.2"), 1, "marked 'latest'")

    def test_failing_steps_carry_a_code_for_the_follow_up_tool(self):
        self.f.json("/api/repos%s/releases/tags/v1.2.4" % REPO, {}, status=404)
        rc, text = self.run_check("--tag", "v1.2.4", "--json")
        steps = json.loads(text.strip().splitlines()[-1])["platforms"][0]["steps"]
        self.assertIn("release_missing", [x["code"] for x in steps])

    def test_windows_arm64_installer_missing(self):
        self.f.release("windows-v2.3.2", {"FiveT-Setup-2.3.2.exe": exe(5)})
        self.failing(self.run_check("--tag", "windows-v2.3.2"), 1, "lacks: FiveT-Setup-2.3.2-arm64.exe")

    def test_windows_installer_is_not_a_program(self):
        self.f.file("%s/releases/download/windows-v2.3.2/FiveT-Setup-2.3.2-arm64.exe" % REPO, b"\x00" * 1_300_000)
        self.failing(self.run_check("--tag", "windows-v2.3.2"), 1, "no 'MZ' header")

    # ---- when the GitHub API is not available the run says so instead of passing quietly
    def test_an_api_outage_gives_a_degraded_pass_that_says_so(self):
        self.f.routes["/api/repos%s/releases/tags/v1.2.4" % REPO] = (503, "application/json", b"{}")
        rc, text = self.run_check("--tag", "v1.2.4", "--json")
        self.assertEqual(rc, 0, text)
        self.assertIn("PASS (degraded: GitHub API not used", text)
        self.assertTrue(json.loads(text.strip().splitlines()[-1])["degraded"])

    def test_a_release_without_a_recorded_digest_says_that_comparison_was_skipped(self):
        rec = json.loads(self.f.routes["/api/repos%s/releases/tags/v1.2.4" % REPO][2])
        for a in rec["assets"]:
            a.pop("digest")
        self.f.json("/api/repos%s/releases/tags/v1.2.4" % REPO, rec)
        rc, text = self.run_check("--tag", "v1.2.4")
        self.assertEqual(rc, 0, text)
        self.assertIn("recorded no digest", text)

    def test_a_download_server_that_keeps_failing_means_could_not_verify_not_broken(self):
        self.f.routes["/objects/mac"] = (503, "text/plain", b"try later")
        self.failing(self.run_check("--tag", "v1.2.4"), 3, "COULD NOT VERIFY")

    # ---- network and arguments
    def test_network_down_means_could_not_verify_not_broken(self):
        rc, text = self.run_check("--tag", "v1.2.4", base="http://127.0.0.1:1")
        self.assertEqual(rc, 3, text)
        self.assertIn("COULD NOT VERIFY", text)

    def test_a_failure_wins_over_an_unknown(self):
        self.f.json("/api/repos%s/releases/tags/v1.2.4" % REPO, {}, status=404)
        rc, text = self.run_check("--tag", "v1.2.4", "--extra-feed", "http://127.0.0.1:1/latest.json")
        self.assertEqual(rc, 1, text)

    def test_bad_version_argument(self):
        self.assertEqual(self.run_check("--version", "abc")[0], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
