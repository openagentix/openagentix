# syntax=docker/dockerfile:1
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/stub-model ./cmd/stub-model

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/stub-model /stub-model
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/stub-model"]
