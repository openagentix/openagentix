# Build the binary first: `make build` (CGO off, linux/arm64). It is not built
# in Docker because go.mod replaces github.com/google/ax with a local checkout.
FROM gcr.io/distroless/static:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5
COPY bin/ax-adapter /ax-adapter
USER nonroot:nonroot
ENTRYPOINT ["/ax-adapter"]
