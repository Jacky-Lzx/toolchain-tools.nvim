FROM node:24-bookworm-slim
ARG NVIM_VERSION=v0.11.5
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git gzip tar unzip xz-utils zip python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
RUN case "$(dpkg --print-architecture)" in \
      arm64) toolchain_arch=arm64 ;; amd64) toolchain_arch=x86_64 ;; *) exit 1 ;; \
    esac \
    && curl --fail --location --retry 2 \
      "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${toolchain_arch}.tar.gz" \
      --output /tmp/nvim.tar.gz \
    && mkdir /opt/nvim \
    && tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1 \
    && rm /tmp/nvim.tar.gz
ENV PATH="/opt/nvim/bin:${PATH}" PYTHONDONTWRITEBYTECODE=1
WORKDIR /workspace
CMD ["sh", "tests/run.sh", "--tools"]
