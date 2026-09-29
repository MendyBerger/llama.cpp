# wasi-bench-runtime

A host for running llama.cpp's wasip3 bench components.

`wasmtime run` handles the CPU build fine, but it cannot run the WebGPU build,
because nothing in wasmtime implements `wasi:webgpu`. This crate adds that one
import on top of the usual `wasi:cli`/`filesystem`/`clocks` set, so the same
`llama-bench` component runs on either backend with no changes.

It is headless: only `wasi:webgpu` is linked, not wasi-gfx `surface` or
`frame-buffer`, so there is no window and no main-thread event loop.

## Use

`run-bench.sh` in the repo root is the short path. It builds the runtime if
needed, runs either or both components, and skips one with a note if it is not
built.

```bash
./run-bench.sh                                     # cpu and gpu
./run-bench.sh -b gpu
./run-bench.sh -m models-runnable/foo.gguf -- -p 512 -n 128
```

Anything after `--` goes to `llama-bench`.

## Build and run by hand

```bash
cargo build --release   # -> target/release/wasi-bench-runtime
```

```bash
# WebGPU build
./wasi-bench-runtime/target/release/wasi-bench-runtime \
    build-wasip3-gpu/bin/llama-bench \
    -m models-runnable/qwen2.5-0.5b-instruct-q4_k_m.gguf -p 32 -n 8

# CPU build, same runtime
./wasi-bench-runtime/target/release/wasi-bench-runtime \
    build-wasip3/bin/llama-bench -m models-runnable/<model>.gguf
```

Everything after the component path goes to the guest. `--dir HOST[::GUEST]`
preopens a directory and repeats; it defaults to `.`, which is why the examples
above pass a plain relative model path.

## Building the components

See `cmake/wasip3.toolchain.cmake`. Needs a wasi-sdk 34+ with a `wasm32-wasip3`
sysroot and the EH runtime.

```bash
# CPU
WASI_SDK_PATH=<wasi-sdk> cmake -B build-wasip3 -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=cmake/wasip3.toolchain.cmake \
  -DCMAKE_HAVE_LIBC_PTHREAD=1 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=OFF -DGGML_WEBGPU=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TOOLS=ON
cmake --build build-wasip3 --target llama-bench -j

# WebGPU: same, plus
#   -DGGML_WEBGPU=ON
#   -DDAWN_WASI_WEBGPU_CPP_DIR=<dawn_wasi_webgpu_cpp checkout>
```

## Native builds that run-bench.sh looks for

| row | directory | configure with |
|-----|-----------|----------------|
| native cpu | `build` | `-DGGML_METAL=OFF -DGGML_BLAS=OFF` on macOS, else nothing |
| native vulkan (Linux, Windows) | `build-vulkan` | `-DGGML_VULKAN=ON` |
| native metal (macOS) | `build-metal` | `-DGGML_METAL=ON` |
| native webgpu | `build-native-webgpu` | `-DGGML_WEBGPU=ON -DDawn_DIR=<dawn>/lib/cmake/Dawn` |

On macOS, Metal and BLAS default to **on** (`ggml/CMakeLists.txt`, the `if (APPLE)`
block), so a plain `build` reports `Metal,BLAS`, not `CPU`. Turn both off for a
real CPU row. Each row's label carries the backend llama-bench itself reports, so
a mix-up like that is visible in the output rather than silent.

ggml has no DX12 backend, so the native GPU row on Windows is Vulkan. D3D12 is
still covered: Dawn and wgpu both default to it there, so the two WebGPU rows
exercise D3D12 on Windows, Metal on macOS, and Vulkan on Linux.

## Notes

- `wasi:cli/run` is lifted sync, so the guest blocks in `wgpuInstanceWaitAny` to
  drive its async webgpu imports to completion.
- `--hostcall-fuel` defaults to 8 GiB. wasmtime's own default is 128 MiB, a DoS
  mitigation on guest-to-host copies; uploading model weights through
  `wgpuQueueWriteBuffer` exhausts it and traps inside `load_all_data`.
- ccache can serve stale objects when a shim header is added that shadows a
  sysroot one, because its direct mode only revalidates the includes it already
  recorded. Use `CCACHE_RECACHE=1` after adding one.
