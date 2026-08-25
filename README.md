# github-backup-docker

Dockerized version of [python-github-backup](https://github.com/josegonzalez/python-github-backup) with extra automation. This container makes a backup daily and keeps up to defined number of backups.

This fork is maintained by [wus-technik](https://github.com/wus-technik) and keeps upstream provenance with [umputun/github-backup-docker](https://github.com/umputun/github-backup-docker).

## Install and run

1. Generate github [access token](https://github.com/settings/tokens). Give it a `repo` scope with full access to repositories.
2. Get provided `docker-compose.yml`. If needed change the mapping for `volumes` and `MAX_BACKUPS` number
3. Change TZ (see the [list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones))
4. Set `TOKEN` (in environment or directly in `docker-compose.yml`)
5. Set `GITHUB_USER` (Github user accounts) and/or `GITHUB_ORG` (Github Organizations; make sure the user token has access to the organization). If you have multiple users/organizations, you can list thme separating names by a comma.
6. Run `docker-compose up -d` to initiate daily backup 

## Monitoring and notifications

Each backup run writes an entity-specific log file under `/srv/var/logs/`.

Set `NOTIFY_WEBHOOK_URL` to a Teams/Power Automate webhook URL to get notifications when:

- `github-backup` exits with a non-zero code
- the run exits successfully but logs soft-failure markers such as unavailable repositories, inaccessible repositories, git return code `128`, or disabled pull requests

Clean runs stay silent. Do not commit webhook URLs or GitHub tokens; provide them through the live stack environment.

## Customize Backup Options

The underlying [python-github-backup](https://github.com/josegonzalez/python-github-backup) library [has a lot of options](https://github.com/josegonzalez/python-github-backup#usage) to customize what is backed up from github. 

We can customize this by using the `BACKUP_OPTIONS` environment variable. By default, the container will backup everything and uses `--private --all --gist`. That will backup the repositories, issues, pull requests, labels, etc.

If you wanted to customize this to only backup the repository code (including private repositories), you could define the following on your `docker-compose.yml` file's environment:

```
BACKUP_OPTIONS=--private --repositories
```

`NOTIFY_WEBHOOK_URL` can also be set in the environment to send Teams/Power Automate cards for failed or warning runs.

## Compression

Set `COMPRESSION` to any non-empty value to pack each finished snapshot into
`/srv/var/<TIMESTAMP>/<TIMESTAMP>_<user_or_org>.tar.gz` and remove the uncompressed directory.
If the `tar` run fails, the directory is kept and the failure is logged.

## Prepared images

- [github packages](https://github.com/orgs/wus-technik/packages/container/package/github-backup-docker)

## Upstream

This project is based on [umputun/github-backup-docker](https://github.com/umputun/github-backup-docker). Keep upstream references when carrying forward fixes or attribution.

## Build from the source

1. Clone this repo
2. run `docker-compose build`
