# Records service (system of record for the reference use cases). `make test` needs only Go.
IMAGE ?= openagentix/records-bank:dev
DOMAIN ?= bank

.PHONY: build test vet fmt docker

build:
	CGO_ENABLED=0 go build -trimpath -ldflags="-X main.defaultDomain=$(DOMAIN)" -o bin/records ./cmd/records

test:
	go test ./... -race -count=1

vet:
	go vet ./...

fmt:
	@test -z "$$(gofmt -l .)" || (gofmt -l .; exit 1)

docker:
	docker build --build-arg DOMAIN=$(DOMAIN) -t $(IMAGE) .
