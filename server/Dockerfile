FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o elephant-server .

FROM alpine:3.20

RUN apk --no-cache add ca-certificates tzdata

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

COPY --from=builder /app/elephant-server .

RUN chown -R appuser:appgroup /app
USER appuser

# Go doesn't know about container memory limits, so after a burst of work
# (e.g. many password hashes at once) it keeps the memory it grew to. A soft
# limit makes it collect more eagerly and hand memory back. Set it to roughly
# 80% of the container's memory: raise it on a bigger host, or override it with
# the GOMEMLIMIT environment variable.
ENV GOMEMLIMIT=400MiB

EXPOSE 3000

CMD ["./elephant-server"]