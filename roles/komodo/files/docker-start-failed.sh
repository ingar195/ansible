#!/bin/bash
# Docker's restart policy never retries a container that failed to *start*
# (e.g. its NFS volume couldn't mount), so retry those here. A container
# stopped on purpose has no State.Error, so it's left alone.
set -uo pipefail

ids=$(docker ps -aq --filter status=exited --filter status=created)
[ -n "$ids" ] || exit 0

docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}} {{.State.Error}}' $ids |
while read -r name policy err; do
    [ -n "$err" ] || continue
    case "$policy" in always|unless-stopped) ;; *) continue ;; esac
    logger -t docker-start-failed "retrying ${name#/}: $err"
    docker start "${name#/}" >/dev/null 2>&1 || true
done
