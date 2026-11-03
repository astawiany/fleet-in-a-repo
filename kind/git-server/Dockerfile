# Read-only smart-HTTP git server for offline Flux sync (see scripts/mgmt-up.sh).
# Serves bare repos mounted at /srv/git as http://<host>/cgi-bin/git/<repo>.git
FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
# apk packages are pinned to a minor version with "~" (git 2.49.x, busybox 1.37.x), not to an
# exact -rN revision: Alpine keeps only the latest revision of a branch's packages, so an exact
# pin (verified at build time: git/git-daemon 2.49.1-r0, busybox-extras 1.37.0-r20) would break
# on the next security rebuild.
RUN apk add --no-cache git~2.49 git-daemon~2.49 busybox-extras~1.37 \
    && git config --system safe.directory '*'
COPY git.cgi /www/cgi-bin/git
CMD ["busybox-extras", "httpd", "-f", "-p", "80", "-h", "/www"]
