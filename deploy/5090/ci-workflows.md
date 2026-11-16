# GitHub Actions in the fork

The fork inherits 62 workflow files from upstream. Only four are meant to run here; the rest are disabled in the
repository settings (`gh workflow disable`), not deleted or edited, so that rebases on `ggml-org/llama.cpp` stay conflict-free.
GitHub registers a workflow file on the first push that touches it, so a newly registered one can run once before it is disabled.

## Enabled

| workflow | why |
|---|---|
| `docker-5090.yml` (Docker (RTX 5090)) | builds and publishes the image used on the GPU host |
| `build-cpu.yml` (CI (cpu)) | CPU build + `ctest -L main` on Linux/Windows: catches breakage of the non-CUDA code paths |
| `code-style.yml` (Code Style Checker) | cheap style gate |
| `editorconfig.yml` (EditorConfig Checker) | cheap style gate |

## Disabled

Everything else. Grouped by reason:

**Publish to upstream infrastructure, need upstream secrets** (`DEPLOY_KEY_RELEASE`, `PYPI_API_TOKEN`, `WINGET_GITHUB_TOKEN`):
`docker.yml` (nightly, all backends, would create a second package `llama.cpp` under the fork owner), `release.yml` (every push to master builds release binaries for all platforms), `release-publish.yml`, `make-release.yml`, `gguf-publish.yml`, `winget.yml`, `ui-publish.yml`.

**Self-hosted runners of ggml-org** (jobs would queue forever in the fork):
`ci-self-hosted-cpu.yml`, `ci-self-hosted-cuda.yml`, `ci-self-hosted-kleidiai.yml`, `ci-self-hosted-metal.yml`, `ci-self-hosted-openvino.yml`, `ci-self-hosted-vulkan.yml`, `ci-self-hosted-webgpu.yml`, `server-self-hosted.yml`, `server-speculative.yml`, `ui-self-hosted.yml`, `ui-build-self-hosted.yml`, `build-cache.yml`, `build-cross.yml`, `build-msys.yml`, `build-openvino.yml`, `models-check.yml`.

**Other backends and platforms, not relevant for the RTX 5090 target** (each costs 10-60 runner minutes per PR):
`build-android.yml`, `build-apple.yml`, `build-apple-daily.yml`, `build-cann.yml`, `build-ibm.yml`, `build-opencl.yml`, `build-riscv.yml`, `build-sycl.yml`, `build-virtgpu.yml`, `build-vulkan.yml`, `build-wasi.yml`, `build-wasm.yml`, `build-webgpu.yml`, `build-and-test-snapdragon.yml`, `build-cuda-windows.yml`, `build-3rd-party.yml`, `hip-quality-check.yml`.

**Upstream CUDA CI, replaced by `docker-5090.yml`:**
`build-cuda-ubuntu.yml` builds CUDA 12.6 for `89-real` plus HIP and MUSA, with ccache in HF buckets (`HF_TOKEN_CI` is not set in the fork). Candidate to re-enable as a second compiler check if needed.

**Tests and checks for code the fork does not touch** (CPU-only, 5-40 minutes per PR each):
`server.yml`, `server-sanitize.yml`, `build-sanitize.yml`, `behavior-check.yml`, `ui.yml`, `ui-build.yml`, `python-check-requirements.yml`, `python-lint.yml`, `python-type-check.yml`, `check-vendor.yml`, `pre-tokenizer-hashes.yml`, `update-ops-docs.yml`, `copilot-setup-steps.yml`.
Candidates to re-enable for a specific PR: `server.yml` when `tools/server` changes, `build-sanitize.yml` for ASan/UBSan/TSan runs, `behavior-check.yml` for the `behavior` ctest label.

**Repository bots** (act on issues and PRs of the fork):
`close-issue.yml` (closes inactive issues), `pr-draft-label.yml` (converts labeled PRs to draft), `labeler.yml`, `pr-video-demo-label.yml`, `ai-issues.yml`.

`bench.yml.disabled` is already disabled by its file name.

## Disable script

Run after every push that registers new workflow files (see the issue LL-1):

```bash
R=QBANIN/llama.cpp-5090
KEEP='^\.github/workflows/(docker-5090|build-cpu|code-style|editorconfig)\.ya?ml$'
gh api "repos/$R/actions/workflows?per_page=100" --jq '.workflows[]|"\(.id) \(.state) \(.path)"' |
while read id st path; do
  [[ "$path" =~ $KEEP ]] && continue
  [ "$st" = active ] && gh api -X PUT "repos/$R/actions/workflows/$id/disable" && echo "disabled $path"
done
gh run list -R $R -L 100 --json databaseId,status,workflowName --jq '.[]|select(.status!="completed")|"\(.databaseId) \(.workflowName)"' |
while read rid name; do
  case "$name" in "CI (cpu)"|"Code Style Checker"|"EditorConfig Checker"|*5090*) ;; *) gh run cancel -R $R "$rid" && echo "cancelled $rid $name";; esac
done
```
