![Docker pulls](https://img.shields.io/docker/pulls/longday/simple-pg-backup)

# simple-pg-backup

Docker image that backs up PostgreSQL to the local filesystem with scheduled, rotating backups.

Inspired by [prodrigestivill/docker-postgres-backup-local](https://github.com/prodrigestivill/docker-postgres-backup-local). It focuses on a single Alpine image based on the PostgreSQL 18 client and a straightforward build-and-release flow.

## Table of Contents

* [Features](#features)
* [Usage](#usage)
  * [Environment Variables](#environment-variables)
  * [Remote host over SSH](#remote-host-over-ssh)
  * [Metrics](#metrics)
  * [How the backups folder works?](#how-the-backups-folder-works)
  * [Changing the compression method](#changing-the-compression-method)
  * [Manual Backups](#manual-backups)
  * [Automatic Periodic Backups](#automatic-periodic-backups)
* [Restore examples](#restore-examples)
  * [Restore using the same container](#restore-using-the-same-container)
  * [Restore using a new container](#restore-using-a-new-container)
  * [Restore a .sql.zst into a running PostgreSQL container](#restore-a-sqlzst-into-a-running-postgresql-container)
* [Build and release](#build-and-release)
* [Changelog](#changelog)

## Features

* **Single image, any server** — the image ships only the PostgreSQL 18 client, so one build dumps any reachable server from version 9.2 onwards.
* **Scheduled backups** — cron-style `SCHEDULE` plus an optional backup on container start.
* **Rotating retention** — automatic `last` / `daily` / `weekly` / `monthly` folders with independent keep settings, deduplicated via hard links.
* **Multiple databases** — list them in `POSTGRES_DB` (comma/space separated), or include `*` in the list to back up every non-template database; `POSTGRES_DB_EXCLUDE` skips databases.
* **Remote host over SSH** — optional SSH tunnel (`SSH_*`) to reach a Postgres server only available over SSH, with key or password auth.
* **Docker secrets** — `*_FILE` variants for user, password and database list.
* **Healthcheck** — HTTP endpoint exposing the schedule status.
* **Metrics** — optional Prometheus textfile-collector metrics (`METRICS_FILE`): last run result, last success time, duration and size per database.
* **Compression** — gzip by default (`-Z1`, `.sql.gz`) or zstd (`-Z zstd:3`, `.sql.zst`); `BACKUP_LEGACY_SUFFIXES` rotates the dumps of the previous method while switching.

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
         #  - for zstd dumps use POSTGRES_EXTRA_OPTS=-Z zstd:3 --schema=public --large-objects together with BACKUP_SUFFIX=.sql.zst
            - BACKUP_SUFFIX=.sql.gz
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
| BACKUP_SUFFIX | Filename suffix of the dump files. It must match the compression method in `POSTGRES_EXTRA_OPTS`: `.sql.gz` for gzip (`-Z1`, the default) or `.sql.zst` for zstd (`-Z zstd:3`). `pg_dump` neither adds nor checks it, and neither does the image. Defaults to `.sql.gz`. |
| BACKUP_LEGACY_SUFFIXES | Comma or space separated suffixes of earlier dumps (e.g. `.sql.gz` after switching to `.sql.zst`) that rotation removes by the retention rules together with `BACKUP_SUFFIX`. Only files named like the dumps the image generates for the database are matched, files with any other suffix are never removed. An entry must not contain `*`, `?`, `[`, `]`, `\` or `/`; otherwise the configuration is rejected. An entry equal to `BACKUP_SUFFIX` is ignored. Defaults to empty. See [Changing the compression method](#changing-the-compression-method). |
| BACKUP_ON_START | If set to `TRUE` performs an backup on each container start or restart. Defaults to `FALSE`. |
| BACKUP_KEEP_DAYS | Number of daily backups to keep before removal. Defaults to `7`. |
| BACKUP_KEEP_WEEKS | Number of weekly backups to keep before removal. Defaults to `4`. |
| BACKUP_KEEP_MONTHS | Number of monthly backups to keep before removal. Defaults to `6`. |
| BACKUP_KEEP_MINS | Number of minutes for `last` folder backups to keep before removal. Defaults to `1440`. |
| VALIDATE_ON_START | If set to `FALSE` does not validate the configuration on start. Disabling this is not recommended. Defaults to `TRUE`. |
| HEALTHCHECK_PORT | Port listening for cron-schedule health check. Defaults to `8080`. |
| METRICS_FILE | Path of the Prometheus metrics file (textfile collector format). Empty disables metrics, which is the default. See [Metrics](#metrics). |
| METRICS_SERVICE | Value of the `service` metrics label. Required when `METRICS_FILE` is set. |
| POSTGRES_DB | Comma or space separated list of postgres databases to backup. Include `*` in the list to back up every non-template database (queried from `pg_database`); the listing query connects through the first database listed before `*`, or `postgres` if none is given (e.g. `*` or `maindb,*`). Required. |
| POSTGRES_DB_FILE | Alternative to POSTGRES_DB, but with one database per line, for usage with docker secrets (remember to remove EOF newlines). |
| POSTGRES_DB_EXCLUDE | Comma or space separated list of databases to skip, applied after `*` is expanded (e.g. `POSTGRES_DB=*` with `POSTGRES_DB_EXCLUDE=logs`). Rotation only removes old files of databases still backed up, so delete an excluded database's existing files manually. Defaults to empty. |
| POSTGRES_EXTRA_OPTS | Additional [options](https://www.postgresql.org/docs/current/app-pgdump.html#PG-DUMP-OPTIONS) for `pg_dump`. Defaults to `-Z1 --large-objects` (gzip). For zstd use `-Z zstd:3` (e.g. `-Z zstd:3 --large-objects`) together with `BACKUP_SUFFIX=.sql.zst`. |
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

### Metrics

The image can publish the result of every run in the [node-exporter textfile collector](https://github.com/prometheus/node_exporter#textfile-collector) format, so a missed or broken backup can raise an alert. Metrics are off unless `METRICS_FILE` is set.

| variable | description |
|--|--|
| `METRICS_FILE` | Path of the metrics file inside the container, e.g. `/metrics/pg_backup_pg-backup.prom`. It must end with `.prom` and its directory must exist and be writable (mount the directory node-exporter reads via `--collector.textfile.directory`). Empty disables metrics. |
| `METRICS_SERVICE` | Value of the `service` label. Required when `METRICS_FILE` is set. Containers sharing one metrics directory need different `METRICS_FILE` names and `METRICS_SERVICE` values. |

All metrics are gauges:

| metric | labels | meaning |
|--|--|--|
| `pg_backup_last_run_timestamp_seconds` | `service` | Unix time the last run finished (successfully or not). |
| `pg_backup_last_run_success` | `service` | `1` if the last run succeeded, `0` if it failed. |
| `pg_backup_last_success_timestamp_seconds` | `service`, `db` | Unix time the `pg_dump` of the database last finished successfully. |
| `pg_backup_duration_seconds` | `service`, `db` | `pg_dump` duration of the last successful backup of the database. |
| `pg_backup_size_bytes` | `service`, `db` | Size of the last successful backup: file size, or `du -sb` of the directory for the directory format (`-Fd`). |

Behaviour:

* The file is rewritten after every database and once more when the run ends. While a run is in progress `last_run_*` keep the values of the previous run.
* After a **successful** run the file contains series only for the databases dumped in that run, so deleted or excluded databases (`POSTGRES_DB_EXCLUDE`) disappear.
* After a **failed** run (any error: `pg_dump` failure, unreachable PostgreSQL, invalid configuration) `pg_backup_last_run_success` is `0` and `pg_backup_last_run_timestamp_seconds` is the current time. Databases dumped before the failure get fresh series; for all other databases the series of the previous file are kept unchanged. The run stops at the first failing database, as before.
* A run killed by a signal leaves the previous file untouched.
* The file is replaced atomically: the data is written to a hidden `.<name>.tmp.XXXXXX` file in the same directory (not ending in `.prom`, so node-exporter ignores it), `chmod 0644` is applied and the file is renamed. The mode matters because node-exporter runs as `nobody` and cannot read the `0600` file that `mktemp` creates.
* A failure to write metrics prints a warning to stderr and never changes the result of the backup.

Example: start a throwaway PostgreSQL with databases `a` and `b`, back them up and read the result through node-exporter (run it from an empty directory):

```sh
mkdir -p backups metrics
docker network create pgdemo
docker run -d --name pgdemo-db --network pgdemo \
  -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password -e POSTGRES_DB=a postgres:18-alpine
until docker exec pgdemo-db pg_isready -h 127.0.0.1 -U user -d a -q; do sleep 1; done
docker exec pgdemo-db createdb -U user b

docker run --rm --network pgdemo \
  -v "$PWD/backups:/backups" -v "$PWD/metrics:/metrics" \
  -e POSTGRES_HOST=pgdemo-db -e POSTGRES_DB=a,b -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password \
  -e METRICS_FILE=/metrics/pg_backup_pg-backup.prom -e METRICS_SERVICE=pg-backup \
  longday/simple-pg-backup:1.1.0 /backup.sh

grep -v '^#' metrics/pg_backup_pg-backup.prom

docker run -d --name pgdemo-ne --user 65534 -p 9100:9100 -v "$PWD/metrics:/textfile:ro" \
  quay.io/prometheus/node-exporter:v1.11.1 --collector.textfile.directory=/textfile
sleep 2
curl -s localhost:9100/metrics | grep -E '^(pg_backup_|node_textfile_scrape_error)'

docker rm -f pgdemo-ne pgdemo-db
docker network rm pgdemo
```

The backup command creates `metrics/pg_backup_pg-backup.prom` with the five metrics above (`pg_backup_last_run_success{service="pg-backup"} 1` and per-database series for `a` and `b`); the `curl` command shows the same series through node-exporter with `node_textfile_scrape_error 0`.

### How the backups folder works?

First a new backup is created in the `last` folder with the full time.

Once this backup finishes successfully, it is hard linked (instead of copying to avoid using more space) to the rest of the folders (daily, weekly and monthly). This step replaces the old backups for that category storing always only the latest for each category (so the monthly backup for a month is always storing the latest for that month and not the first).

So the backup folder are structured as follows:

* `BACKUP_DIR/last/DB-YYYYMMDD-HHmmss.sql.gz`: all the backups are stored separately in this folder.
* `BACKUP_DIR/daily/DB-YYYYMMDD.sql.gz`: always store (hard link) the **latest** backup of that day.
* `BACKUP_DIR/weekly/DB-YYYYww.sql.gz`: always store (hard link) the **latest** backup of that week (the last day of the week will be Sunday as it uses ISO week numbers).
* `BACKUP_DIR/monthly/DB-YYYYMM.sql.gz`: always store (hard link) the **latest** backup of that month (normally the ~31st).

The suffix is `BACKUP_SUFFIX`: `.sql.gz` for gzip dumps (the default) or `.sql.zst` for zstd dumps (`-Z zstd:3`).

For **cleaning** the script removes the files for each category only if the new backup has been successful.
To do so it is using the following independent variables:

* BACKUP_KEEP_MINS: will remove files from the `last` folder that are older than its value in minutes after a new successful backup without affecting the rest of the backups (because they are hard links).
* BACKUP_KEEP_DAYS: will remove files from the `daily` folder that are older than its value in days after a new successful backup.
* BACKUP_KEEP_WEEKS: will remove files from the `weekly` folder that are older than its value in weeks after a new successful backup (remember that it starts counting from the end of each week not the beginning).
* BACKUP_KEEP_MONTHS: will remove files from the `monthly` folder that are older than its value in months (of 31 days) after a new successful backup (remember that it starts counting from the end of each month not the beginning).

### Changing the compression method

`POSTGRES_EXTRA_OPTS` (`-Z`) sets how `pg_dump` compresses a dump and `BACKUP_SUFFIX` names the file. Rotation removes only files with `BACKUP_SUFFIX` or one of `BACKUP_LEGACY_SUFFIXES`, so after a change of suffix the old files match nothing and stay on disk forever unless the old suffix is listed in `BACKUP_LEGACY_SUFFIXES`. To change `.sql.gz` (gzip, the default) to `.sql.zst` (zstd) without losing restore points:

1. Switch the method and the suffix together and leave `BACKUP_LEGACY_SUFFIXES` empty: `POSTGRES_EXTRA_OPTS=-Z zstd:3 --large-objects` and `BACKUP_SUFFIX=.sql.zst`. New dumps are `.sql.zst`; the old `.sql.gz` files are not rotated and not removed, so both sets are on disk and the new set grows until its retention is full. Make sure the filesystem has room for it, then run `/backup.sh` once.
2. Check the new dump: test it and restore it into an empty database (see [Restore examples](#restore-examples)).
3. Set `BACKUP_LEGACY_SUFFIXES=.sql.gz`. The next runs remove `.sql.gz` files by the same rules as `.sql.zst`: older than `BACKUP_KEEP_MINS` in `last`, `BACKUP_KEEP_DAYS` days in `daily`, `BACKUP_KEEP_WEEKS` × 7 + 1 days in `weekly`, `BACKUP_KEEP_MONTHS` × 31 + 1 days in `monthly`. The last `.sql.gz` is gone after the longest of them (187 days with the defaults). Do not do this before step 2: with a single copy (`BACKUP_KEEP_*` set to `0`) the first run removes the old dump as soon as it is past retention, and if the new one is unusable nothing is left.
4. When no file with the old suffix is left (`find $BACKUP_DIR -name '*.sql.gz'` prints nothing), remove `BACKUP_LEGACY_SUFFIXES`.

To go back to gzip, swap the values: `-Z1`, `BACKUP_SUFFIX=.sql.gz`, `BACKUP_LEGACY_SUFFIXES=.sql.zst`. Files with a suffix that is neither `BACKUP_SUFFIX` nor listed in `BACKUP_LEGACY_SUFFIXES` are never removed, and a legacy suffix matches only the names the image generates for the database being rotated (`DB-YYYYMMDD-HHmmss` in `last`, `DB-YYYYMMDD` in `daily`, `DB-YYYYww` in `weekly`, `DB-YYYYMM` in `monthly`), so a dump of another database such as `DB-staging-…` is not touched. The image does not check that `-Z` and `BACKUP_SUFFIX` agree. The size of a dump (`pg_backup_size_bytes`) drops after the switch because zstd compresses better than gzip level 1.

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

Some examples to restore/apply the backups. A dump is a plain-SQL file compressed as a whole with the method its suffix says: `.sql.gz` is read with `zcat`, `.sql.zst` with `zstd -dc`. Both tools are in this image and in the official `postgres` images (Debian and Alpine).

Before restoring:

* Restore into an **empty** database. Dumps are made without `--clean`, so objects that already exist cause errors.
* The dump starts with `\restrict` and ends with `\unrestrict`, so the `psql` that applies it must support them: PostgreSQL 18.x and the patch releases 17.6, 16.10, 15.14, 13.22 and newer. An older client fails. This image ships the PostgreSQL 18 client; with the official `postgres` image pick a `$VERSION` that meets this.
* The commands use `-v ON_ERROR_STOP=1`, so `psql` stops at the first error and exits non-zero. `-q` alone does not hide the result rows of `lo_create`, `lowrite` and `set_config`, so the commands add `-o /dev/null`; errors still go to stderr.
* The exit code of a pipe is the one of its last command (`psql`), so a failing `zstd`/`zcat` is not reported. `set -o pipefail` in your script covers only the pipes that run in your shell (the `zstd -dc … | docker exec …` commands below). The pipes inside `/bin/sh -c "…"` and `sh -c "…"` run in the container's shell, where the setting of your script has no effect, and `/bin/sh` of some images has no `pipefail`. A truncated or corrupted file may not make `psql` fail either, so test the file first (see below) and compare the restored row counts with the source.

Test a file and check that the dump is complete (`PostgreSQL database dump complete` is among the last 5 lines, the check prints `1`):

```sh
zstd -t $BACKUPFILE && zstd -dc $BACKUPFILE | tail -n 5 | grep -c 'PostgreSQL database dump complete'
gzip -t $BACKUPFILE && gzip -dc $BACKUPFILE | tail -n 5 | grep -c 'PostgreSQL database dump complete'
```

The first line is for `.sql.zst`, the second for `.sql.gz`.

### Restore using the same container

To restore using the same backup container, replace `$BACKUPFILE` (path inside the container, e.g. `/backups/last/dbname-20260101-030000.sql.zst`), `$CONTAINER`, `$HOSTNAME`, `$PORT`, `$USERNAME` and `$DBNAME` in one of the following commands.

`.sql.gz`:

```sh
docker exec --tty --interactive $CONTAINER /bin/sh -c "zcat $BACKUPFILE | psql --host=$HOSTNAME --port=$PORT --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null -W"
```

`.sql.zst`:

```sh
docker exec --tty --interactive $CONTAINER /bin/sh -c "zstd -dc $BACKUPFILE | psql --host=$HOSTNAME --port=$PORT --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null -W"
```

### Restore using a new container

Replace `$BACKUPFILE` (absolute path on the host), `$VERSION`, `$HOSTNAME`, `$PORT`, `$USERNAME` and `$DBNAME` in one of the following commands. `$HOSTNAME` must be reachable from the new container; for a server on a docker network add `--network $NETWORK`.

`.sql.gz`:

```sh
docker run --rm --tty --interactive -v $BACKUPFILE:/tmp/backupfile.sql.gz postgres:$VERSION /bin/sh -c "zcat /tmp/backupfile.sql.gz | psql --host=$HOSTNAME --port=$PORT --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null -W"
```

`.sql.zst`:

```sh
docker run --rm --tty --interactive -v $BACKUPFILE:/tmp/backupfile.sql.zst postgres:$VERSION /bin/sh -c "zstd -dc /tmp/backupfile.sql.zst | psql --host=$HOSTNAME --port=$PORT --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null -W"
```

### Restore a .sql.zst into a running PostgreSQL container

Replace `$BACKUPDIR` (host directory with the dump), `$BACKUPNAME` (file name in it), `$PGCONTAINER` (container with PostgreSQL), `$USERNAME` and `$DBNAME`. The database must exist and be empty (`docker exec $PGCONTAINER psql --username=$USERNAME -c "create database $DBNAME"`).

With `zstd` on the host:

```sh
zstd -dc $BACKUPDIR/$BACKUPNAME | docker exec -i $PGCONTAINER psql --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null
```

Without `zstd` on the host, decompress with the image:

```sh
docker run --rm -v $BACKUPDIR:/b:ro longday/simple-pg-backup:1.2.0 zstd -dc /b/$BACKUPNAME | docker exec -i $PGCONTAINER psql --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null
```

With only the image, restoring into a PostgreSQL server reachable over a docker network (`$NETWORK`; export `PGPASSWORD` in your shell first, so the password does not appear in the command):

```sh
docker run --rm --interactive --network $NETWORK -v $BACKUPDIR:/b:ro -e PGPASSWORD longday/simple-pg-backup:1.2.0 sh -c "zstd -dc /b/$BACKUPNAME | psql --host=$HOSTNAME --port=$PORT --username=$USERNAME --dbname=$DBNAME -v ON_ERROR_STOP=1 -q -o /dev/null"
```

## Build and release

The released version is stored in the `VERSION` file using [semver](https://semver.org/) (`MAJOR.MINOR.PATCH`). To cut a release: bump `VERSION`, add the matching entry to the Changelog below, commit, then run:

```sh
./build.sh
```

`build.sh` reads `VERSION`, builds a multi-arch image, pushes `latest` and the version tag to Docker Hub, and creates the matching `v<version>` git tag.

The image name, platforms and base versions are constants defined at the top of `build.sh`. The script aborts if `VERSION` is not valid semver, if the working tree is dirty, if the git tag already exists, or if there is no `### <version>` entry in the Changelog below.

## Changelog

### 1.2.0 - 2026-11-25

* Added `BACKUP_LEGACY_SUFFIXES`: comma or space separated suffixes of earlier dumps that rotation removes by the retention rules together with `BACKUP_SUFFIX`. It lets a deployment change the compression method (e.g. `.sql.gz` to `.sql.zst`) without leaving unrotated dumps behind. See [Changing the compression method](#changing-the-compression-method). Empty by default; without it rotation, files and metrics are the same as 1.1.0.
* Defaults are unchanged (`POSTGRES_EXTRA_OPTS=-Z1 --large-objects`, `BACKUP_SUFFIX=.sql.gz`). zstd dumps (`-Z zstd:3` with `BACKUP_SUFFIX=.sql.zst`) are documented and verified with the bundled `pg_dump`.
* Restore examples cover `.sql.gz` and `.sql.zst`, the `psql` version required by `\restrict`/`\unrestrict`, and a restore with `zstd` from the image.

### 1.1.0 - 2026-11-20

* Added Prometheus metrics for the [node-exporter textfile collector](https://github.com/prometheus/node_exporter#textfile-collector): set `METRICS_FILE` and `METRICS_SERVICE` to get last run result, last success time, duration and size per database. See [Metrics](#metrics). Disabled by default; without `METRICS_FILE` behaviour and output are the same as 1.0.2.
* `METRICS_SERVICE` is required when `METRICS_FILE` is set.

### 1.0.2 - 2026-11-17

* Added `POSTGRES_DB_EXCLUDE` to skip databases, including those matched by `*`.

### 1.0.1 - 2026-06-16

* Added `SSH_COMPRESSION` (default `TRUE`) to compress the SSH tunnel, and `ServerAliveCountMax` for deterministic tunnel timeouts.
* Improved backup log output: progress counters (`[n/total]`), database names, and per-database dump size.
* Boolean environment flags (`TRUE`/`FALSE`) are now case-insensitive.
* Replaced the `**None**` sentinel with empty-string defaults and `-z`/`-n` checks.
* Removed the `postgres` user run guidance from the documentation.

### 1.0.0 - 2026-06-11

* Initial release, inspired by `prodrigestivill/docker-postgres-backup-local`.
* Single Alpine image based on PostgreSQL 18 (dumps any server from 9.2+).
* Added `POSTGRES_DB=*` to back up every non-template database the user can connect to.
* Added optional SSH tunnel support (`SSH_*`) for Postgres servers reachable only over SSH.
* Replaced CI with `build.sh` for building, publishing and git-tagging releases.
