# dockerhub: viktorbarzin/redfish-exporter
# repo: https://pkg.go.dev/github.com/jenningsloy318/redfish_exporter#section-readme
FROM golang:rc-bullseye AS builder

LABEL maintainer="Viktor Barzin <me@viktorbarzin.me>"

ARG ARCH=amd64

ENV GOROOT /usr/local/go
ENV GOPATH /go
ENV PATH "$GOROOT/bin:$GOPATH/bin:$PATH"
ENV GO_VERSION 1.15.2
ENV GO111MODULE=on 


# Build dependencies
RUN mkdir -p /go/src/github.com/ && \
    git clone https://github.com/jenningsloy318/redfish_exporter /go/src/github.com/jenningsloy318/redfish_exporter && \
    cd /go/src/github.com/jenningsloy318/redfish_exporter && \
    make build

FROM golang:rc-bullseye

COPY --from=builder /go/src/github.com/jenningsloy318/redfish_exporter/build/redfish_exporter /usr/local/bin/redfish_exporter
RUN mkdir /etc/prometheus
# config file mounter at runtime
CMD ["/usr/local/bin/redfish_exporter", "--config.file", "/etc/prometheus/redfish_exporter.yml"]
