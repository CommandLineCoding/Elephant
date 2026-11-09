FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o elephant-server .

# Distroless: CA certificates, tzdata and our binary, with no shell or package
# manager. Smaller, and far less for an attacker to use if the server is ever
# compromised. The binary is static (CGO_ENABLED=0), so it needs nothing else.
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app
COPY --from=builder /app/elephant-server .

# Unprivileged. The server writes nothing, so any other id works too: Compose
# sets it with `user:` (ELEPHANT_UID / ELEPHANT_GID).
USER 1000:1000

# Go doesn't know about container memory limits, so after a burst of work
# (e.g. many password hashes at once) it keeps the memory it grew to. A soft
# limit makes it collect more eagerly and hand memory back. Set it to roughly
# 80% of the container's memory: raise it on a bigger host, or override it with
# the GOMEMLIMIT environment variable.
ENV GOMEMLIMIT=400MiB

EXPOSE 3000

ENTRYPOINT ["./elephant-server"]