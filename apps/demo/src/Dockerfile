# Base images pinned by digest (tag kept for readability).
# The build is deterministic for a given source: no VCS stamping, read-only module graph (go.sum is
# authoritative), stripped paths. release.yml also passes SOURCE_DATE_EPOCH so image timestamps are
# fixed and a rebuild of the same commit yields the same image config.
FROM golang:1.26-alpine@sha256:a2012b4a1d1f9f7e9f44e0d39b805a901e856b1dd80b4e6ee4338db547050308 AS build
ENV CGO_ENABLED=0 GOFLAGS=-mod=readonly
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY *.go ./
RUN go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/demo .

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
# OCI labels; release.yml sets the real values. The source label also links the GHCR package to the repo.
ARG VERSION=dev
ARG REVISION=unknown
ARG SOURCE=https://github.com/astawiany/fleet-in-a-repo
LABEL org.opencontainers.image.title="fleet-demo" \
      org.opencontainers.image.description="Fleet-in-a-Repo demo app (web, api, worker)" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT"
COPY --from=build /out/demo /demo
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/demo"]
