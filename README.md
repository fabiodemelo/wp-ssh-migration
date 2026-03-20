# WordPress SSH Migration Tool

A single bash script that fully migrates a WordPress site from one server to another over SSH. Run it on the source server and it handles everything — database, files, config, permissions.

## What It Migrates

- **All WordPress core files** (`wp-admin/`, `wp-includes/`, `index.php`, etc.)
- **All plugins** (`wp-content/plugins/`)
- **All themes** (`wp-content/themes/`)
- **All media uploads** — photos, PDFs, videos (`wp-content/uploads/`)
- **Must-use plugins** (`wp-content/mu-plugins/`)
- **Language files** (`wp-content/languages/`)
- **`.htaccess`** — rewrite rules and server config
- **`wp-config.php`** — transferred then updated with new DB credentials
- **Full database** — all posts, pages, comments, users, plugin/theme settings, widget configs, menus, media library metadata, custom tables

Nothing is left behind.

## Requirements

**Source server:**
- `mysql` and `mysqldump`
- `rsync`
- `ssh`
- `bash` 4+

**Destination server:**
- `mysql` (for database import)
- `wp` / [WP-CLI](https://wp-cli.org/) (optional, for URL search-replace and cache flush)

## Quick Start

```bash
# 1. SSH into your source server
ssh user@old-server

# 2. Navigate to your WordPress root
cd /var/www/html

# 3. Download the script
curl -O https://raw.githubusercontent.com/fabiodemelo/wp-ssh-migration/main/wpmigration.sh
chmod +x wpmigration.sh

# 4. Run it
bash wpmigration.sh
```

The script will walk you through each step interactively.

## Dry Run

Preview what the script would do without making any changes:

```bash
bash wpmigration.sh --dry-run
```

## Using a .env File

To avoid typing credentials every time (useful for repeated migrations or testing), create a `.env` file alongside the script:

```bash
cp .env.example .env
nano .env   # fill in your values
```

Any values set in `.env` will be used automatically. Empty values will still be prompted interactively. This means you can pre-fill some fields and leave others blank.

### .env Variables

| Variable | Description | Default |
|---|---|---|
| `NEW_SSH_HOST` | Destination server IP or hostname | *(prompted)* |
| `NEW_SSH_PORT` | SSH port | `22` |
| `NEW_SSH_USER` | SSH username | *(prompted)* |
| `AUTH_METHOD` | `key` or `password` | `key` |
| `SSH_PASS` | SSH password (if using password auth) | *(prompted)* |
| `SSH_KEY_PATH` | Path to SSH private key | `~/.ssh/id_rsa` |
| `NEW_WEB_PATH` | WordPress path on new server | *(prompted)* |
| `NEW_WEB_USER` | Web server user for file ownership | `www-data` |
| `NEW_WEB_GROUP` | Web server group for file ownership | `www-data` |
| `NEW_DB_HOST` | New database host | `localhost` |
| `NEW_DB_NAME` | New database name | *(prompted)* |
| `NEW_DB_USER` | New database username | *(prompted)* |
| `NEW_DB_PASS` | New database password | *(prompted)* |
| `NEW_TABLE_PREFIX` | New table prefix | *(same as source)* |
| `OLD_URL` | Old site URL for search-replace | *(prompted)* |
| `NEW_URL` | New site URL for search-replace | *(prompted)* |

> **Security:** The `.gitignore` is configured to prevent `.env` from being committed. Never commit credentials.

## What the Script Does (12 Steps)

1. **Pre-flight checks** — verifies `mysql`, `mysqldump`, `rsync`, `ssh` exist on source
2. **Reads wp-config.php** — auto-extracts DB name, user, password, host, and table prefix
3. **Dumps the database** — full `mysqldump` with routines, triggers, and integrity checks
4. **Collects SSH credentials** — destination server host, user, auth method, web path, web user
5. **Remote pre-flight** — tests SSH connection, checks for `mysql` and `wp-cli` on destination
6. **Rsyncs all files** — transfers everything including `.htaccess` (excludes `.git`, `node_modules`)
7. **Collects new DB credentials** — host, name, user, password for the destination database
8. **Updates wp-config.php** — replaces DB credentials on the remote server via `sed`
9. **Imports the database** — loads the SQL dump into the new database
10. **URL search-replace** — WP-CLI serialization-safe replacement across all tables (if URLs changed)
11. **Sets permissions** — ownership to web user, dirs to 755, files to 644, wp-config.php to 600
12. **Cleanup** — offers to delete SQL dump from remote, flushes caches, prints post-migration checklist

## Real-Time Status

The script provides continuous feedback so you always know what's happening:

- **Progress bar** at each step: `████████░░░░░░░░ Step 6/12 (50%) — Syncing files [elapsed 3m 12s]`
- **Animated spinner** with live elapsed timer during long operations (DB dump, DB import, permissions)
- **Per-step timing**: `⏱ Step 5 completed in 12s`
- **File stats** before rsync: file count and total size
- **DB stats** after dump: size, line count, table count
- **rsync `--stats`** and `--progress` for per-file transfer details
- **Total elapsed time** in the final summary

## Post-Migration Checklist

After the script completes, verify:

1. Site loads correctly in a browser
2. wp-admin login works
3. Media uploads display properly
4. Internal links and navigation work
5. Permalink settings are correct (Settings → Permalinks → Save)
6. SSL certificate is valid (if using HTTPS)
7. DNS is updated (if needed)
8. Plugins behave correctly (deactivate/reactivate if needed)
9. CDN and caching plugin caches are cleared
10. Delete the `/db/` folder from both servers once confirmed

## License

MIT
