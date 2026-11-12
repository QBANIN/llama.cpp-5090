# Image for NVIDIA RTX 5090 (Blackwell, sm_120a) only.
# Separate from .devops/cuda.Dockerfile so that rebases on upstream do not conflict.
# Usage: see deploy/5090/README.md
ARG UBUNTU_VERSION=24.04
ARG CUDA_VERSION=13.5.0
ARG GCC_VERSION=14
ARG NODE_VERSION=24
ARG BASE_CUDA_DEV_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}
ARG BASE_CUDA_RUN_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

### Web UI (embedded into llama-server)
FROM docker.io/node:${NODE_VERSION} AS web

ARG APP_VERSION

WORKDIR /app/tools/ui

COPY tools/ui/package.json tools/ui/package-lock.json ./
RUN npm ci

COPY tools/ui/ ./
RUN LLAMA_BUILD_NUMBER="$APP_VERSION" npm run build

### Build
FROM ${BASE_CUDA_DEV_CONTAINER} AS build

ARG GCC_VERSION
# 120a-real: SASS for RTX 5090 only, no PTX. Shorter build, smaller image.
ARG CUDA_DOCKER_ARCH=120a-real
# empty = nproc
ARG BUILD_JOBS=

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc-${GCC_VERSION} g++-${GCC_VERSION} build-essential cmake ninja-build git python3 libssl-dev libgomp1 && \
    rm -rf /var/lib/apt/lists/*

ENV CC=gcc-${GCC_VERSION} CXX=g++-${GCC_VERSION} CUDAHOSTCXX=g++-${GCC_VERSION}

WORKDIR /app

COPY . .

COPY --from=web /app/tools/ui/dist tools/ui/dist

# GGML_NATIVE=OFF + GGML_CPU_ALL_VARIANTS=ON: the CPU of the CI runner is not the CPU of the GPU host.
# The full test suite does not link with GGML_BACKEND_DL=ON (test-kv-cache uses CPU backend symbols),
# so the tests needed on the GPU host are built as explicit targets in a second pass.
RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES=${CUDA_DOCKER_ARCH} \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
        -DGGML_NATIVE=OFF \
        -DGGML_CUDA=ON \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_TOOLS=ON \
        -DLLAMA_BUILD_SERVER=ON && \
    cmake --build build --config Release -j${BUILD_JOBS:-$(nproc)} && \
    cmake -S . -B build -DLLAMA_BUILD_TESTS=ON && \
    cmake --build build --config Release -j${BUILD_JOBS:-$(nproc)} \
        --target test-backend-ops test-backend-tensor test-backend-sampler test-thread-safety

RUN mkdir -p /app/lib /app/bin && \
    find build -name "*.so*" -exec cp -P {} /app/lib \; && \
    find build/bin -maxdepth 1 -type f -perm -u+x ! -name "*.so*" -exec cp {} /app/bin \;

### Runtime (default target): llama-server, llama-cli, llama-bench, llama-perplexity, test-backend-ops, ...
FROM ${BASE_CUDA_RUN_CONTAINER} AS runtime

ARG CUDA_VERSION
ARG CUDA_DOCKER_ARCH=120a-real
ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
ARG IMAGE_SOURCE=https://github.com/QBANIN/llama.cpp-5090
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp-5090" \
      org.opencontainers.image.description="llama.cpp for NVIDIA RTX 5090 (CUDA ${CUDA_VERSION}, ${CUDA_DOCKER_ARCH})" \
      org.opencontainers.image.url=$IMAGE_SOURCE \
      org.opencontainers.image.source=$IMAGE_SOURCE \
      com.nvidia.cuda.version=$CUDA_VERSION \
      org.ggml.cuda.architectures=$CUDA_DOCKER_ARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends libgomp1 curl ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Some hosts only mount the driver here (see .devops/cuda.Dockerfile)
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib64:/usr/local/nvidia/lib:${LD_LIBRARY_PATH}

# ggml loads the backend .so files from the directory of the executable, so libs and bins share /app
COPY --from=build /app/lib/ /app/
COPY --from=build /app/bin/ /app/

# non-root user; /dev/nvidia* are world rw, so the GPU still works
RUN (userdel -r ubuntu 2>/dev/null || true) && \
    useradd -m -u 1000 -U -s /bin/bash llama

ENV PATH=/app:${PATH}
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080

WORKDIR /app
USER llama

CMD ["llama-server", "--help"]

### Profiling: runtime binaries + Nsight Systems (nsys) + Nsight Compute (ncu), built only on master / workflow_dispatch
FROM ${BASE_CUDA_DEV_CONTAINER} AS profiling

ARG CUDA_VERSION
ARG CUDA_DOCKER_ARCH=120a-real
ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
ARG IMAGE_SOURCE=https://github.com/QBANIN/llama.cpp-5090
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp-5090-profiling" \
      org.opencontainers.image.description="llama.cpp for NVIDIA RTX 5090 (CUDA ${CUDA_VERSION}, ${CUDA_DOCKER_ARCH}) + Nsight Systems/Compute" \
      org.opencontainers.image.url=$IMAGE_SOURCE \
      org.opencontainers.image.source=$IMAGE_SOURCE \
      com.nvidia.cuda.version=$CUDA_VERSION \
      org.ggml.cuda.architectures=$CUDA_DOCKER_ARCH

# cuda-nsight-*-X-Y package names use the major-minor of CUDA_VERSION (13.5.0 -> 13-5).
# The packages put nsys and ncu wrappers into /usr/local/cuda/bin, which is already on PATH.
RUN CUDA_PKG="$(echo "${CUDA_VERSION}" | cut -d. -f1,2 | tr . -)" && \
    apt-get update && \
    apt-get install -y --no-install-recommends libgomp1 curl ca-certificates \
        cuda-nsight-systems-${CUDA_PKG} cuda-nsight-compute-${CUDA_PKG} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    nsys --version && \
    ncu --version

ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib64:/usr/local/nvidia/lib:${LD_LIBRARY_PATH}

COPY --from=build /app/lib/ /app/
COPY --from=build /app/bin/ /app/

ENV PATH=/app:${PATH}

WORKDIR /app

# root: ncu needs an effective CAP_SYS_ADMIN for GPU performance counters (see deploy/5090/README.md)
CMD ["bash"]
