#!/bin/sh
# What does a web site actually see from LibreWolf? Starts a throw-away HTTP
# server on 127.0.0.1, opens it in a headless LibreWolf with a fresh profile
# (the real one is not touched, nothing appears on screen) and prints the
# User-Agent header plus what page JavaScript reads from navigator.
#
#   ua-test.sh                      current system config
#   ua-test.sh 'user_pref("privacy.resistFingerprinting", true);'
#                                   same, with extra prefs for this run only
#
# Needs python3. Takes about 40 s (LibreWolf is killed by timeout, it has no
# "load one page and quit" mode).
set -eu
PORT=${PORT:-8765}
T=$(mktemp -d)
trap 'kill $SP 2>/dev/null; rm -rf "$T"' EXIT
printf '%s\n' "${1:-}" > "$T/user.js"

cat > "$T/srv.py" <<'PY'
import http.server, sys, urllib.parse
PAGE = b"""<script>fetch('/js?' + new URLSearchParams({
  userAgent: navigator.userAgent, platform: navigator.platform,
  maxTouchPoints: navigator.maxTouchPoints,
  hardwareConcurrency: navigator.hardwareConcurrency,
  timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  window: innerWidth + 'x' + innerHeight}))</script>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/":
            print("HTTP  User-Agent:", self.headers.get("User-Agent"), flush=True)
            body = PAGE
        elif u.path == "/js":
            for k, v in urllib.parse.parse_qs(u.query).items():
                print("JS    %s: %s" % (k, v[0]), flush=True)
            body = b"ok"
        else:
            body = b""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

python3 "$T/srv.py" "$PORT" & SP=$!
sleep 1
timeout 40 librewolf --headless --no-remote --profile "$T" "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
