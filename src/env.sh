#!/usr/bin/env bash
# Pre-validate the environment
if [ -z "${POSTGRES_DB}" ] && [ -z "${POSTGRES_DB_FILE}" ]; then
  echo "You need to set the POSTGRES_DB or POSTGRES_DB_FILE environment variable."
  exit 1
fi

if [ -z "${POSTGRES_HOST}" ]; then
  if [ -n "${POSTGRES_PORT_5432_TCP_ADDR}" ]; then
    POSTGRES_HOST=${POSTGRES_PORT_5432_TCP_ADDR}
    POSTGRES_PORT=${POSTGRES_PORT_5432_TCP_PORT}
  else
    echo "You need to set the POSTGRES_HOST environment variable."
    exit 1
  fi
fi

if [ -z "${POSTGRES_USER}" ] && [ -z "${POSTGRES_USER_FILE}" ]; then
  echo "You need to set the POSTGRES_USER or POSTGRES_USER_FILE environment variable."
  exit 1
fi

if [ -z "${POSTGRES_PASSWORD}" ] && [ -z "${POSTGRES_PASSWORD_FILE}" ] && [ -z "${POSTGRES_PASSFILE_STORE}" ]; then
  echo "You need to set the POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE or POSTGRES_PASSFILE_STORE environment variable or link to a container named POSTGRES."
  exit 1
fi

# Optional SSH tunnel validation
if [ -n "${SSH_HOST}" ]; then
  if [ -z "${SSH_USER}" ]; then
    echo "SSH_HOST is set but SSH_USER is missing."
    exit 1
  fi
  if [ '!' -s "${SSH_KEY_FILE}" ] && [ -z "${SSH_PASSWORD}" ] && [ -z "${SSH_PASSWORD_FILE}" ]; then
    echo "SSH_HOST is set but no SSH authentication provided (mount a key at SSH_KEY_FILE or set SSH_PASSWORD or SSH_PASSWORD_FILE)."
    exit 1
  fi
fi

#Process vars
if [ -z "${POSTGRES_DB_FILE}" ]; then
  POSTGRES_DBS=$(echo "${POSTGRES_DB}" | tr , " ")
elif [ -r "${POSTGRES_DB_FILE}" ]; then
  POSTGRES_DBS=$(cat "${POSTGRES_DB_FILE}")
else
  echo "Missing POSTGRES_DB_FILE file."
  exit 1
fi
if [ -z "${POSTGRES_USER_FILE}" ]; then
  export PGUSER="${POSTGRES_USER}"
elif [ -r "${POSTGRES_USER_FILE}" ]; then
  export PGUSER=$(cat "${POSTGRES_USER_FILE}")
else
  echo "Missing POSTGRES_USER_FILE file."
  exit 1
fi
if [ -z "${POSTGRES_PASSWORD_FILE}" ] && [ -z "${POSTGRES_PASSFILE_STORE}" ]; then
  export PGPASSWORD="${POSTGRES_PASSWORD}"
elif [ -r "${POSTGRES_PASSWORD_FILE}" ]; then
  export PGPASSWORD=$(cat "${POSTGRES_PASSWORD_FILE}")
elif [ -r "${POSTGRES_PASSFILE_STORE}" ]; then
  export PGPASSFILE="${POSTGRES_PASSFILE_STORE}"
else
  echo "Missing POSTGRES_PASSWORD_FILE or POSTGRES_PASSFILE_STORE file."
  exit 1
fi
if [ -n "${SSH_HOST}" ]; then
  # pg_dump connects to the local end of the SSH tunnel (opened in backup.sh).
  REMOTE_PG_HOST="${POSTGRES_HOST}"
  REMOTE_PG_PORT="${POSTGRES_PORT}"
  SSH_LOCAL_PORT=63333
  export PGHOST="127.0.0.1"
  export PGPORT="${SSH_LOCAL_PORT}"
  # Resolve SSH authentication (private key takes precedence over password)
  if [ -s "${SSH_KEY_FILE}" ]; then
    SSH_AUTH="key"
  elif [ -n "${SSH_PASSWORD_FILE}" ]; then
    if [ -r "${SSH_PASSWORD_FILE}" ]; then
      SSH_PASSWORD_RESOLVED=$(cat "${SSH_PASSWORD_FILE}")
    else
      echo "Missing SSH_PASSWORD_FILE file."
      exit 1
    fi
    SSH_AUTH="password"
  else
    SSH_PASSWORD_RESOLVED="${SSH_PASSWORD}"
    SSH_AUTH="password"
  fi
else
  export PGHOST="${POSTGRES_HOST}"
  export PGPORT="${POSTGRES_PORT}"
fi

KEEP_MINS=${BACKUP_KEEP_MINS}
KEEP_DAYS=${BACKUP_KEEP_DAYS}
KEEP_WEEKS=$(( BACKUP_KEEP_WEEKS * 7 + 1 ))
KEEP_MONTHS=$(( BACKUP_KEEP_MONTHS * 31 + 1 ))

# Validate backup dir
if [ '!' -d "${BACKUP_DIR}" -o '!' -w "${BACKUP_DIR}" -o '!' -x "${BACKUP_DIR}" ]; then
  echo "BACKUP_DIR points to a file or folder with insufficient permissions."
  exit 1
fi
