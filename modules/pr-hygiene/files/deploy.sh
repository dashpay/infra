#!/bin/bash
# Deploys one image of the PR Hygiene service, by digest, and goes back to
# the previous one if the new one does not become ready.
#
# Run by the SSM document "<name>-deploy" on behalf of the deploy job in the
# service's repository. What this prints ends up in that job's log, which is
# public: image references and outcomes only, never the service's own logs.
set -euo pipefail

. /etc/pr-hygiene/host.env
export HOME=/root DOCKER_CONFIG=/root/.docker

digest="${1:-}"
if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "usage: pr-hygiene-deploy sha256:<64 hex digits>" >&2
  exit 2
fi

exec 9> /run/pr-hygiene-deploy.lock
if ! flock -n 9; then
  echo "another deploy is running" >&2
  exit 1
fi

state=/srv/pr-hygiene/deploy
new="$PRH_ECR_REPOSITORY@$digest"
old=""
if [ -s "$state/image" ]; then
  old=$(cat "$state/image")
fi

start() {
  printf 'PR_HYGIENE_IMAGE=%s\n' "$1" > "$state/image.env"
  docker compose --env-file "$state/image.env" -f /etc/pr-hygiene/compose.yaml \
    up -d --remove-orphans --quiet-pull
}

# /readyz: the database answers and GitHub's signing keys are loaded.
ready() {
  for _ in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:8080/readyz; then
      return 0
    fi
    sleep 2
  done
  return 1
}

docker pull --quiet "$new" > /dev/null
start "$new"
if ready; then
  printf '%s\n' "$new" > "$state/image"
  echo "deployed $new"
  docker image prune -af --filter until=168h > /dev/null || true
  exit 0
fi

echo "not ready after 90 s: $new" >&2
echo "its logs are on the host: docker logs ${PRH_NAME}-service-1" >&2
if [ -n "$old" ]; then
  start "$old"
  if ready; then
    echo "rolled back to $old" >&2
  else
    echo "rolled back to $old, which is not ready either" >&2
  fi
else
  echo "there was no earlier image to go back to" >&2
fi
exit 1
