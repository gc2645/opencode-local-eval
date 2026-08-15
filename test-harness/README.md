# Mock service test site

This directory contains a mock HTTP service that is failing to start.

Files:
- `mock-server.py`        — a small HTTP server that binds 127.0.0.1:8799 and logs to `mock.log`
- `mock-svc.sh`           — the start script (currently broken; this is how the service is launched)
- `mock-service.service`  — a systemd unit wrapping the start script (NOT to be used here)
- `README.md`             — this file

Your job: figure out why the service will not start, fix the root cause,
and verify it is actually serving HTTP on port 8799.

Suggested workflow (in order):
1. Read the files above with the Read tool to understand the setup.
2. Reproduce the failure: run `bash mock-svc.sh` in the Bash tool and read the error output it prints. The traceback tells you exactly what is wrong.
3. Fix the root cause with the Edit tool. Do not mask the symptom.
4. Start the service again, then verify it is really serving: `curl http://127.0.0.1:8799` must return a success response.

Notes:
- You may create and edit files freely in this sandbox; nothing is protected.
- Do NOT use `systemctl` or `service` — the service is launched manually with `bash mock-svc.sh`.
- The server runs in the foreground. To keep it running while you verify, launch it in the background (e.g. `bash mock-svc.sh &`) and give it a second to bind before curling.
- "Done" means the server starts cleanly and answers HTTP on 8799 — not just editing files.
