#!/usr/bin/env bash
# Restores the fixture to its pristine, buggy state. Safe to run anytime.
# Portable: resolves its own directory, so it works from any checkout location.
cd "$(dirname "$0")" || exit 1
pkill -f "mock-server.py" 2>/dev/null
sleep 1
rm -rf logs mock.log run.log clean.log
cat > mock-server.py <<'PYEOF'
#!/usr/bin/env python3
"""Mock server for the agentic tool-calling test. Binds 127.0.0.1:8799."""
import http.server, logging, sys

logging.basicConfig(filename="logs/mock.log", level=logging.INFO,
                    format="%(asctime)s %(message)s")
log = logging.getLogger("mock")

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.info("GET %s", self.path)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"mock service OK\n")
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    log.info("mock server starting")
    http.server.HTTPServer(("127.0.0.1", 8799), H).serve_forever()
PYEOF
cat > mock-svc.sh <<'PYEOF'
#!/usr/bin/env bash
# Starts the mock server.
exec python3 mock-server.py
PYEOF
chmod +x mock-svc.sh
echo "fixture restored"
