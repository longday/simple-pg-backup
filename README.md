![Docker pulls](https://img.shields.io/docker/pulls/longday/simple-pg-backup)

# simple-pg-backup

Docker image that backs up PostgreSQL to the local filesystem with scheduled, rotating backups.

Inspired by [prodrigestivill/docker-postgres-backup-local](https://github.com/prodrigestivill/docker-postgres-backup-local). It focuses on a single Alpine image based on the PostgreSQL 18 client and a straightforward build-and-release flow.

## Features

* **Single image, any server** — the image ships only the PostgreSQL 18 client, so one build dumps any reachable server from version 9.2 onwards.
* **Scheduled backups** — cron-style `SCHEDULE` plus an optional backup on container start.
* **Rotating retention** — automatic `last` / `daily` / `weekly` / `monthly` folders with independent keep settings, deduplicated via hard links.
* **Multiple databases** — list them in `POSTGRES_DB` (comma/space separated), or include `*` in the list to back up every non-template database.
* **Remote host over SSH** — optional SSH tunnel (`SSH_*`) to reach a Postgres server only available over SSH, with key or password auth.
* **Docker secrets** — `*_FILE` variants for user, password and database list.
* **Healthcheck** — HTTP endpoint exposing the schedule status.

The destination docker volume `/backups` must be a POSIX-compliant filesystem (hard links and symlinks are required), so VFAT, EXFAT, SMB/CIFS and similar cannot be used.

Please also read [How the backups folder works?](#how-the-backups-folder-works).

## Usage

Docker:

```sh
docker run -e POSTGRES_HOST=postgres -e POSTGRES_DB=dbname -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password  longday/simple-pg-backup
```

Docker Compose:

```yaml
services:
    postgres:
        image: postgres
        restart: always
        environment:
            - POSTGRES_DB=database
            - POSTGRES_USER=username
            - POSTGRES_PASSWORD=password
         #  - POSTGRES_PASSWORD_FILE=/run/secrets/db_password <-- alternative for POSTGRES_PASSWORD (to use with docker secrets, remember to remove EOF newlines)
    pgbackups:
        image: longday/simple-pg-backup
        restart: always
        volumes:
            - /var/opt/pgbackups:/backups
        links:
            - postgres
        depends_on:
            - postgres
        environment:
            - POSTGRES_HOST=postgres
            - POSTGRES_DB=database
            - POSTGRES_USER=username
            - POSTGRES_PASSWORD=password
         #  - POSTGRES_PASSWORD_FILE=/run/secrets/db_password <-- alternative for POSTGRES_PASSWORD (to use with docker secrets, remember to remove EOF newlines)
            - POSTGRES_EXTRA_OPTS=-Z1 --schema=public --large-objects
            - SCHEDULE=@daily
            - BACKUP_ON_START=TRUE
            - BACKUP_KEEP_DAYS=7
            - BACKUP_KEEP_WEEKS=4
            - BACKUP_KEEP_MONTHS=6
            - HEALTHCHECK_PORT=8080
```

### Environment Variables

Most variables are the same as in the [official postgres image](https://hub.docker.com/_/postgres/).

| env variable | description |
|--|--|
| BACKUP_DIR | Directory to save the backup at. Defaults to `/backups`. |
| BACKUP_SUFFIX | Filename suffix to save the backup. Defaults to `.sql.gz`. |
| BACKUP_ON_START | If set to `TRUE` performs an backup on each container start or restart. Defaults to `FALSE`. |
| BACKUP_KEEP_DAYS | Number of daily backups to keep before removal. Defaults to `7`. |
| BACKUP_KEEP_WEEKS | Number of weekly backups to keep before removal. Defaults to `4`. |
| BACKUP_KEEP_MONTHS | Number of monthly backups to keep before removal. Defaults to `6`. |
| BACKUP_KEEP_MINS | Number of minutes for `last` folder backups to keep before removal. Defaults to `1440`. |
| VALIDATE_ON_START | If set to `FALSE` does not validate the configuration on start. Disabling this is not recommended. Defaults to `TRUE`. |
| HEALTHCHECK_PORT | Port listening for cron-schedule health check. Defaults to `8080`. |
| POSTGRES_DB | Comma or space separated list of postgres databases to backup. Include `*` in the list to back up every non-template database (queried from `pg_database`); the listing query connects through the first database listed before `*`, or `postgres` if none is given (e.g. `*` or `maindb,*`). Required. |
| POSTGRES_DB_FILE | Alternative to POSTGRES_DB, but with one database per line, for usage with docker secrets (remember to remove EOF newlines). |
| POSTGRES_EXTRA_OPTS | Additional [options](https://www.postgresql.org/docs/current/app-pgdump.html#PG-DUMP-OPTIONS) for `pg_dump`. Defaults to `-Z1 --large-objects`. |
| POSTGRES_HOST | Postgres connection parameter; postgres host to connect to. Required. |
| POSTGRES_PASSWORD | Postgres connection parameter; postgres password to connect with. Required. |
| POSTGRES_PASSWORD_FILE | Alternative to POSTGRES_PASSWORD, for usage with docker secrets (remember to remove EOF newlines). |
| POSTGRES_PASSFILE_STORE | Alternative to POSTGRES_PASSWORD in [passfile format](https://www.postgresql.org/docs/current/libpq-pgpass.html#LIBPQ-PGPASS). |
| POSTGRES_PORT | Postgres connection parameter; postgres port to connect to. Defaults to `5432`. |
| POSTGRES_USER | Postgres connection parameter; postgres user to connect with. Required. |
| POSTGRES_USER_FILE | Alternative to POSTGRES_USER, for usage with docker secrets (remember to remove EOF newlines). |
| SSH_HOST | When set, open an SSH tunnel and back up Postgres through it (see [Remote host over SSH](#remote-host-over-ssh)). Default disabled. |
| SSH_PORT | SSH port. Defaults to `22`. |
| SSH_USER | SSH user. Required when SSH_HOST is set. |
| SSH_KEY_FILE | Path to the SSH private key inside the container (mount it / use docker secrets). Takes precedence over password authentication. Defaults to `/run/secrets/ssh_key`; key auth is used only when this file exists and is non-empty. |
| SSH_PASSWORD | SSH password, used when SSH_KEY_FILE is not set. |
| SSH_PASSWORD_FILE | Alternative to SSH_PASSWORD, for usage with docker secrets (remember to remove EOF newlines). |
| SSH_KNOWN_HOSTS_FILE | Path to a `known_hosts` file used to verify the SSH host key (mount it). |
| SSH_STRICT_HOST_KEY_CHECKING | Set to `TRUE` to enable SSH host key verification. Defaults to `FALSE` (insecure, vulnerable to MITM). |
| SCHEDULE | [Cron-schedule](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules) specifying the interval between postgres backups. Defaults to `@daily`. |
| TZ | [POSIX TZ variable](https://www.gnu.org/software/libc/manual/html_node/TZ-Variable.html) specifying the timezone used to evaluate SCHEDULE cron (example "Europe/Paris"). |

#### Special Environment Variables

These variables are not intended to be used for normal deployment operations:

| env variable | description |
|--|--|
| POSTGRES_PORT_5432_TCP_ADDR | Sets the POSTGRES_HOST when the latter is not set. |
| POSTGRES_PORT_5432_TCP_PORT | Sets POSTGRES_PORT when POSTGRES_HOST is not set. |

### Remote host over SSH

If the PostgreSQL server is only reachable through SSH, set `SSH_HOST` to open an SSH tunnel before each backup. The backup connects to Postgres through that tunnel, so `POSTGRES_HOST`/`POSTGRES_PORT` must point to the database **as seen from the SSH host** (often `localhost:5432`).

Authentication uses a private key (`SSH_KEY_FILE`) when provided, otherwise a password (`SSH_PASSWORD` / `SSH_PASSWORD_FILE`). Host keys are verified against `SSH_KNOWN_HOSTS_FILE`; set `SSH_STRICT_HOST_KEY_CHECKING=FALSE` to skip verification (insecure).

```yaml
    pgbackups:
        image: longday/simple-pg-backup
        restart: always
        volumes:
            - /var/opt/pgbackups:/backups
            - ./id_ed25519:/run/secrets/ssh_key:ro
            - ./known_hosts:/run/secrets/known_hosts:ro
        environment:
            - POSTGRES_HOST=localhost   # Postgres as seen from the SSH host
            - POSTGRES_DB=database
            - POSTGRES_USER=username
            - POSTGRES_PASSWORD=password
            - SSH_HOST=db.example.com
            - SSH_USER=backup
            - SSH_KEY_FILE=/run/secrets/ssh_key
            - SSH_KNOWN_HOSTS_FILE=/run/secrets/known_hosts
```

### How the backups folder works?

First a new backup is created in the `last` folder with the full time.

Once this backup finishes successfully, it is hard linked (instead of copying to avoid using more space) to the rest of the folders (daily, weekly and monthly). This step replaces the old backups for that category storing always only the latest for each category (so the monthly backup for a month is always storing the latest for that month and not the first).

So the backup folder are structured as follows:

* `BACKUP_DIR/last/DB-YYYYMMDD-HHmmss.sql.gz`: all the backups are stored separately in this folder.
* `BACKUP_DIR/daily/DB-YYYYMMDD.sql.gz`: always store (hard link) the **latest** backup of that day.
* `BACKUP_DIR/weekly/DB-YYYYww.sql.gz`: always store (hard link) the **latest** backup of that week (the last day of the week will be Sunday as it uses ISO week numbers).
* `BACKUP_DIR/monthly/DB-YYYYMM.sql.gz`: always store (hard link) the **latest** backup of that month (normally the ~31st).

For **cleaning** the script removes the files for each category only if the new backup has been successful.
To do so it is using the following independent variables:

* BACKUP_KEEP_MINS: will remove files from the `last` folder that are older than its value in minutes after a new successful backup without affecting the rest of the backups (because they are hard links).
* BACKUP_KEEP_DAYS: will remove files from the `daily` folder that are older than its value in days after a new successful backup.
* BACKUP_KEEP_WEEKS: will remove files from the `weekly` folder that are older than its value in weeks after a new successful backup (remember that it starts counting from the end of each week not the beginning).
* BACKUP_KEEP_MONTHS: will remove files from the `monthly` folder that are older than its value in months (of 31 days) after a new successful backup (remember that it starts counting from the end of each month not the beginning).

### Manual Backups

By default this container makes daily backups, but you can start a manual backup by running `/backup.sh`.

This script as example creates one backup as the running user and saves it the working folder.

```sh
docker run --rm -v "$PWD:/backups" -u "$(id -u):$(id -g)" -e POSTGRES_HOST=postgres -e POSTGRES_DB=dbname -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password  longday/simple-pg-backup /backup.sh
```

### Automatic Periodic Backups

You can change the `SCHEDULE` environment variable in `-e SCHEDULE="@daily"` to alter the default frequency. Default is `daily`.

More information about the scheduling can be found [here](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules).

Folders `daily`, `weekly` and `monthly` are created and populated using hard links to save disk space.

## Restore examples

Some examples to restore/apply the backups.

### Restore using the same container

To restore using the same backup container, replace `$BACKUPFILE`, `$CONTAINER`, `$USERNAME` and `$DBNAME` from the following command:

```sh
docker exec --tty --interactive $CONTAINER /bin/sh -c "zcat $BACKUPFILE | psql --username=$USERNAME --dbname=$DBNAME -W"
```

### Restore using a new container

Replace `$BACKUPFILE`, `$VERSION`, `$HOSTNAME`, `$PORT`, `$USERNAME` and `$DBNAME` from the following command:

```sh
docker run --rm --tty --interactive -v $BACKUPFILE:/tmp/backupfile.sql.gz postgres:$VERSION /bin/sh -c "zcat /tmp/backupfile.sql.gz | psql --host=$HOSTNAME --port=$PORT --username=$USERNAME --dbname=$DBNAME -W"
```

## Build and release

The released version is stored in the `VERSION` file using [semver](https://semver.org/) (`MAJOR.MINOR.PATCH`). To cut a release: bump `VERSION`, add the matching entry to the Changelog below, commit, then run:

```sh
./build.sh
```

`build.sh` reads `VERSION`, builds a multi-arch image, pushes `latest` and the version tag to Docker Hub, and creates the matching `v<version>` git tag.

The image name, platforms and base versions are constants defined at the top of `build.sh`. The script aborts if `VERSION` is not valid semver, if the working tree is dirty, if the git tag already exists, or if there is no `### <version>` entry in the Changelog below.

## Changelog

### 1.0.0 - 2026-06-11

* Initial release, inspired by `prodrigestivill/docker-postgres-backup-local`.
* Single Alpine image based on PostgreSQL 18 (dumps any server from 9.2+).
* Added `POSTGRES_DB=*` to back up every non-template database the user can connect to.
* Added optional SSH tunnel support (`SSH_*`) for Postgres servers reachable only over SSH.
* Replaced CI with `build.sh` for building, publishing and git-tagging releases.
