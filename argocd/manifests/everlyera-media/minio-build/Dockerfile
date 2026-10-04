FROM golang:1.24.8-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X github.com/minio/minio/cmd.Version=2025-10-15T17:29:55Z -X github.com/minio/minio/cmd.ReleaseTag=RELEASE.2025-10-15T17-29-55Z -X github.com/minio/minio/cmd.CommitID=9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a -X github.com/minio/minio/cmd.ShortCommitID=9e49d5e7a648 -X github.com/minio/minio/cmd.CopyrightYear=2025" -o /minio .
FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=build /minio /usr/bin/minio
COPY LICENSE /licenses/LICENSE
EXPOSE 9000 9001
ENTRYPOINT ["/usr/bin/minio"]
