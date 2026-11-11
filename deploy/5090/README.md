# llama.cpp-5090 on the RTX 5090 host

The fork is compiled only in GitHub Actions (`.github/workflows/docker-5090.yml`, Dockerfile `.devops/cuda-5090.Dockerfile`).
The GPU host never compiles: it pulls `ghcr.io/qbanin/llama.cpp-5090:<tag>` and runs it with `docker compose`.

## Image

- Base: `nvidia/cuda:13.5.0-runtime-ubuntu24.04` (runtime), `nvidia/cuda:13.5.0-devel-ubuntu24.04` (build and profiling).
- Build: `-DCMAKE_CUDA_ARCHITECTURES=120a-real` (SASS for RTX 5090 only, no PTX), `-DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON`; tests are built as explicit targets because the full suite does not link with `GGML_BACKEND_DL=ON`.
- Binaries in `/app` (also on `PATH`): `llama-server`, `llama-cli`, `llama-bench`, `llama-perplexity`, `llama-quantize`, `llama-batched-bench`, `llama-tokenize` and the other tools and examples from `build/bin`, plus `test-backend-ops`, `test-backend-tensor`, `test-backend-sampler`, `test-thread-safety`. Backends are the `libggml-*.so` files next to them.
- Runs as user `llama` (uid 1000). No models, no secrets inside.
- `*-profiling` tags: same binaries on the devel base plus Nsight Systems (`nsys`) and Nsight Compute (`ncu`), ~17 GB. Built only on `master` and `workflow_dispatch`.

### Tags

| tag | when |
|---|---|
| `latest`, `latest-profiling` | push to `master` |
| `master`, `master-profiling` | push to `master` |
| `sha-<short>`, `sha-<short>-profiling` | every build |
| `pr-<nr>` | every pull request from this repository (no profiling image) |
| `buildcache`, `buildcache-profiling` | Buildx layer cache, not runnable |

PRs from external forks do not build or publish images.

### Why CUDA 13.5

Upstream `.devops/cuda.Dockerfile` defaults to CUDA 12.8.1 and also builds a `cuda13` image with 13.5.0 (see `.github/workflows/docker.yml`).
13.5 bundles CCCL >= 3.5, so the CUDA backend builds without `GGML_CUDA_CCCL_VERSION` (`top-k.cu`, `argsort.cu` need CCCL >= 3.4.3 for the fast paths),
and it is the toolkit NVIDIA ships for the R620 driver branch. The version lives in one place: `ARG CUDA_VERSION` in the Dockerfile and `env.CUDA_VERSION` in the workflow.

## Host requirements

- NVIDIA driver for the CUDA 13.x series: **>= 580** (R580 branch) is the minimum under CUDA minor version compatibility;
  **R620** is the branch that corresponds to CUDA 13.5 (CUDA Toolkit 13.5 release notes, section "CUDA Driver").
  The image is built with `120a-real` (SASS only), so it does not depend on PTX JIT support of a newer driver.
  The forward-compatibility package inside the image (`/usr/local/cuda/compat`) does not apply to GeForce GPUs, so the host driver must meet the minimum.
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) configured for Docker (`nvidia-ctk runtime configure --runtime=docker`).
- Docker Engine with Compose v2 (`docker compose version`).
- Models directory on the host with world-readable GGUF files (mounted read-only, read by uid 1000).
- The GHCR package is public, so no `docker login ghcr.io` is needed. If it is private: `echo $GH_TOKEN | docker login ghcr.io -u <user> --password-stdin` with a token that has `read:packages`.

One-time step after the first publish: GitHub creates a new container package as private.
Change it to public in GitHub -> Packages -> `llama.cpp-5090` -> Package settings -> Change visibility. `GITHUB_TOKEN` cannot do this.

## Usage

```bash
cd deploy/5090
cp .env.example .env          # set MODELS_DIR, LLAMA_MODEL, LLAMA_TAG

docker compose pull                      # only pulls, never builds
docker compose up -d server              # http://localhost:8080 (healthcheck on /health)
docker compose logs -f server

docker compose run --rm test             # test-backend-ops test -b CUDA0
docker compose run --rm test test -b CUDA0 -o MUL_MAT
docker compose run --rm bench            # llama-bench -m /models/$LLAMA_MODEL $LLAMA_BENCH_ARGS
docker compose run --rm bench -m /models/other.gguf -fa 1 -p 512 -n 128 -ngl 99

docker compose down
```

`llama-server` is configured through `LLAMA_ARG_*` environment variables (`LLAMA_NGL`, `LLAMA_CTX`, `LLAMA_FA` in `.env`) plus `LLAMA_SERVER_ARGS` for everything else, for example `--backend-sampling` or `--n-cpu-moe 8`.

### Run the image of a pull request

```bash
LLAMA_TAG=pr-123 docker compose pull
LLAMA_TAG=pr-123 docker compose run --rm test
LLAMA_TAG=pr-123 docker compose run --rm bench
LLAMA_TAG=pr-123 docker compose up -d server
```

`pr-<nr>` moves with every push to the PR. Use `LLAMA_PULL_POLICY=always` in `.env`, or `docker compose pull` again, to pick up a new build. `sha-<short>` tags are immutable.

### Verify the GPU inside the container

```bash
docker compose run --rm --entrypoint nvidia-smi server
docker compose run --rm --entrypoint bash server -c 'ls -la /app && llama-cli --version'
docker compose run --rm test support -b CUDA0 | head
docker compose run --rm --entrypoint llama-bench server -m /models/$LLAMA_MODEL -fa 1 -p 512 -n 128
```

`nvidia-smi` comes from the host driver through the Container Toolkit. `test-backend-ops test -b CUDA0` compares every op on the GPU against the CPU backend.

### Profiling (Perf and QA)

```bash
LLAMA_TAG=master docker compose pull profile
docker compose run --rm profile                                     # nsys profile of llama-bench -> ./reports/llama-bench.nsys-rep
docker compose run --rm --entrypoint ncu profile --set full -o /reports/decode llama-bench -m /models/$LLAMA_MODEL -fa 1 -p 0 -n 32
docker compose run --rm --entrypoint bash profile                   # interactive
```

The `profile` service runs as root with `cap_add: SYS_ADMIN`: `ncu` needs an effective `CAP_SYS_ADMIN` to read GPU performance counters, and a non-root container user cannot hold it.
Alternative without root: on the host `echo 'options nvidia NVreg_RestrictProfilingToAdminUsers=0' > /etc/modprobe.d/nvidia-profiling.conf` and reload the driver.
Reports land in `REPORTS_DIR` (default `./reports`, git-ignored).

### PCIe traffic

```bash
nvidia-smi dmon -s t                     # host, while bench or server runs
```

## Local build (reference only, not for the GPU host)

```bash
docker build -f .devops/cuda-5090.Dockerfile --target runtime -t llama.cpp-5090:local .
docker build -f .devops/cuda-5090.Dockerfile --target profiling -t llama.cpp-5090:local-profiling .
docker build -f .devops/cuda-5090.Dockerfile --target runtime --build-arg BUILD_JOBS=4 .   # limit parallel nvcc jobs (RAM)
```

Upstream workflows that stay enabled in the fork and the list of disabled ones: `deploy/5090/ci-workflows.md`.
