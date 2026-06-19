FROM alpine:latest

WORKDIR /app

RUN apk add --no-cache \
    curl \
    ca-certificates \
    unzip \
    iproute2 \
    libc6-compat \
    tzdata

COPY x-cf.sh .
RUN chmod +x x-cf.sh

ENV UUID=""
ENV DOMAIN=""

CMD ["./x-cf.sh"]
