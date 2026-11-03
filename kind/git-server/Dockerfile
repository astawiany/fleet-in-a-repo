# Read-only smart-HTTP git server for offline Flux sync (see scripts/mgmt-up.sh).
# Serves bare repos mounted at /srv/git as http://<host>/cgi-bin/git/<repo>.git
FROM alpine:3.22
RUN apk add --no-cache git git-daemon busybox-extras \
    && git config --system safe.directory '*'
COPY git.cgi /www/cgi-bin/git
CMD ["busybox-extras", "httpd", "-f", "-p", "80", "-h", "/www"]
