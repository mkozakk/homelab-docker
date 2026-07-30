#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DO_CHECK=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --check)   DO_CHECK=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<'USAGE'
usage: backup/backup.sh [--check] [--dry-run]

  --check    also verify repository integrity (slow)
  --dry-run  show what would be backed up, write nothing
USAGE
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -f .env ]]; then
  echo "FATAL: .env not found in $REPO_ROOT" >&2
  exit 1
fi

set -a
source .env
set +a

: "${BACKUP_REPOSITORY:?set BACKUP_REPOSITORY in .env}"
: "${BACKUP_PASSWORD:?set BACKUP_PASSWORD in .env}"
: "${AUTHENTIK_DB_PASSWORD:?}"
: "${NEXTCLOUD_DB_ROOT_PASSWORD:?}"

RESTIC_TAG_IMAGE="${RESTIC_TAG:-latest}"
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-12}"
INCLUDE_PROMETHEUS="${BACKUP_INCLUDE_PROMETHEUS:-false}"
PROJECT="${COMPOSE_PROJECT_NAME:-homelab}"

COMPOSE=(docker compose -f docker-compose.yml)
[[ -f compose.podman.yml ]] && COMPOSE+=(-f compose.podman.yml)

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

exec 9>"${TMPDIR:-/tmp}/homelab-backup.lock"
flock -n 9 || die "another backup is already running"

VOLUMES=(
  nextcloud-data
  nextcloud-app
  authentik-media
  authentik-templates
  adguard-conf
  grafana-data
  openwebui-data
)
[[ "$INCLUDE_PROMETHEUS" == "true" ]] && VOLUMES+=(prometheus-data)

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/homelab-backup.XXXXXX")"
chmod 700 "$STAGING"

MAINTENANCE_ON=0
cleanup() {
  local rc=$?
  if [[ $MAINTENANCE_ON -eq 1 ]]; then
    log "disabling Nextcloud maintenance mode"
    "${COMPOSE[@]}" exec -T -u www-data nextcloud php occ maintenance:mode --off \
      || log "WARNING: could not disable maintenance mode - do it by hand!"
  fi
  rm -rf -- "$STAGING"
  [[ $rc -eq 0 ]] && log "backup finished successfully" || log "backup FAILED (exit $rc)"
  exit $rc
}
trap cleanup EXIT

LOCAL_REPO=0
[[ "$BACKUP_REPOSITORY" == /* ]] && LOCAL_REPO=1

restic() {
  local args=()
  if [[ $LOCAL_REPO -eq 1 ]]; then
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
  local v
  for v in "${VOLUMES[@]}"; do
    args+=(-v "${PROJECT}_${v}:/data/${v}:ro")
  done
  docker run --rm \
    --security-opt label=disable \
    -e RESTIC_PASSWORD="$BACKUP_PASSWORD" \
    -e RESTIC_CACHE_DIR=/cache \
    -v "${STAGING}:/staging:ro" \
    -v "${PROJECT}-restic-cache:/cache" \
    "${args[@]}" \
    "docker.io/restic/restic:${RESTIC_TAG_IMAGE}" "$@"
}

if [[ $LOCAL_REPO -eq 1 ]]; then
  [[ -d "$BACKUP_REPOSITORY" ]] || die "BACKUP_REPOSITORY ($BACKUP_REPOSITORY) does not exist - is the backup disk mounted?"

  if [[ "${BACKUP_ALLOW_SAME_DISK:-false}" != "true" ]]; then
    backup_dev="$(findmnt -no SOURCE --target "$BACKUP_REPOSITORY" | sed 's/\[.*//')"
    root_dev="$(findmnt -no SOURCE --target / | sed 's/\[.*//')"
    if [[ "$backup_dev" == "$root_dev" ]]; then
      die "$BACKUP_REPOSITORY sits on $backup_dev, the same device as / - that is a copy, not a backup. Mount the second disk there, or set BACKUP_ALLOW_SAME_DISK=true to override."
    fi
  fi
fi

for v in "${VOLUMES[@]}"; do
  docker volume inspect "${PROJECT}_${v}" >/dev/null 2>&1 \
    || die "volume ${PROJECT}_${v} not found - is the stack up?"
done

if ! restic cat config >/dev/null 2>&1; then
  log "initialising restic repository at $BACKUP_REPOSITORY"
  restic init
fi

log "enabling Nextcloud maintenance mode"
"${COMPOSE[@]}" exec -T -u www-data nextcloud php occ maintenance:mode --on
MAINTENANCE_ON=1

log "dumping authentik (postgres)"
"${COMPOSE[@]}" exec -T authentik-db \
  pg_dump -U authentik --clean --if-exists authentik > "$STAGING/authentik.sql"

log "dumping nextcloud (mariadb)"
"${COMPOSE[@]}" exec -T nextcloud-db \
  mariadb-dump -u root -p"$NEXTCLOUD_DB_ROOT_PASSWORD" \
    --single-transaction --quick nextcloud > "$STAGING/nextcloud.sql"

for f in "$STAGING"/*.sql; do
  [[ -s "$f" ]] || die "$(basename "$f") is empty - dump failed"
done

log "including .env and stack configuration"
cp .env "$STAGING/env.txt"
tar -cf "$STAGING/config.tar" \
  --exclude='nginx/certs/*.key' \
  nginx prometheus grafana tailscale docker-compose.yml compose.podman.yml 2>/dev/null || true
cp nginx/certs/homelab.key "$STAGING/" 2>/dev/null || true
cp nginx/certs/homelab.crt "$STAGING/" 2>/dev/null || true
chmod 600 "$STAGING"/*

BACKUP_ARGS=(
  backup /staging
  --tag homelab
  --host "${BACKUP_HOSTNAME:-homelab}"
  --exclude-caches
  --compression auto
)
for v in "${VOLUMES[@]}"; do BACKUP_ARGS+=("/data/${v}"); done
[[ $DRY_RUN -eq 1 ]] && BACKUP_ARGS+=(--dry-run --verbose)

log "running restic backup"
restic "${BACKUP_ARGS[@]}"

if [[ $DRY_RUN -eq 1 ]]; then
  log "dry run - skipping forget/prune"
  exit 0
fi

log "applying retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
restic forget \
  --tag homelab \
  --host "${BACKUP_HOSTNAME:-homelab}" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune

if [[ $DO_CHECK -eq 1 ]]; then
  log "verifying repository integrity"
  restic check --read-data-subset=5%
fi

restic snapshots --tag homelab --latest 3
