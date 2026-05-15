FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.opencode/bin:/root/.local/bin:/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    nodejs \
    npm \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Install OpenCode via official installer
RUN curl -fsSL https://opencode.ai/install | bash

# Configure OpenCode with XQAI provider
RUN mkdir -p /root/.config/opencode
# Include repository's default OpenCode config in the image so containers
# have a sane default even when the workspace mounted at /workspace doesn't
# contain an opencode.jsonc. This prevents missing config when users bind
# different project folders as the container's workdir.
COPY opencode.jsonc /root/.config/opencode/opencode.jsonc

# Install entrypoint script that copies runtime config into place
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["opencode"]
