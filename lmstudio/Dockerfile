# CUDA 12.4 runtime requires host NVIDIA driver >= 550.
# nvidia/cuda:12.4.1-runtime-ubuntu24.04 does not exist; ubuntu22.04 is the correct base.
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    libatomic1 \
    && rm -rf /var/lib/apt/lists/*

# LM Studio must not run as root; uid 1000 is required
RUN useradd -m -u 1000 -s /bin/bash lmstudio
USER lmstudio
WORKDIR /home/lmstudio

# Install LM Studio CLI (lms) and headless daemon (llmster) to ~/.lmstudio/bin/
RUN curl -fsSL https://lmstudio.ai/install.sh | bash

ENV PATH="/home/lmstudio/.lmstudio/bin:${PATH}"
ENV HOME="/home/lmstudio"

COPY --chown=lmstudio:lmstudio entrypoint.sh /home/lmstudio/entrypoint.sh
RUN chmod +x /home/lmstudio/entrypoint.sh

EXPOSE 1234

ENTRYPOINT ["/home/lmstudio/entrypoint.sh"]
