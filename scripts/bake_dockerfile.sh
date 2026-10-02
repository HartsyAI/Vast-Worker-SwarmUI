#!/usr/bin/env bash
# Prints a Dockerfile that adds the models in a bake list to a published worker image, one layer per model so they
# download in parallel. Each file is checked against its sha256 at build time.
#   scripts/bake_dockerfile.sh bake/krea2-turbo.txt kalebbroo/swarmui-worker-vast:1.0.0-hartsyinference > Dockerfile.bake
#   docker build -f Dockerfile.bake -t you/swarmui-worker-vast:1.0.0-hartsyinference-krea2-turbo .
set -euo pipefail
list="$1"
from="$2"
echo "FROM $from"
echo "USER swarm"
count=0
while read -r dest sha url; do
    case "$dest" in ''|'#'*) continue ;; esac
    if [ -z "$url" ] || ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || [[ "$dest" == /* || "$dest" == *..* ]]; then
        echo "Bad line in $list: $dest $sha $url" >&2
        exit 1
    fi
    path="/opt/swarmui/Models/$dest"
    echo "RUN mkdir -p \"$(dirname "$path")\" \\"
    echo " && curl -fL --retry 5 --retry-delay 10 -o \"$path\" \"$url\" \\"
    echo " && echo \"$sha  $path\" | sha256sum -c -"
    count=$((count + 1))
done < "$list"
if [ "$count" = 0 ]; then
    echo "$list lists no models" >&2
    exit 1
fi
# The worker's entrypoint starts as root (see Dockerfile).
echo "USER root"
