#!/bin/sh
# CGI wrapper: busybox httpd passes the repo path in PATH_INFO.
export GIT_PROJECT_ROOT=/srv/git
export GIT_HTTP_EXPORT_ALL=1
exec /usr/libexec/git-core/git-http-backend
