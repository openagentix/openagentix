# syntax=docker/dockerfile:1
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/echo-a2a .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/echo-a2a /echo-a2a
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/echo-a2a"]
