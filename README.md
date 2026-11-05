# wp-starter

A guided setup for Lando + Composer WordPress projects. One wizard covers the three ways a project starts.

| Command | Use it when |
|---|---|
| `wp-project.sh new` | There's nothing yet |
| `wp-project.sh adopt` | There's a live site but no repo |
| `wp-project.sh clone` | The repo exists and you need local development |
| `wp-project.sh resume` | A run stopped. Run this from the project folder |

Run it from the folder that holds your projects, such as `~/Sites`. With no command, it asks which one you need.

```bash
ln -s ~/Sites/wp-starter/wp-project.sh ~/Sites/wp-project.sh
cd ~/Sites && ./wp-project.sh
```

Requires Lando, a running Docker, git, Composer, PHP, perl, openssl and curl. `adopt` also needs rsync. Works with the bash that ships with macOS.

## What you get

**Per project, by answering the wizard:**

- **Theme:** a child of any wordpress.org theme, a custom theme with no parent, or none yet. A starter can come from a zip, folder or URL.
- **PHP version:** feeds Lando, Composer's platform, PHPCS and CI from one answer.
- **Asset build:** webpack and pnpm, or nothing.
- **Deployment:** see the hosts below, or none.
- **Premium Composer repos:** WP Migrate, Gravity Forms, Yoast. `auth.json.example` lists only what you pick.

**Every project:** generated `AGENTS.md`, CI (PHPCS, PHPStan, TruffleHog, Gitleaks), Mailpit, Xdebug tooling, and a `.env` with fresh salts generated on your machine.

## Hosts

| Preset | Transport | Notes |
|---|---|---|
| `bigscoots` | rsync | Host helpers, cache and Perfmatters are excluded |
| `wpengine` | WP Engine action | Asks for install names |
| `siteground` | rsync | Port 18765, SG plugins excluded |
| `hostgator` | rsync | Port 2222, host plugins excluded |
| `godaddy`, `sftp` | SFTP | `wp-content` only; server core isn't managed by Composer |
| `ssh` | rsync | Any host with SSH |

**To add a host,** create one file in `templates/deploy/hosts/`. That's all, apart from adding it to the menu in `lib/deploy.sh`.

```bash
HOST_LABEL='Kinsta'
TRANSPORT='rsync'      # rsync, sftp or wpe
SSH_PORT='22'
ROOT_EXCLUDES=''       # docroot files the host owns, space-separated
WP_CONTENT_EXCLUDES='' # paths in wp-content the host owns
```

Before relying on a new preset, list what's on the server. Anything host-managed that the repo lacks must be excluded, or the deploy will delete it. `mu-plugins` and `languages` are protected for every rsync host.

## How the rsync deploy stays safe

`--delete` is never rooted at the docroot, because a docroot can hold sibling sites, host tools and logs. It runs in three passes: root files with no delete, then `wp-admin` and `wp-includes`, then `wp-content`. Run the deploy workflow by hand with `dry_run` before the first real deploy.

## Answering from a file

`--config FILE` reads answers from a shell-style file and skips the prompts. Anything missing uses its default.

```bash
PROJECT_NAME=acme-widgets
THEME_KIND=child
PARENT_CHOICE=ollie
THEME_SOURCE=
ASSETS=true
DEPLOY_HOST=bigscoots
STAGING_URL=https://staging.acme.test
AUTO_COMMIT=true
```

Outward-facing steps never run from a config file. Creating a GitHub repo always needs a person to confirm it.

## Repo layout

```
wp-project.sh      entry point
lib/               prompts, stages, rendering, one file per mode
bin/               wp-composerize.sh, ollie-mcp.sh
versions.env       every pinned version and action SHA
templates/base/    files for every project
templates/assets/  webpack and pnpm overlay
templates/ci/      ci.yml
templates/deploy/  transports, shared build steps, host presets
templates/theme/   minimal theme scaffolds
```

## Templates

- `{{TOKEN}}` is replaced from exported variables. An unknown token is a hard error.
- A line holding only a token expands multi-line values at that indent, and disappears if the value is empty.
- `@@if NAME`, `@@if !NAME` and `@@endif` on their own lines keep or drop a block.
- `gitignore.tmpl` becomes `.gitignore`. It can't be named that here, or git would apply it to this repo.

## Updating pins

Change `versions.env`. Action pins are full commit SHAs, so a moved tag can't change what runs in CI. pnpm blocks dependency build scripts unless they're listed in `templates/assets/pnpm-workspace.yaml`, so check that file when adding a JS dependency.
