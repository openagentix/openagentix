# Evaluation harness. `make test` needs nothing but Go (and the yaml module from the Go module cache).

.PHONY: build test vet fmt

build:
	CGO_ENABLED=0 go build -trimpath -o bin/oa-eval ./cmd/oa-eval

test:
	go test ./... -race -count=1

vet:
	go vet ./...

fmt:
	@test -z "$$(gofmt -l .)" || (gofmt -l .; exit 1)
