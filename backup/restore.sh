#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f .env ]]; then
  echo "FATAL: .env not found in $REPO_ROOT" >&2
  exit 1
fi

set -a
source .env
set +a

: "${BACKUP_REPOSITORY:?set BACKUP_REPOSITORY in .env}"
: "${BACKUP_PASSWORD:?set BACKUP_PASSWORD in .env}"

TARGET="$REPO_ROOT/backup/restored"

restic() {
  local args=()
  if [[ "$BACKUP_REPOSITORY" == /* ]]; then
    args+=(-e RESTIC_REPOSITORY=/repo -v "$BACKUP_REPOSITORY:/repo")
  else
    args+=(-e RESTIC_REPOSITORY="$BACKUP_REPOSITORY")
    local var
    for var in B2_ACCOUNT_ID B2_ACCOUNT_KEY \
               AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION \
               RESTIC_REST_USERNAME RESTIC_REST_PASSWORD; do
      [[ -n "${!var:-}" ]] && args+=(-e "$var=${!var}")
    done
  fi
  docker run --rm -it \
    --security-opt label=disable \
    -e RESTIC_PASSWORD="$BACKUP_PASSWORD" \
    -v "$TARGET:/restore" \
    "${args[@]}" \
    "docker.io/restic/restic:${RESTIC_TAG:-latest}" "$@"
}

case "${1:-}" in
  list)
    restic snapshots --tag homelab
    ;;

  files)
    [[ -n "${2:-}" ]] || { echo "usage: $0 files <snapshot-id>" >&2; exit 2; }
    restic ls -l "$2"
    ;;

  fetch)
    [[ -n "${2:-}" ]] || { echo "usage: $0 fetch <snapshot-id>" >&2; exit 2; }
    mkdir -p "$TARGET"
    restic restore "$2" --target /restore
    echo
    echo "Restored into: $TARGET"
    cat <<'EOF'

This helper stops here on purpose - the steps below are destructive, so run
them by hand and check each one.

  1. Stop the stack, keeping the volumes:
       hl down

  2. Restore .env and configuration (the secrets must match the dumps —
     without AUTHENTIK_SECRET_KEY the authentik dump is useless):
       cp backup/restored/staging/env.txt .env
       tar -xf backup/restored/staging/config.tar

  3. Start only the databases:
       hl up -d authentik-db nextcloud-db

  4. Load the dumps:
       docker compose exec -T authentik-db \
         psql -U authentik authentik < backup/restored/staging/authentik.sql
       docker compose exec -T nextcloud-db \
         mariadb -u root -p"$NEXTCLOUD_DB_ROOT_PASSWORD" nextcloud \
         < backup/restored/staging/nextcloud.sql

  5. Restore the file volumes (repeat per volume under backup/restored/data/):
       docker run --rm --security-opt label=disable \
         -v homelab_nextcloud-data:/dst \
         -v "$PWD/backup/restored/data/nextcloud-data:/src:ro" \
         docker.io/library/alpine sh -c 'rm -rf /dst/* /dst/..?* ; cp -a /src/. /dst/'

  6. Bring everything up and clear maintenance mode:
       hl up -d
       docker compose exec -u www-data nextcloud php occ maintenance:mode --off

EOF
    ;;

  *)
    echo "usage: $0 {list|files <id>|fetch <id>}" >&2
    exit 2
    ;;
esac
