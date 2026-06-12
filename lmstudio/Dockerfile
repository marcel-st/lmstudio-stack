# ─── Stage 1: Build llama-server with CUDA ───────────────────────────────────
# RTX 5060 Ti (Blackwell / sm_120) requires CUDA 12.6+; host driver must be ≥570.
# Official llama.cpp releases ship Linux CPU-only binaries, so we build from source.
# This fixes the gemma4uv projector error that blocked Gemma 4 12B in LM Studio.
FROM nvidia/cuda:12.8.0-devel-ubuntu22.04 AS llama-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake git build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp /llama.cpp

# libcuda.so.1 is not present at Docker build time (injected by the host driver
# at runtime via --gpus). Create a versioned symlink to the CUDA stub so the
# linker can resolve it; the real library is used when the container runs.
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/lib/libcuda.so.1 \
    && ldconfig

# sm_89 = Ada Lovelace (RTX 40xx)  sm_120 = Blackwell (RTX 50xx)
# Extend the list if you need sm_86 (RTX 30xx) or sm_80 (A100).
RUN cmake -B /llama.cpp/build -S /llama.cpp \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="89;120" \
        -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /llama.cpp/build -j"$(nproc)" --target llama-server

# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

# libcublas is already present in the cuda:12.8.0-runtime base image
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates libatomic1 libgomp1 gosu \
    && rm -rf /var/lib/apt/lists/*

# Copy entire build output (binary + shared libs like libllama-server-impl.so, libggml-cuda.so, etc.)
COPY --from=llama-builder /llama.cpp/build/bin/ /usr/local/lib/llama/
RUN ln -s /usr/local/lib/llama/llama-server /usr/local/bin/llama-server \
    && echo "/usr/local/lib/llama" > /etc/ld.so.conf.d/llama.conf \
    && ldconfig

# LM Studio must not run as root; uid 1000 is required
RUN useradd -m -u 1000 -s /bin/bash lmstudio
USER lmstudio
WORKDIR /home/lmstudio

# Install LM Studio CLI (lms) — used only for model downloads; llama-server handles inference
RUN curl -fsSL https://lmstudio.ai/install.sh | bash

ENV PATH="/home/lmstudio/.lmstudio/bin:${PATH}"
ENV HOME="/home/lmstudio"

USER root
COPY --chown=lmstudio:lmstudio entrypoint.sh /home/lmstudio/entrypoint.sh
RUN chmod +x /home/lmstudio/entrypoint.sh

EXPOSE 1234
ENTRYPOINT ["/home/lmstudio/entrypoint.sh"]
