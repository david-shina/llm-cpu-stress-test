# Dockerfile for CPU-only llama.cpp inference test of medLLM_V1 (Q4_K_M GGUF).
# Target host (Windows + Docker Desktop WSL2): i7-12700H, 31 GB RAM, emulates an
# i5 10th-12th gen / 7 GB laptop via `docker run --memory=7g --cpus=4 --cpuset-cpus=0-3`.
#
# Build:
#   docker build -t llm-cpu-test .
#
# Pinned llama.cpp commit for reproducibility. Update the LLAMA_COMMIT arg to
# rebuild against a newer release. Tag chosen: a stable build from Aug 2026 that
# ships `llama-cli`, `llama-server`, `llama-bench` (post llamafile naming change).

FROM ubuntu:22.04

ARG LLAMA_COMMIT=HEAD
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    ca-certificates \
    curl \
    python3 \
    python3-pip \
    apache2-utils \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
# Clone latest master (shallow). If LLAMA_COMMIT != HEAD, fetch and checkout that
# exact ref; otherwise build the tip of master that was just cloned.
RUN git clone --depth 1 https://github.com/ggerganov/llama.cpp.git llama.cpp && \
    cd llama.cpp && \
    if [ "$LLAMA_COMMIT" != "HEAD" ]; then \
        git fetch --depth 1 origin "$LLAMA_COMMIT" && git checkout "$LLAMA_COMMIT"; \
    fi

WORKDIR /opt/llama.cpp
RUN mkdir build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=ON \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_CURL=OFF \
        -DGGML_OPENSSL=OFF \
        -DBUILD_SHARED_LIBS=OFF \
    && cmake --build . --config Release -j4

# Put binaries on PATH. After the llamafile naming rename they are
# llama-cli / llama-server / llama-bench / llama-quantize in build/bin/.
ENV PATH="/opt/llama.cpp/build/bin:${PATH}"

# Python helpers inside container (used by analyze.py if re-run there).
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir requests

WORKDIR /test
COPY llm_run.sh /test/llm_run.sh
COPY prompts/ /test/prompts/

RUN chmod +x /test/llm_run.sh

# Default entrypoint runs the full 4-stage stress sequence.
ENTRYPOINT ["/test/llm_run.sh"]