FROM golang:alpine
# kubectl, curl and jq serve the daily showcase pipeline (.woodpecker/showcase.yml),
# which reads live cluster state and its Vault token from inside this image.
RUN apk add --no-cache kubectl curl jq
RUN mkdir /app 
ADD . /app/
WORKDIR /app 
RUN go build -o infra_cli .
RUN adduser -S -D -H -h /app appuser
USER appuser
CMD ["./infra_cli", "-h"]
