#!/usr/bin/env bash
# Bench llama.cpp across every backend: native CPU, native Vulkan, native WebGPU,
# wasip3 CPU and wasip3 wasi:webgpu, then print one comparison table. The wasm
# components run through wasi-bench-runtime, which is built here if missing.
# Binaries are not built here; anything absent is skipped.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MODEL=models-runnable/qwen2.5-0.5b-instruct-q4_k_m.gguf
BENCH_ARGS=(-p 128 -n 32 -r 3)

runtime=wasi-bench-runtime/target/release/wasi-bench-runtime

exe=
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) exe=.exe ;;
esac

# The native GPU backend differs per platform. ggml has no DX12 backend, so on
# Windows this stays Vulkan; D3D12 is still measured, because both WebGPU rows
# reach it (Dawn and wgpu each default to D3D12 there).
case "$(uname -s)" in
    Darwin) native_gpu="native metal|build-metal/bin/llama-bench$exe|native" ;;
    *)      native_gpu="native vulkan|build-vulkan/bin/llama-bench$exe|native" ;;
esac

# label, binary, and whether it needs the wasm runtime in front
BENCHES=(
    "native cpu|build/bin/llama-bench$exe|native"
    "$native_gpu"
    "native webgpu|build-native-webgpu/bin/llama-bench$exe|native"
    "wasip3 cpu|build-wasip3/bin/llama-bench$exe|wasm"
    "wasip3 wasi:webgpu|build-wasip3-gpu/bin/llama-bench$exe|wasm"
)

need_runtime=no
for entry in "${BENCHES[@]}"; do
    IFS='|' read -r _ binary kind <<<"$entry"
    if [[ $kind == wasm && -f $binary ]]; then
        need_runtime=yes
    fi
done

if [[ $need_runtime == yes && ! -x $runtime ]]; then
    echo "==> building wasi-bench-runtime" >&2
    cargo build --release --manifest-path wasi-bench-runtime/Cargo.toml
fi

results=$(mktemp -d)
trap 'rm -rf "$results"' EXIT

i=0
for entry in "${BENCHES[@]}"; do
    IFS='|' read -r label binary kind <<<"$entry"
    i=$((i + 1))
    out="$results/$i.json"

    if [[ ! -f $binary ]]; then
        printf '%s\t%s\t%s\n' "$label" "$out" "not built" >>"$results/manifest"
        continue
    fi

    echo "==> $label" >&2
    # llama-bench writes the JSON to stdout; its logging goes to stderr.
    if [[ $kind == wasm ]]; then
        status=ok
        "$runtime" --dir . "$binary" -m "$MODEL" "${BENCH_ARGS[@]}" -o json >"$out" 2>/dev/null || status=failed
    else
        status=ok
        "./$binary" -m "$MODEL" "${BENCH_ARGS[@]}" -o json >"$out" 2>/dev/null || status=failed
    fi
    printf '%s\t%s\t%s\n' "$label" "$out" "$status" >>"$results/manifest"
done

MODEL="$MODEL" SETTINGS="${BENCH_ARGS[*]}" python3 - "$results/manifest" <<'PY'
import json, os, sys

rows, tests = [], []

with open(sys.argv[1]) as f:
    manifest = [line.rstrip("\n").split("\t") for line in f if line.strip()]

for label, path, status in manifest:
    scores = {}
    if status == "ok":
        try:
            with open(path) as fh:
                entries = json.load(fh)
        except (OSError, ValueError):
            entries, status = [], "failed"
        for e in entries:
            name = f"pp{e['n_prompt']}" if e["n_prompt"] else f"tg{e['n_gen']}"
            if name not in tests:
                tests.append(name)
            scores[name] = (e["avg_ts"], e["stddev_ts"])
        # What llama-bench itself reports, so a build that quietly picked up
        # another backend says so instead of hiding behind the label. On Apple,
        # Metal is on by default, so a plain build reports "Metal,BLAS" here.
        if entries:
            label = f"{label} [{entries[0]['backends']}]"
    rows.append((label, status, scores))

def cell(row, test):
    label, status, scores = row
    if test in scores:
        avg, sd = scores[test]
        return f"{avg:.2f} +/- {sd:.2f}"
    return {"ok": "-"}.get(status, status)

headers = ["backend"] + [f"{t} t/s" for t in tests]
table = [[r[0]] + [cell(r, t) for t in tests] for r in rows]
widths = [max(len(h), *(len(r[i]) for r in table)) for i, h in enumerate(headers)]

print()
print(f"model:    {os.environ['MODEL']}")
print(f"settings: {os.environ['SETTINGS']}")

# One chart per measure: pp and tg differ by an order of magnitude, so a shared
# axis would flatten the smaller one. Backend order is the same in both so the
# rows can be read across.
BAR_W = 44
PARTIALS = " " + "▏▎▍▌▋▊▉"

# Categorical slots in fixed order, one per backend, never cycled. Dark-surface
# steps; validated for CVD separation and contrast as a set. Only the bars wear
# these - labels and values keep the terminal's own ink, so identity is never
# carried by color alone.
SERIES = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"]

if os.environ.get("NO_COLOR") or not (
    sys.stdout.isatty() or os.environ.get("FORCE_COLOR")
):
    def paint(_slot, text):
        return text
else:
    def paint(slot, text):
        r, g, b = (int(SERIES[slot][i : i + 2], 16) for i in (1, 3, 5))
        return f"\033[38;2;{r};{g};{b}m{text}\033[0m"

for test in tests:
    # Keep each backend's slot tied to its row, so a backend that is missing from
    # one chart never shifts another's color.
    charted = [(i, r[0], r[2][test][0]) for i, r in enumerate(rows) if test in r[2]]
    if not charted:
        continue
    top = max(v for _, _, v in charted)
    pad = max(len(name) for _, name, _ in charted)

    print()
    print(f"{test} t/s (higher is better)")
    for slot, name, value in charted:
        scaled = value / top * BAR_W if top else 0
        whole = int(scaled)
        bar = "█" * whole
        eighth = int((scaled - whole) * 8)
        if eighth:
            bar += PARTIALS[eighth]
        print(f"  {name:<{pad}}  {paint(slot % len(SERIES), bar) or '|'} {value:.2f}")
print()

def line(cells):
    out = [cells[0].ljust(widths[0])]
    out += [c.rjust(widths[i + 1]) for i, c in enumerate(cells[1:])]
    return "| " + " | ".join(out) + " |"

print(line(headers))
print("|" + "|".join("-" * (w + 2) for w in widths) + "|")
for r in table:
    print(line([r[0]] + r[1:]))
print()
PY
