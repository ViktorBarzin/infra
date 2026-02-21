FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /f1-stream .

FROM alpine:3.20
RUN apk add --no-cache \
    ca-certificates \
    chromium nss freetype harfbuzz ttf-freefont \
    mesa-dri-gallium mesa-gl \
    dbus \
    xvfb-run xorg-server \
    pulseaudio pulseaudio-utils \
    ffmpeg
ENV CHROME_PATH=/usr/bin/chromium-browser
COPY --from=builder /f1-stream /f1-stream
COPY static/ /static/
EXPOSE 8080
ENTRYPOINT ["/f1-stream"]
