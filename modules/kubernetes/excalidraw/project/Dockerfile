FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod ./
COPY main.go ./
COPY static/ ./static/

RUN go build -o excalidraw-library .

FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /app/excalidraw-library .

ENV DATA_DIR=/data
ENV PORT=8080

EXPOSE 8080

CMD ["./excalidraw-library"]
