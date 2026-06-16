#!/usr/bin/env bash
set -Eeo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

# Open SSH tunnel if configured (pg_dump then connects to 127.0.0.1:SSH_LOCAL_PORT)
SSH_TUNNEL_PID=""
cleanup(){
  if [ -n "${SSH_TUNNEL_PID}" ]; then
    kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "${SSH_HOST}" != "**None**" ]; then
  echo "Opening SSH tunnel ${SSH_USER}@${SSH_HOST}:${SSH_PORT} -> ${REMOTE_PG_HOST}:${REMOTE_PG_PORT}..."
  SSH_OPTS="-o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -p ${SSH_PORT}"
  if [ "${SSH_STRICT_HOST_KEY_CHECKING}" = "FALSE" ]; then
    SSH_OPTS="${SSH_OPTS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  elif [ "${SSH_KNOWN_HOSTS_FILE}" != "**None**" ]; then
    SSH_OPTS="${SSH_OPTS} -o UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}"
  fi
  SSH_FWD="127.0.0.1:${SSH_LOCAL_PORT}:${REMOTE_PG_HOST}:${REMOTE_PG_PORT}"
  if [ "${SSH_AUTH}" = "key" ]; then
    ssh -i "${SSH_KEY_FILE}" -o BatchMode=yes ${SSH_OPTS} -NL "${SSH_FWD}" "${SSH_USER}@${SSH_HOST}" &
    SSH_TUNNEL_PID=$!
  else
    SSHPASS="${SSH_PASSWORD_RESOLVED}" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ${SSH_OPTS} -NL "${SSH_FWD}" "${SSH_USER}@${SSH_HOST}" &
    SSH_TUNNEL_PID=$!
  fi
  # Wait until the forwarded port accepts connections
  for _ in $(seq 1 30); do
    if pg_isready -h 127.0.0.1 -p "${SSH_LOCAL_PORT}" >/dev/null 2>&1; then break; fi
    kill -0 "${SSH_TUNNEL_PID}" 2>/dev/null || { echo "SSH tunnel process exited unexpectedly."; exit 1; }
    sleep 1
  done
  pg_isready -h 127.0.0.1 -p "${SSH_LOCAL_PORT}" >/dev/null 2>&1 || { echo "SSH tunnel did not become ready."; exit 1; }
fi

# Expand a "*" entry in the database list to every non-template database.
# psql connects through the first explicitly listed database, or "postgres".
case " ${POSTGRES_DBS} " in
  *" * "*)
    set -f
    CONNECT_DB="postgres"
    for db in ${POSTGRES_DBS}; do
      if [ "${db}" != "*" ]; then CONNECT_DB="${db}"; break; fi
    done
    POSTGRES_DBS=$(psql -d "${CONNECT_DB}" -tAc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
    set +f
    if [ -z "${POSTGRES_DBS}" ]; then
      echo "POSTGRES_DB contained '*' but no databases were found."
      exit 1
    fi
    ;;
esac

#Initialize dirs
mkdir -p "${BACKUP_DIR}/last/" "${BACKUP_DIR}/daily/" "${BACKUP_DIR}/weekly/" "${BACKUP_DIR}/monthly/"

#Loop all databases
set -- ${POSTGRES_DBS}
TOTAL=$#
echo "Found ${TOTAL} database(s) to back up from ${POSTGRES_HOST}: $*"
COUNT=0
for DB in ${POSTGRES_DBS}; do
  COUNT=$((COUNT + 1))
  #Initialize backup paths
  FILE="${BACKUP_DIR}/last/${DB}-$(date +%Y%m%d-%H%M%S)${BACKUP_SUFFIX}"
  DFILE="${BACKUP_DIR}/daily/${DB}-$(date +%Y%m%d)${BACKUP_SUFFIX}"
  WFILE="${BACKUP_DIR}/weekly/${DB}-$(date +%G%V)${BACKUP_SUFFIX}"
  MFILE="${BACKUP_DIR}/monthly/${DB}-$(date +%Y%m)${BACKUP_SUFFIX}"
  #Create dump
  echo "[${COUNT}/${TOTAL}] Dumping ${DB}..."
  pg_dump -d "${DB}" -f "${FILE}" ${POSTGRES_EXTRA_OPTS}
  #Copy (hardlink) for each entry
  if [ -d "${FILE}" ]; then
    DFILENEW="${DFILE}-new"
    WFILENEW="${WFILE}-new"
    MFILENEW="${MFILE}-new"
    rm -rf "${DFILENEW}" "${WFILENEW}" "${MFILENEW}"
    mkdir "${DFILENEW}" "${WFILENEW}" "${MFILENEW}"
    (
      # Allow hardlinking more files than the max arg list length
      # First CHDIR to avoid possible space problems with BACKUP_DIR
      cd "${FILE}"
      for F in *; do
        ln -f "$F" "${DFILENEW}/"
        ln -f "$F" "${WFILENEW}/"
        ln -f "$F" "${MFILENEW}/"
      done
    )
    rm -rf "${DFILE}" "${WFILE}" "${MFILE}"
    mv "${DFILENEW}" "${DFILE}"
    mv "${WFILENEW}" "${WFILE}"
    mv "${MFILENEW}" "${MFILE}"
  else
    ln -f "${FILE}" "${DFILE}"
    ln -f "${FILE}" "${WFILE}"
    ln -f "${FILE}" "${MFILE}"
  fi
  #Clean old files
  find "${BACKUP_DIR}/last" -maxdepth 1 -mmin "+${KEEP_MINS}" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  find "${BACKUP_DIR}/daily" -maxdepth 1 -mtime "+${KEEP_DAYS}" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  find "${BACKUP_DIR}/weekly" -maxdepth 1 -mtime "+${KEEP_WEEKS}" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  find "${BACKUP_DIR}/monthly" -maxdepth 1 -mtime "+${KEEP_MONTHS}" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  echo "[${COUNT}/${TOTAL}] ${DB} done ($(du -sh "${FILE}" | cut -f1))."
done

echo "SQL backup created successfully"
