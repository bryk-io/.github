FROM ghcr.io/bryk-io/shell:0.2.0

# Expose required ports
EXPOSE 9090

# Expose required volumes
VOLUME /etc/my-app

# Add application binary and use it as default entrypoint
COPY my-app /bin/my-app
ENTRYPOINT ["/bin/my-app"]
