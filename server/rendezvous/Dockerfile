# syntax=docker/dockerfile:1.7
# bridgey-rendezvous, the Connect anywhere control service (docs/connect-anywhere.md, section 6).
# Built on rr-dev-1 for arm64 (rr-web): the Rust build runs natively and cross-compiles to a static
# musl binary with cargo-zigbuild, so nothing is emulated. Context: the repository root.
FROM --platform=$BUILDPLATFORM ghcr.io/rust-cross/cargo-zigbuild:0.20.1 AS build
ARG TARGETARCH
WORKDIR /src
COPY rust/ rust/
COPY server/rendezvous/bridgey-rendezvous.toml server/rendezvous/bridgey-rendezvous.toml
RUN case "$TARGETARCH" in \
      arm64) target=aarch64-unknown-linux-musl ;; \
      amd64) target=x86_64-unknown-linux-musl ;; \
      *) echo "unsupported architecture $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && rustup target add "$target" \
 && cd rust \
 && cargo zigbuild --release --locked -p bridgey-rendezvous --target "$target" \
 && install -D "target/$target/release/bridgey-rendezvous" /out/bridgey-rendezvous

FROM scratch
COPY --from=build /out/bridgey-rendezvous /bridgey-rendezvous
COPY server/rendezvous/bridgey-rendezvous.toml /etc/bridgey/bridgey-rendezvous.toml
USER 65534:65534
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s CMD ["/bridgey-rendezvous", "--health"]
ENTRYPOINT ["/bridgey-rendezvous"]
CMD ["/etc/bridgey/bridgey-rendezvous.toml"]
