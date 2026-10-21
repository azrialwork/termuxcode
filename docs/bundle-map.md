# Bundle map: v1.19.3

What the compiled JavaScript actually contains, for planning the slim profile.
Generated from the `metafile-slim-arm64` artifact of run
[`39662040825`](https://github.com/azrialwork/termuxcode/actions/runs/39662040825)
(commit `3c83776`). The slim and full binaries of that run were byte-identical,
so this map describes the full build too. The Termux-only tree (run `39674869021`)
brought the slim bundle to 32,706,591 B without changing which modules dominate
it.

- inputs: 4892 modules
- outputs: 338 files (entry plus workers)
- output bytes: 32,783,125 (31.3 MiB)
- compiled binary: 174,658,760 (166.6 MiB)

The gap between 31.3 MiB of JavaScript and the 166.6 MiB binary is the Bun
runtime and the compiled payload. JavaScript trimming cannot go below that floor.

## Largest modules

| MiB | module |
| --- | --- |
| 8.6 | `typescript@5.8.2/lib/typescript.js` |
| 0.85 | `prettier@3.6.2/plugins/typescript.mjs` |
| 0.65 | `prettier@3.6.2/plugins/flow.mjs` |
| 0.62 | `prettier@3.6.2/index.mjs` |
| 0.58 | `@opentui/core/chunk-bun-t2myhmwd.js` |
| 0.49 | `@babel/parser/lib/index.js` |
| 0.42 | `@opentui/core/index.bun.js` |
| 0.42 | `ai/dist/index.mjs` |
| 0.35 | `fast-check/lib/fast-check.js` |
| 0.33 | `venice-ai-sdk-provider/dist/index.mjs` |

## Largest packages (sum of modules)

| MiB | package |
| --- | --- |
| 8.6 | `typescript` |
| 6.7 | application code (`sdk/js`, `src`, ...) |
| 3.8 | `effect` |
| 3.8 | `prettier` |
| 1.4 | `@opentui/core` |
| 0.5 | `@mixmark-io/domino` |
| 0.5 | `@ai-sdk/openai` (0.88) |
| 0.5 | `@babel/parser` |
| 0.4 | `@ai-sdk/anthropic` |
| 0.4 | `openai` |

`typescript` plus `prettier` is 12.4 MiB, about 38% of the bundle, before
compression. Whether removing them helps memory depends on whether they are
imported at startup, which the map does not answer by itself.

## Reproduce

```sh
gh run download <run-id> -n metafile-slim-arm64 -D meta
jq '{inputs:(.inputs|length), bytes:([.outputs[].bytes]|add)}' meta/*.json
jq -r '.inputs|to_entries[]|"\(.value.bytes)\t\(.key)"' meta/*.json | sort -rn | head -20
```
