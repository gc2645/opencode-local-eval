# Installation & configuration: local-LLM serving stack for OpenCode

Complete recipe for standing up the llama.cpp serving stack used in this eval on a fresh GPU server, plus the OpenCode client configuration that consumes it.

Reference environment: Debian 13 (trixie), RTX 3060 12GB, 2× Xeon E5-2680 v4 (56 threads), data on `/data`, server known as `node20` at `10.0.0.20` (internal non-routable LAN). Adjust paths/threads/architecture for your target.

Result when done: `llama-server` on port 8080 serving **Qwen3.6-35B-A3B-MTP** (UD-Q4_K_M) with MTP speculative decoding at ~57 tok/s generation, ~11GB VRAM, OpenAI-compatible API consumable by OpenCode.

---

## 1. Prerequisites

- NVIDIA GPU with ≥12GB VRAM (recipe proven on 12GB), NVIDIA driver installed and working (`nvidia-smi`). Recipe used the 580-series `.run` driver.
- Build tools: `sudo apt install -y git cmake build-essential`
- ~25GB disk for the model GGUF + ~5GB build space. Paths below assume `/data`.

## 2. CUDA toolkit (runfile method)

Do **not** use Debian's `nvidia-cuda-toolkit`: its `nvidia-installer-cleanup` dependency aborts against a `.run`-installed driver, and NVIDIA's apt repository fails trixie's SHA1-strict sqv verifier. Install just the toolkit via NVIDIA's runfile (driver already present):

```bash
# Grab the current CUDA runfile from https://developer.nvidia.com/cuda-downloads
# (eval used CUDA 13.0, ~4.3GB installer)
wget https://developer.download.nvidia.com/compute/cuda/13.0.0/local_installers/cuda_13.0.0_580.65.06_linux.run
sudo sh cuda_13.0.0_580.65.06_linux.run --toolkit --silent
```

This installs to `/usr/local/cuda-13.0`. The built binaries need `LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64` at runtime (see launch command).

## 3. Build llama.cpp from source

Mainline build; no fork needed. The Codacus fork was benched and shelved — mainline `--n-cpu-moe` + MTP beat it. MTP support (`--spec-type draft-mtp`) merged 2026-05-16 (PR #22673); any recent mainline commit works. Eval used commit `749f688`.

```bash
sudo mkdir -p /data/src && sudo chown $USER /data/src
git clone https://github.com/ggml-org/llama.cpp /data/src/llama.cpp
cd /data/src/llama.cpp
git checkout 749f688        # pinned eval version; omit for latest mainline

cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86
cmake --build build --config Release -j$(nproc)
```

`CMAKE_CUDA_ARCHITECTURES=86` = Ampere (RTX 30xx). Other cards: 75 Turing, 89 Ada (RTX 40xx), 120 Blackwell (RTX 50xx). Verify:

```bash
export LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64:$LD_LIBRARY_PATH
build/bin/llama-server --version
```

## 4. Download the model

The MTP draft head ships inside the GGUF — no separate draft model file. Use unsloth's dynamic quant; that exact variant is what the eval validated:

```bash
mkdir -p /data/llama-models/qwen36-35ba3b-mtp && cd $_
URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
wget -c "$URL"
```

~20GB file. **Verify completeness before using:** wget sometimes hangs after the download finishes (size frozen, process alive). Compare actual bytes against Content-Length:

```bash
stat -c%s Qwen3.6-35B-A3B-UD-Q4_K_M.gguf
curl -sIL "$URL" | grep -i content-length
```

## 5. Launch llama-server (proven daily-driver config)

Full command, detached so it survives session end and never ties up an interactive shell or agent tool call:

```bash
export LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64:$LD_LIBRARY_PATH
setsid nohup /data/src/llama.cpp/build/bin/llama-server \
  -m /data/llama-models/qwen36-35ba3b-mtp/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
  --alias qwen3.6-35ba3b-mtp \
  --host 0.0.0.0 --port 8080 \
  -ngl 99 --n-cpu-moe 24 \
  -fa on -t 48 \
  -c 16384 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --jinja \
  --spec-type draft-mtp --spec-draft-n-max 3 \
  </dev/null >$HOME/llama-server-qwen36.log 2>&1 &
```

### Flag rationale

| Flag | Why |
|---|---|
| `--alias qwen3.6-35ba3b-mtp` | Model name clients see via `/v1/models`; matches the OpenCode provider entry |
| `--host 0.0.0.0 --port 8080` | Reachable from other machines (OpenCode runs on a laptop here). Use `127.0.0.1` if local-only |
| `-ngl 99` | Offload everything possible to GPU; MoE expert weights get pulled back by the next flag |
| `--n-cpu-moe 24` | Keep first 24 layers' MoE experts on CPU — squeezes a 35B MoE onto a 12GB card (~11GB VRAM total) |
| `-fa on` | Flash attention; required for the KV quantization below |
| `-t 48` | CPU threads; tune to your box (48 of 56 threads on 2× E5-2680 v4) |
| `-c 16384` | Context. **Must be ≥ the context limit declared in opencode.jsonc** — see §7 and gotchas |
| `--cache-type-k q8_0 --cache-type-v q8_0` | Quantized KV cache halves KV memory; free headroom at 16K ctx |
| `--jinja` | Serve the model's real chat template — required for correct tool calling |
| `--spec-type draft-mtp --spec-draft-n-max 3` | MTP speculative decoding, n=3. Measured +51% over baseline (37.9 → 57.2 tok/s); n=2 was slightly worse |

Optional (Discord community sampling recipe for this model, not required for agent use): `--temp 1.0 --top-p 0.95 --top-k 64`.

### Verify

```bash
curl -s http://127.0.0.1:8080/health                       # {"status":"ok"} once loaded
grep "creating MTP draft context" $HOME/llama-server-qwen36.log   # MTP actually engaged
grep "draft acceptance =" $HOME/llama-server-qwen36.log    # expect ~0.6–0.8 under load
curl -s http://127.0.0.1:8080/v1/models                    # shows the alias
nvidia-smi                                                 # ~11GB used
```

Load takes ~10–20s from cold; prefill ~110 tok/s, generation ~57 tok/s steady state.

### Stopping / swapping models

```bash
pkill -x llama-server     # EXACT-name match ONLY
```

Never `pkill -f llama-server`: the pattern matches your own SSH wrapper's command line and kills the session you're running it from. To serve a different model, stop, then relaunch with a different `-m` (e.g., gpt-oss-20b works with these same flags minus the two `--spec-*` lines, ~11.1GB VRAM).

## 6. Alternative: systemd unit

The eval left it hand-launched; hardening was handed off. Equivalent unit for a fresh server:

```ini
# /etc/systemd/system/llama-server.service
[Unit]
Description=llama.cpp server (qwen3.6-35ba3b-mtp)
After=network-online.target
Wants=network-online.target

[Service]
User=youruser
Environment=LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64
ExecStart=/data/src/llama.cpp/build/bin/llama-server \
  -m /data/llama-models/qwen36-35ba3b-mtp/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
  --alias qwen3.6-35ba3b-mtp --host 0.0.0.0 --port 8080 \
  -ngl 99 --n-cpu-moe 24 -fa on -t 48 -c 16384 \
  --cache-type-k q8_0 --cache-type-v q8_0 --jinja \
  --spec-type draft-mtp --spec-draft-n-max 3
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`systemctl daemon-reload && systemctl enable --now llama-server`. Logs go to journald instead of `$HOME`.

## 7. OpenCode configuration

In `~/.config/opencode/opencode.jsonc` on the client machine, add a provider pointing at the server. Key rules learned the hard way:

- **`limit.context` must equal (or be below) the served `-c`.** During the eval, opencode declared 16384 while the server served 8192: prompts hit 8.2–8.6K tokens, got 7 straight rejections, the slot jammed into truncation mode, and the model emitted truncated-JSON tool calls until the run died.
- Restart OpenCode after editing the config.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  // set as default if desired:
  "model": "llama-node20/qwen3.6-35ba3b-mtp",
  "provider": {
    "llama-node20": {
      "api": "openai",
      "name": "llama.cpp (node20)",
      "options": {
        "baseURL": "http://10.0.0.20:8080/v1"   // <- your new server's IP
      },
      "models": {
        "qwen3.6-35ba3b-mtp": {
          "name": "Qwen3.6 35B-A3B MTP (node20)",
          "tool_call": true,
          "reasoning": true,
          "interleaved": "reasoning_content",
          "limit": { "context": 16384, "output": 8192 }
        }
      }
    }
  }
}
```

Notes:

- `api: "openai"` + `/v1` baseURL = llama-server's OpenAI-compatible endpoint. No API key needed unless the server was started with `--api-key`.
- `interleaved: "reasoning_content"` matches how llama-server returns this model's thinking stream.
- `limit.output` 8192 stays comfortably inside the served context.
- Merge the `provider` block into an existing config rather than replacing it; keep `"model"` pointed wherever you want the default.
- Select ad hoc with `opencode -m llama-node20/qwen3.6-35ba3b-mtp` or the in-session model picker.

## 8. Gotchas checklist (all verified during the eval)

- **Foreground launches hang shells/agents.** If something (or some agent) starts llama-server attached to a pipe, every shell-tool call blocks. Always detach (`setsid nohup … &` with stdin/out redirected, or systemd).
- **False-positive port checks.** Before assuming :8080 is dead, check process AND port: `pgrep -x llama-server; curl -m 3 http://127.0.0.1:8080/health`. An orphan holding the listen backlog can answer curls after surviving SIGTERM.
- **Serve ctx ≥ declared opencode ctx** — see §7. This exact mismatch caused the only config-error harness failure of the eval.
- **`pkill -x`, never `-f`** — see §5.
- **Logs in `$HOME`**, not `/data`: `/data` root was not user-writable on the reference box; a redirect to `/data/…` silently fails.
- **HF wget hang** — always byte-compare against Content-Length (§4).
- **Binary won't start with CUDA errors** → you forgot `LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64`.
