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

ENV POSTGRES_DB="" \
    POSTGRES_DB_FILE="" \
    POSTGRES_HOST="" \
    POSTGRES_PORT=5432 \
    POSTGRES_USER="" \
    POSTGRES_USER_FILE="" \
    POSTGRES_PASSWORD="" \
    POSTGRES_PASSWORD_FILE="" \
    POSTGRES_PASSFILE_STORE="" \
    POSTGRES_EXTRA_OPTS="-Z1 --large-objects" \
    SSH_HOST="" \
    SSH_PORT=22 \
    SSH_USER="" \
    SSH_KEY_FILE="/run/secrets/ssh_key" \
    SSH_PASSWORD="" \
    SSH_PASSWORD_FILE="" \
    SSH_KNOWN_HOSTS_FILE="" \
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
