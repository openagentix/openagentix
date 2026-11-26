# syntax=docker/dockerfile:1
# Build context is the repository root: docker build -f services/console/Dockerfile .
# build-context: .
#
# Base images are pinned by digest (the multi-platform index; the tag each digest was taken from is in the comment above it).
# To update: docker buildx imagetools inspect <tag>, copy the "Digest:" line here.

# node:22
FROM node:25@sha256:78839ac448c23517f8eab2e8f7943d9b4f73979eb7f8bed2c73dbf72ff869e7b AS web
# package.json carries "packageManager": "pnpm@<version>+sha512.<hash>", so corepack fetches exactly that pnpm and checks its hash
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
WORKDIR /src/console
COPY console/package.json console/pnpm-lock.yaml console/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY console/ ./
RUN pnpm build

# golang:1.25
FROM golang:1.25@sha256:699337d620559a59b4a2bb298ad59611e535d2ee755a34cf2d2a98f37578dc80 AS build
WORKDIR /src
COPY services/console/ ./
COPY --from=web /src/console/build ./web/dist
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/console ./cmd/console

# gcr.io/distroless/static:nonroot
FROM gcr.io/distroless/static:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5
COPY --from=build /out/console /console
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/console"]
