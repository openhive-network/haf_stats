#!/bin/sh
# Entrypoint for the haf_stats PostgREST URL rewriter (openresty).
# Substitutes runtime placeholders into the nginx config template, then starts openresty.
#
#   REWRITE_LOG     - set to "on" to enable nginx rewrite logging (default: off)
#   POSTGREST_HOST  - hostname of the PostgREST service to proxy to (default: haf-stats-api)
#   POSTGREST_PORT  - port of the PostgREST service (default: 3000)
#   RESOLVER        - DNS server nginx re-resolves POSTGREST_HOST through at request
#                     time (default: 127.0.0.11, Docker's embedded DNS)
#   REWRITER_HOSTS_FILE, REWRITER_OPENRESTY_PREFIX
#                   - the hosts file and openresty prefix (default: /etc/hosts and
#                     /usr/local/openresty); overridden only by the unit tests
#
# nginx's resolver never reads /etc/hosts, so a POSTGREST_HOST listed there (localhost, a
# compose extra_hosts entry, a hosts-file name outside Docker) is replaced here by its
# hosts-file address, fixed for the container's life. Every other name -- a Docker
# service name -- stays a name and is re-resolved through RESOLVER per request.

if [ "$REWRITE_LOG" = "on" ]; then
    REWRITE_LOG="rewrite_log on;"
else
    REWRITE_LOG="# rewrite_log off;"
fi

POSTGREST_HOST="${POSTGREST_HOST:-haf-stats-api}"
POSTGREST_PORT="${POSTGREST_PORT:-3000}"
RESOLVER="${RESOLVER:-127.0.0.11}"
HOSTS_FILE="${REWRITER_HOSTS_FILE:-/etc/hosts}"
OPENRESTY_PREFIX="${REWRITER_OPENRESTY_PREFIX:-/usr/local/openresty}"

# Not getent: it falls through to DNS, so it cannot tell a hosts-file name from a service
# name, and pinning a service name would undo the per-request re-resolution.
# An IPv4 entry is preferred; an IPv6 one is bracketed for the URL.
hosts_address=$(awk -v name="$POSTGREST_HOST" '
    { sub(/#.*/, "") }
    NF >= 2 {
        for (i = 2; i <= NF; i++) {
            if (tolower($i) == tolower(name)) {
                if ($1 ~ /:/) { if (v6 == "") v6 = "[" $1 "]" }
                else if (v4 == "") v4 = $1
            }
        }
    }
    END { print (v4 != "" ? v4 : v6) }
' "$HOSTS_FILE" 2>/dev/null)

if [ -n "$hosts_address" ]; then
    echo "rewriter: POSTGREST_HOST $POSTGREST_HOST is in $HOSTS_FILE, which nginx's resolver does not read; proxying to $hosts_address for this container's life" >&2
    POSTGREST_HOST="$hosts_address"
fi

sed -e "s|\${REWRITE_LOG}|$REWRITE_LOG|g" \
    -e "s|\${POSTGREST_HOST}|$POSTGREST_HOST|g" \
    -e "s|\${POSTGREST_PORT}|$POSTGREST_PORT|g" \
    -e "s|\${RESOLVER}|$RESOLVER|g" \
    "$OPENRESTY_PREFIX/nginx/conf/nginx.conf.template" \
    > "$OPENRESTY_PREFIX/nginx/conf/nginx.conf"

exec "$OPENRESTY_PREFIX/bin/openresty" -g 'daemon off;'
