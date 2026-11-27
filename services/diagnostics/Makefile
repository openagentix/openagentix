# Diagnostics tool servers (ADR 0025). `make test` needs nothing but Go: the
# Kubernetes API is the fake client of client-go, and no model or cluster is used.

IMAGE ?= openagentix/diagnostics:dev

.PHONY: build test cover vet fmt docker

build:
	CGO_ENABLED=0 go build -trimpath -o bin/ ./cmd/...

test:
	go test ./... -race -count=1

cover:
	go test ./... -count=1 -cover

vet:
	go vet ./...

fmt:
	@test -z "$$(gofmt -l .)" || (gofmt -l .; exit 1)

docker:
	docker build -t $(IMAGE) .
