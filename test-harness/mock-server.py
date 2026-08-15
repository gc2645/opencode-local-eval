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
