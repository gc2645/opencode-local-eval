# Agentic tool-calling eval: mock HTTP service

A reproducible benchmark that measures whether a local LLM can drive an agent loop end-to-end: diagnose a broken service, fix the root cause, and verify it is actually serving HTTP.

Tested harness: [opencode](https://opencode.ai) driving models served by [Ollama](https://ollama.com). The harness itself is model- and engine-agnostic — any agent that can read files, edit files, run a shell, and issue HTTP requests can be evaluated with it.

## The fixture

Directory contents after `restore-fixture.sh`:

| File | Purpose |
|---|---|
| `mock-server.py` | Small Python HTTP server binding `127.0.0.1:8799`, logging to `logs/mock.log` |
| `mock-svc.sh` | Start script (`exec python3 mock-server.py`) |
| `mock-service.service` | Illustrative systemd wrapper — **not** to be used in the test |
| `README.md` | The task instructions shown to the model (suggested workflow, verification bar) |

**The injected bug:** `mock-server.py` configures Python logging to write `logs/mock.log`, but the `logs/` directory does not exist. `logging.basicConfig` therefore raises `FileNotFoundError` and the process dies before binding the port. The symptom is silent from the outside: the service just never comes up.

## The task (prompt the agent receives)

```
Mock service won't start on port 8799
```

The fixture `README.md` (in the working directory) explains the expectations, including: read the files, reproduce the failure with `bash mock-svc.sh` and read the traceback, fix the root cause (do not mask the symptom), start the service in the background (`bash mock-svc.sh &`), and verify with `curl http://127.0.0.1:8799` returning a success response. "Done" means the server starts cleanly and answers HTTP on 8799 — not merely editing files.

## Harness protocol

1. **Restore pristine state** before every run: `bash restore-fixture.sh` (kills stray servers, removes logs, regenerates the broken fixture). Portable — resolves its own directory.
2. **Precheck** the port is free: `curl http://127.0.0.1:8799` must fail.
3. **Run the agent** against the fixture directory:

   ```bash
   opencode run --model <provider>/<model> --auto --dir <path-to-fixture> "Mock service won't start on port 8799"
   ```

   Restore + precheck again between runs.
4. **Capture evidence**, not just the transcript:
   - Server-side `logs/mock.log` is ground truth. A real verification shows the model's own `curl` arriving as `GET /` **after** `mock server starting` (+2s is the classic signature).
   - Response body must be `mock service OK\n` (a different body means the agent hit a stale/foreign server, not its own — a false positive).
   - Exit code and whether a final report was produced.

## Verdict definitions

- **PASS** — diagnose → fix → verify (server-side confirmed) → final report.
- **near-PASS** — task completed and server-side verified, but the run died before a final report.
- **FAIL** — the loop broke: foreground-server trap, refusal, hallucinated tools, structural inability to call tools, or dropped final message.

## Known harness artifact (important for scoring)

The start script runs the server in the **foreground** (`exec`). Correctly starting it means backgrounding it. Backgrounding with `&` while the shell's stdout is still attached to the agent's shell tool can hang that tool: the agent never sees the shell return, its harness kills the process group, the run dies, and the server **orphans** (stays bound to 8799). Orphaned servers are the #1 source of false positives and hang-induced verdicts — which is why restore+precheck before every run is mandatory. A model that survives this artifact to deliver a verified report is measurably more robust than one that completes the work but dies in the hang.

## Findings (2026 campaign summary)

Run across local models on a two-machine stack (Mac + LAN GPU server) served by Ollama and llama.cpp, plus a cloud baseline. Findings that survived the campaign:

**Round 1 — small diagnose→fix→verify loop (mock HTTP service):**

- Task competence ≠ speed: the fastest model refused on its first try; the slowest passed.
- Context quality matters: a better task README flipped one model from outright refusal to a clean PASS.
- The single biggest differentiator was surviving the background-server hang to emit the final report.
- Local passers: GLM-4.7-Flash (3m28s), Qwen3.6-27B (4m28s), Qwen3.6-35B-A3B-MTP (~5m), GPT-OSS-20B (7m30s, after one failed attempt). Cloud baseline: 2m38s.

**Round 2 — long-horizon real-infrastructure builds over SSH** (create an unprivileged LXC container to spec, install nginx inside it, prove service-level verification from the host):

- **Round 1 rankings did not transfer.** Qwen3.6-35B-A3B-MTP was the only model that completed builds (2/2 attempts, verified end-to-end; sole defect: never signals session completion and idles until timeout).
- GPT-OSS-20B failed twice with different failure modes: a hallucinated "no network" refusal without trying once, then answering with a copy-paste recipe instead of acting.
- GLM-4.7-Flash failed deterministically inside the agent loop while a raw-API probe proved it emits perfectly valid tool calls at identical prompt length — an agent-integration transport bug, not model capability.
- Meta-lessons: small-loop benchmarks don't predict long-horizon agentic performance; explicit "execute yourself / end when done" instructions matter more as tasks grow; always differential-probe the raw API before concluding a model can't do something.

## Reproduce from scratch

```bash
# 1. Take a copy of the harness
cp -r test-harness /tmp/mock-eval && cd /tmp/mock-eval
# 2. Confirm the fixture is in its broken state (a traceback is expected)
bash restore-fixture.sh && bash mock-svc.sh
# 3. Confirm the fix works and produces server-side evidence
mkdir -p logs && (bash mock-svc.sh &) && sleep 2 && curl -s http://127.0.0.1:8799 && cat logs/mock.log
# 4. Restore, then evaluate any agent with the protocol above
bash restore-fixture.sh
```
