#!/usr/bin/env bash
set -Eeo pipefail

# Prometheus metrics (textfile collector format), enabled only when METRICS_FILE is set.
# State lives in "name -> 'timestamp duration size'" records keyed by the escaped db label.
METRICS_DONE=""
PREV_RUN_TS=""
PREV_RUN_OK=""
declare -A PREV_REC=()
declare -A CUR_REC=()

metrics_enabled(){
  [ -n "${METRICS_FILE}" ] && [ -n "${METRICS_SERVICE}" ]
}

# Escape a label value for the Prometheus text format; result in METRICS_ESCAPED.
metrics_escape(){
  local v="${1//\\/\\\\}"
  v="${v//\"/\\\"}"
  METRICS_ESCAPED="${v//$'\n'/\\n}"
}

# Read the previous file: last run lines and complete per-database records.
metrics_load_previous(){
  local line key
  local -A ts=() dur=() size=()
  local re_db='^pg_backup_(last_success_timestamp_seconds|duration_seconds|size_bytes)\{service="([^"\\]|\\.)*",db="(([^"\\]|\\.)*)"\} ([^ ]+)$'
  local re_run='^pg_backup_last_run_(timestamp_seconds|success)\{.*\} ([^ ]+)$'
  [ -r "${METRICS_FILE}" ] || return 0
  while IFS= read -r line; do
    if [[ "${line}" =~ ${re_db} ]]; then
      case "${BASH_REMATCH[1]}" in
        last_success_timestamp_seconds) ts["${BASH_REMATCH[3]}"]="${BASH_REMATCH[5]}" ;;
        duration_seconds) dur["${BASH_REMATCH[3]}"]="${BASH_REMATCH[5]}" ;;
        size_bytes) size["${BASH_REMATCH[3]}"]="${BASH_REMATCH[5]}" ;;
      esac
    elif [[ "${line}" =~ ${re_run} ]]; then
      case "${BASH_REMATCH[1]}" in
        timestamp_seconds) PREV_RUN_TS="${BASH_REMATCH[2]}" ;;
        success) PREV_RUN_OK="${BASH_REMATCH[2]}" ;;
      esac
    fi
  done < "${METRICS_FILE}"
  for key in "${!ts[@]}"; do
    if [ -n "${dur["${key}"]-}" ] && [ -n "${size["${key}"]-}" ]; then
      PREV_REC["${key}"]="${ts["${key}"]} ${dur["${key}"]} ${size["${key}"]}"
    fi
  done
}

# Atomically (re)write METRICS_FILE.
#   $1: run result, 0 or 1; "prev" keeps the previous run lines (run still in progress)
#   $2: "merged" = previous databases overlaid with this run's; "current" = this run's only
metrics_write(){
  local run_ok="$1" scope="$2" run_ts dir base tmp key family
  local -A rec=()
  local -a keys=()
  local -a families=(
    "last_success_timestamp_seconds|Unix time of the last successful backup of the database."
    "duration_seconds|Duration of the last successful backup of the database."
    "size_bytes|Size of the last successful backup of the database."
  )
  if [ "${scope}" = "merged" ]; then
    for key in "${!PREV_REC[@]}"; do rec["${key}"]="${PREV_REC["${key}"]}"; done
  fi
  for key in "${!CUR_REC[@]}"; do rec["${key}"]="${CUR_REC["${key}"]}"; done
  if [ "${#rec[@]}" -gt 0 ]; then
    mapfile -t keys < <(printf '%s\n' "${!rec[@]}" | sort)
  fi
  if [ "${run_ok}" = "prev" ]; then
    run_ts="${PREV_RUN_TS}"
    run_ok="${PREV_RUN_OK}"
  else
    run_ts="${EPOCHSECONDS}"
  fi

  metrics_escape "${METRICS_SERVICE}"
  local svc="${METRICS_ESCAPED}"
  dir="$(dirname "${METRICS_FILE}")"
  base="$(basename "${METRICS_FILE}")"
  # Temp name must not end in ".prom" or node-exporter would read a half-written file
  tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")" || return 1
  {
    if [ -n "${run_ts}" ]; then
      printf '# HELP pg_backup_last_run_timestamp_seconds Unix time of the last finished backup run.\n'
      printf '# TYPE pg_backup_last_run_timestamp_seconds gauge\n'
      printf 'pg_backup_last_run_timestamp_seconds{service="%s"} %s\n' "${svc}" "${run_ts}"
    fi
    if [ -n "${run_ok}" ]; then
      printf '# HELP pg_backup_last_run_success Whether the last finished backup run succeeded (1) or failed (0).\n'
      printf '# TYPE pg_backup_last_run_success gauge\n'
      printf 'pg_backup_last_run_success{service="%s"} %s\n' "${svc}" "${run_ok}"
    fi
    local idx=1 name help t d s
    for family in "${families[@]}"; do
      [ "${#keys[@]}" -gt 0 ] || break
      name="pg_backup_${family%%|*}"
      help="${family#*|}"
      printf '# HELP %s %s\n# TYPE %s gauge\n' "${name}" "${help}" "${name}"
      for key in "${keys[@]}"; do
        read -r t d s <<< "${rec["${key}"]}"
        case "${idx}" in
          1) printf '%s{service="%s",db="%s"} %s\n' "${name}" "${svc}" "${key}" "${t}" ;;
          2) printf '%s{service="%s",db="%s"} %s\n' "${name}" "${svc}" "${key}" "${d}" ;;
          3) printf '%s{service="%s",db="%s"} %s\n' "${name}" "${svc}" "${key}" "${s}" ;;
        esac
      done
      idx=$((idx + 1))
    done
  } > "${tmp}" || { rm -f "${tmp}"; return 1; }
  # mktemp creates 0600; node-exporter runs as nobody and must be able to read the file
  if ! { chmod 0644 "${tmp}" && mv -f "${tmp}" "${METRICS_FILE}"; }; then
    rm -f "${tmp}"
    return 1
  fi
}

# A metrics failure must never fail or alter the backup itself.
metrics_write_safe(){
  if ! metrics_write "$1" "$2"; then
    echo "Warning: failed to write metrics file ${METRICS_FILE}" >&2
  fi
}

# Record a finished database: $1 db, $2 dump path, $3/$4 start/end in microseconds.
metrics_record(){
  local size dur_us
  if [ -d "$2" ]; then
    size="$(du -sb "$2" | cut -f1)"
  else
    size="$(stat -c %s "$2")"
  fi
  dur_us=$(( $4 - $3 ))
  metrics_escape "$1"
  CUR_REC["${METRICS_ESCAPED}"]="$(( $4 / 1000000 )) $(printf '%d.%03d' $(( dur_us / 1000000 )) $(( dur_us % 1000000 / 1000 ))) ${size}"
  metrics_write_safe prev merged
}

metrics_on_error(){
  if metrics_enabled && [ -z "${METRICS_DONE}" ]; then
    METRICS_DONE=1
    metrics_write_safe 0 merged
  fi
}

# Remove expired dumps of one database from a directory, for every suffix in ROTATE_SUFFIXES.
#   $1: directory, $2/$3: find age test (e.g. -mtime +7), $4: database
# BACKUP_SUFFIX (the first entry) matches "<db>-*<suffix>" as it always did. Legacy suffixes
# match only the names this script generates (<db>-YYYYMMDD-HHMMSS, -YYYYMMDD, -GGGGVV, -YYYYMM),
# so a dump of another database whose name starts with "<db>-" is never removed.
rotate_dir(){
  local s i d6 d8
  local -a names=(-name "$4-*${ROTATE_SUFFIXES[0]}")
  d6="[0-9][0-9][0-9][0-9][0-9][0-9]"
  d8="[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]"
  for (( i = 1; i < ${#ROTATE_SUFFIXES[@]}; i++ )); do
    s="${ROTATE_SUFFIXES[i]}"
    names+=(-o -name "$4-${d8}-${d6}${s}" -o -name "$4-${d8}${s}" -o -name "$4-${d6}${s}")
  done
  find "$1" -maxdepth 1 "$2" "$3" \( "${names[@]}" \) -exec rm -rf '{}' ';'
}

# Open SSH tunnel if configured (pg_dump then connects to 127.0.0.1:SSH_LOCAL_PORT)
SSH_TUNNEL_PID=""
cleanup(){
  local rc=$?
  if [ -n "${SSH_TUNNEL_PID}" ]; then
    kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
  fi
  # Failures that bypass the ERR trap (explicit "exit 1", signals) still count as a failed run
  if [ "${rc}" -ne 0 ]; then
    metrics_on_error
  fi
}
trap cleanup EXIT
trap metrics_on_error ERR

if metrics_enabled; then
  metrics_load_previous
fi

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

if [ -n "${SSH_HOST}" ]; then
  echo "Opening SSH tunnel ${SSH_USER}@${SSH_HOST}:${SSH_PORT} -> ${REMOTE_PG_HOST}:${REMOTE_PG_PORT}..."
  SSH_OPTS="-o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p ${SSH_PORT}"
  if [ "${SSH_COMPRESSION^^}" = "TRUE" ]; then
    SSH_OPTS="${SSH_OPTS} -C"
  fi
  if [ "${SSH_STRICT_HOST_KEY_CHECKING^^}" = "FALSE" ]; then
    SSH_OPTS="${SSH_OPTS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  elif [ -n "${SSH_KNOWN_HOSTS_FILE}" ]; then
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

# Drop the databases listed in POSTGRES_DB_EXCLUDE (comma or space separated).
if [ -n "${POSTGRES_DB_EXCLUDE}" ]; then
  EXCLUDE=" $(echo "${POSTGRES_DB_EXCLUDE}" | tr , " ") "
  KEPT=""
  for db in ${POSTGRES_DBS}; do
    case "${EXCLUDE}" in
      *" ${db} "*) ;;
      *) KEPT="${KEPT} ${db}" ;;
    esac
  done
  POSTGRES_DBS="${KEPT# }"
  if [ -z "${POSTGRES_DBS}" ]; then
    echo "No databases left to back up after applying POSTGRES_DB_EXCLUDE."
    exit 1
  fi
fi

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
  DB_START_US="${EPOCHREALTIME/[.,]/}"
  pg_dump -d "${DB}" -f "${FILE}" ${POSTGRES_EXTRA_OPTS}
  DB_END_US="${EPOCHREALTIME/[.,]/}"
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
  rotate_dir "${BACKUP_DIR}/last" -mmin "+${KEEP_MINS}" "${DB}"
  rotate_dir "${BACKUP_DIR}/daily" -mtime "+${KEEP_DAYS}" "${DB}"
  rotate_dir "${BACKUP_DIR}/weekly" -mtime "+${KEEP_WEEKS}" "${DB}"
  rotate_dir "${BACKUP_DIR}/monthly" -mtime "+${KEEP_MONTHS}" "${DB}"
  if metrics_enabled; then
    metrics_record "${DB}" "${FILE}" "${DB_START_US}" "${DB_END_US}"
  fi
  echo "[${COUNT}/${TOTAL}] ${DB} done ($(du -sh "${FILE}" | cut -f1))."
done

echo "SQL backup created successfully"

if metrics_enabled; then
  METRICS_DONE=1
  metrics_write_safe 1 current
fi
