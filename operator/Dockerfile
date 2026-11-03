FROM golang:1.27-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/manager ./cmd/manager

FROM ubuntu:24.04
COPY --from=build /out/manager /manager
USER 65532:65532
ENTRYPOINT ["/manager"]
