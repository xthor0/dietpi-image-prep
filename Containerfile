# Linux userland for running prepare-image.sh on macOS (see run_in_container in prepare-image.sh).
# The script loop-mounts the image's ext4 partition, which needs the Podman machine's Linux kernel.
FROM docker.io/library/debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends xz-utils util-linux mount \
 && rm -rf /var/lib/apt/lists/*
