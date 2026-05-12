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

# Install entrypoint script that copies runtime config into place
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["opencode"]
