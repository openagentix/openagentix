# Stub model. `make test` needs nothing but Go; the module has no dependencies outside the standard library.

IMAGE ?= openagentix/stub-model:dev

.PHONY: build test vet fmt docker

build:
	CGO_ENABLED=0 go build -trimpath -o bin/stub-model ./cmd/stub-model

test:
	go test ./... -race -count=1

vet:
	go vet ./...

fmt:
	@test -z "$$(gofmt -l .)" || (gofmt -l .; exit 1)

docker:
	docker build -t $(IMAGE) .
