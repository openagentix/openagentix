# syntax=docker/dockerfile:1
# One binary, one domain per image: build with --build-arg DOMAIN=bank (the only domain so far).
FROM golang:1.25@sha256:699337d620559a59b4a2bb298ad59611e535d2ee755a34cf2d2a98f37578dc80 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG DOMAIN=bank
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X main.version=${VERSION} -X main.defaultDomain=${DOMAIN}" -o /out/records ./cmd/records
# The data directory is the only writable path. It is owned by the nonroot user (65532) of the distroless base.
RUN mkdir -p /out/data && chown 65532:65532 /out/data

FROM gcr.io/distroless/static:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5
COPY --from=build /out/records /records
COPY --from=build --chown=65532:65532 /out/data /data
USER nonroot:nonroot
ENV RECORDS_DATA_DIR=/data
EXPOSE 8080 8081
ENTRYPOINT ["/records"]
