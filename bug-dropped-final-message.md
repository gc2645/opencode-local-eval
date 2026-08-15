# Draft: opencode bug — "silent dropped final message" (empty `stop` message, exit 0)

**Filed 2026-08-14:** https://github.com/anomalyco/opencode/issues/42677 (this file is the archival copy).

---

## Title

`opencode run` silently saves an empty assistant `stop` message (tokens counted, zero parts) and exits 0

## Summary

Headless `opencode run --auto` against the **ollama** provider (OpenAI-compatible `/v1/chat/completions`)
sometimes ends a session by saving an assistant message with `finish:"stop"`, **118 output tokens counted,
and no `parts` array at all** (no text, no tool call), then exits 0 with no error. The task is left incomplete
with no diagnostic. The streamed response on the wire is complete (ollama HTTP 200, `truncated=0`) and
contains the content/tool-call that opencode then fails to materialize as parts.

## Repro signature (verified 2026-08-14, opencode 1.18.15, ollama on node20)

- `opencode run --model ollama-node20/gpt-oss:20b --auto --dir <fixture> "<task>"`.
- Config for the model: `tool_call: true`, `reasoning: true`, `options.reasoningEffort: "high"`,
  no `interleaved`, `limit: { context: 32768, output: 8192 }`.
- Fresh session, **step 1, ~7K context** (not a long-session / context-window-exhaustion effect).

Message sequence in `~/.local/share/opencode/opencode.db`:

1. `user` — the task.
2. `assistant` — `finish: "tool-calls"`, 301 output tokens. (Glob `**/*` → 5 matches.)
3. Glob executes.
4. `assistant` — `finish: "stop"`, 118 output tokens, **no `parts` key**. `parentID` equals message 1's id
   (a sibling of message 2, not a child of it). Run exits 0. Loop never advances past step 1.

`data` of the dropped message:

```json
{"parentID":"...","role":"assistant","mode":"build","agent":"build",
 "cost":0,"tokens":{"total":7235,"input":7117,"output":118,"reasoning":0},
 "modelID":"gpt-oss:20b","providerID":"ollama-node20",
 "finish":"stop"}
```

Ollama-side (`journalctl -u ollama`) shows both requests completed cleanly:

```
18:25:28 [GIN] 200 POST /v1/chat/completions  (301 tok, truncated=0)
18:25:31 [GIN] 200 POST /v1/chat/completions  (118 tok, truncated=0, 2.9s)
```

The second response contained the model's next tool call (a `read`); the CLI rendered its raw JSON —
`{"filePath":"/private/tmp/opencode-local-test/mock-svc.sh","limit":200,"offset":1}` — as a bare line,
then the run stopped. The tool call never became a part and never executed.

## Wider pattern

Same signature (empty `stop` message, tokens counted, zero parts, exit 0, no error) observed repeatedly:

- 2026-08-13, gpt-oss:20b with `interleaved:"reasoning"` at 32K — dropped its **final** assistant message
  after a complete 200 (753 tokens); removal of `interleaved` previously seemed to fix it, but today's drop
  reproduces **without** interleaved and at **low context**, so it is not the interleaved setting.
- 2026-08-14, qwen3:30b-a3b — died silently on its 2nd LLM turn (complete 200, 308 tokens, empty `stop`, exit 0).
- 2026-08-14, qwen3.5:9b — three near-complete runs each ended at this signature before a final report.

## Expected

If a stream produces output tokens and a normal `finish_reason`, the assistant message must materialize its
parts (text and/or tool calls) and the agent loop must continue. An empty `finish:"stop"` assistant message
that silently ends the run (exit 0) is data loss.

## Environment

- opencode 1.18.15 (current); drop observed under the same config that produced a clean PASS earlier, so a
  version change between 2026-08-13 and 2026-08-14 is suspected as the trigger.
- Provider: ollama via `api: "openai"`, `baseURL http://<host>:11434/v1`, streaming enabled.
- Models: gpt-oss:20b (reasoning model), qwen3 family (reasoning models with `interleaved:"reasoning_content"`).

## Suggested investigation

- Message write path when an assistant turn returns `finish_reason:"tool_calls"` (or `"stop"`) — why are
  parts dropped while tokens are counted, and why does the dropped message share the *user* message as parent.
- Whether the drop correlates with `reasoning:true` (all observed cases are reasoning models).
- Whether stream chunk flushing has a race that drops the final chunk when the tool call ends the stream.
