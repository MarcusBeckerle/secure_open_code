FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.opencode/bin:/root/.local/bin:/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install OpenCode via official installer
RUN curl -fsSL https://opencode.ai/install | bash

# Configure OpenCode with XQAI provider
RUN mkdir -p /root/.config/opencode
COPY opencode.jsonc /root/.config/opencode/opencode.jsonc

WORKDIR /workspace

CMD ["opencode"]
