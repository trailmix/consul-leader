FROM alpine:3.14.2
RUN apk add jq bash curl

COPY --chmod=0755 consul.sh /consul-leader.sh
ENTRYPOINT [ "/bin/bash","/consul-leader.sh" ]