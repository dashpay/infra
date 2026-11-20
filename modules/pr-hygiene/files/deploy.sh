#!/bin/bash
# Deploys one image of the PR Hygiene service, by digest, and goes back to
# the previous one if the new one does not start or does not become ready.
#
# Run by the SSM document "<name>-deploy" on behalf of the deploy job in the
# service's repository. What this prints ends up in that job's log, which is
# public: image references and outcomes only, never the service's own logs.
#
# Time budget, worst case: pull 120 s + start 60 s + readiness 90 s for the
# new image, then start 60 s + readiness 90 s for the old one: 420 s. The
# SSM document allows 600 s, so a rollback is never cut off.
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

# deploy/image names the last image that became ready, and nothing else. It
# is what a rollback returns to and what a replacement host starts.
state=/srv/pr-hygiene/deploy
env_file=/run/pr-hygiene-image.env
new="$PRH_ECR_REPOSITORY@$digest"
old=""
if [ -s "$state/image" ]; then
  old=$(cat "$state/image")
fi

start() {
  printf 'PR_HYGIENE_IMAGE=%s\n' "$1" > "$env_file" || return 1
  timeout 60 docker compose --env-file "$env_file" -f /etc/pr-hygiene/compose.yaml \
    up -d --remove-orphans --quiet-pull
}

# /readyz: the database answers and GitHub's signing keys are loaded.
ready() {
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8080/readyz; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Nothing has changed yet if the pull fails: the old image keeps running.
if ! timeout 120 docker pull --quiet "$new" > /dev/null; then
  echo "could not pull $new within 120 s; nothing was changed" >&2
  exit 1
fi

# Failing to start and failing to become ready end the same way.
if start "$new" && ready; then
  printf '%s\n' "$new" > "$state/image.tmp"
  mv "$state/image.tmp" "$state/image"
  echo "deployed $new"
  # Local copies unused for a week go. A rollback to one of them pulls it
  # again: the repository never expires a tagged image.
  docker image prune -af --filter until=168h > /dev/null || true
  exit 0
fi

echo "did not start or was not ready within 90 s: $new" >&2
echo "its logs are on the host: docker logs ${PRH_NAME}-service-1" >&2
if [ -n "$old" ]; then
  if start "$old" && ready; then
    echo "rolled back to $old" >&2
  else
    echo "rolled back to $old, which did not start or is not ready either" >&2
  fi
else
  echo "there was no earlier image to go back to" >&2
fi
exit 1
