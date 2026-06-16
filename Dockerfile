ARG BASETAG
FROM postgres:$BASETAG

ARG GOCRONVER
ARG TARGETOS
ARG TARGETARCH
RUN set -x \
	&& : "${GOCRONVER:?GOCRONVER build arg is required}" \
	&& apk update && apk add ca-certificates curl openssh-client sshpass \
	&& curl --fail --retry 4 --retry-all-errors -L https://github.com/prodrigestivill/go-cron/releases/download/$GOCRONVER/go-cron-$TARGETOS-$TARGETARCH-static.gz | zcat > /usr/local/bin/go-cron \
	&& chmod a+x /usr/local/bin/go-cron

ENV POSTGRES_DB="**None**" \
    POSTGRES_DB_FILE="**None**" \
    POSTGRES_HOST="**None**" \
    POSTGRES_PORT=5432 \
    POSTGRES_USER="**None**" \
    POSTGRES_USER_FILE="**None**" \
    POSTGRES_PASSWORD="**None**" \
    POSTGRES_PASSWORD_FILE="**None**" \
    POSTGRES_PASSFILE_STORE="**None**" \
    POSTGRES_EXTRA_OPTS="-Z1 --large-objects" \
    SSH_HOST="**None**" \
    SSH_PORT=22 \
    SSH_USER="**None**" \
    SSH_KEY_FILE="/run/secrets/ssh_key" \
    SSH_PASSWORD="**None**" \
    SSH_PASSWORD_FILE="**None**" \
    SSH_KNOWN_HOSTS_FILE="**None**" \
    SSH_STRICT_HOST_KEY_CHECKING="FALSE" \
    SSH_COMPRESSION="TRUE" \
    SCHEDULE="@daily" \
    VALIDATE_ON_START="TRUE" \
    BACKUP_ON_START="FALSE" \
    BACKUP_DIR="/backups" \
    BACKUP_SUFFIX=".sql.gz" \
    BACKUP_KEEP_DAYS=7 \
    BACKUP_KEEP_WEEKS=4 \
    BACKUP_KEEP_MONTHS=6 \
    BACKUP_KEEP_MINS=1440 \
    HEALTHCHECK_PORT=8080

COPY src/backup.sh src/env.sh src/init.sh /

VOLUME /backups

ENTRYPOINT []
CMD ["/init.sh"]

HEALTHCHECK --interval=5m --timeout=3s \
  CMD curl -f "http://localhost:$HEALTHCHECK_PORT/" || exit 1
