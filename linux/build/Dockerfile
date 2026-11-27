# The Linux build and test environment: Ubuntu 24.04 (GTK 4.14, libadwaita 1.5, glibc 2.39), the oldest system the
# AppImage supports. scripts/rr/build-linux.sh --container runs in it on hosts without these packages; GitHub's
# ubuntu-24.04 runners install the same list directly (linux/build/packages.txt).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
COPY packages.txt /tmp/packages.txt
RUN apt-get update \
 && xargs -a /tmp/packages.txt apt-get install -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*
# Rust from rustup (minimal profile); the toolchain is pinned by rust/Cargo.toml's rust-version floor, not here.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path \
 && rustup component add clippy rustfmt \
 && chmod -R a+rwX /opt/cargo /opt/rustup
