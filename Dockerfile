ARG REGISTRY=docker.io
FROM ${REGISTRY}/hashicorp/packer:1.16.2

RUN apk add --no-cache ansible ca-certificates openssh-client qemu-img qemu-system-x86_64 xorriso

# Extra CA certificates (*.pem, *.crt) from the certs build context
COPY --from=certs / /tmp/certs/
RUN find /tmp/certs -type f \( -name '*.pem' -o -name '*.crt' \) -exec cat {} + >> /etc/ssl/certs/ca-certificates.crt

# The base image runs packer. This one runs the command it is given.
ENTRYPOINT []
