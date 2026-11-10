# wp-starter

A guided setup for Lando + Composer WordPress projects. One wizard covers the three ways a project starts.

| Command | Use it when |
|---|---|
| `wp-project.sh new` | There's nothing yet |
| `wp-project.sh adopt` | There's a live site but no repo |
| `wp-project.sh clone` | The repo exists and you need local development |
| `wp-project.sh resume` | A run stopped. Run this from the project folder |

Clone this repo anywhere, then run the wizard from the folder that holds your projects. New projects are created there. With no command, it asks which one you need.

```bash
git clone <repo-url> ~/wp-starter
cd ~/Sites            # wherever your projects live
~/wp-starter/wp-project.sh
```

A symlink saves typing: `ln -s ~/wp-starter/wp-project.sh ~/Sites/wp-project.sh`, then `./wp-project.sh`. Setting `PROJECTS_DIR` creates projects there instead of the current folder.

Setup runs as numbered steps, and `resume` picks up at the step that stopped.

**Platforms:** tested on macOS, with the bash it ships. Linux should work but hasn't been tested. On Windows, use WSL.

## Before you start

**Every mode** needs Lando 3.21 or newer with Docker running, plus git, Composer 2, PHP, perl, openssl and curl on your machine. The wizard checks these before its first project question. Node and pnpm run inside Lando, so you don't need them locally. To have the wizard create the GitHub repo at the end, install `gh` and run `gh auth login` first. Without `gh`, that step is skipped.

**`adopt` over SSH** pulls from the **production** site, whose URL becomes the project's production URL. You need:

- SSH access to production. A key with a `Host` alias in `~/.ssh/config` is easiest. A password works too: the wizard reuses one connection, so you type it once.
- WP-CLI on the server, and rsync on your machine.
- The folder WordPress lives in on the server, the one holding `wp-content`. On WP Engine that's `~/sites/<install>`; on cPanel hosts it's usually `~/public_html`. The wizard checks it before going on.

Adopting copies the production database to your machine, including users' names, emails and any form entries. Get the site owner's OK before adopting a client site. The copy is imported into Lando, the temporary dump is deleted when setup finishes, and outbound email is disabled so the local site can't email real people.

**`adopt` from a backup** needs a folder or `.zip` with `wp-content` and a `.sql` or `.sql.gz` dump inside, such as a hosting panel backup. All-in-One WP Migration `.wpress` files and UpdraftPlus's split archives won't work.

**`clone`** needs git access to the repo, plus a database source: a dump file, SSH access to any environment (staging is safer, since production holds real people's data), a fresh install, or nothing for now.

**Premium Composer repos** need credentials in `auth.json`, which the wizard asks for when it gets there:

| Plugin | Credentials |
|---|---|
| WP Migrate DB Pro | Composer username and password from your Delicious Brains account |
| Gravity Forms | License key and the site URL it's registered to |
| Yoast SEO Premium | MyYoast token ID and secret |

**Deploys** need nothing up front. The wizard prints the GitHub secrets to add when it finishes.

## What this assumes

The generated projects are opinionated. If these don't fit how you work, this isn't the right starter:

- **Lando** for local development: nginx, MySQL, Mailpit, and Xdebug (off by default).
- **WordPress core is a Composer dependency** installed into `cms/`, never committed. The site runs as a subdirectory install with `wp-content/` at the project root, and the deploy reassembles it for the server.
- **Plugins and themes come from [wpackagist](https://wpackagist.org)** through Composer and are gitignored. Only your own theme, custom plugins and premium plugins with no Composer source are committed.
- **Config lives in `.env`**, read by `wp-config.php`. Credentials never enter git.
- **The disable-emails plugin** is activated on any copied database, so local sites can't email real users.
- **Parent theme shortcuts** are Ollie and Astra, but any wordpress.org theme works.
- **A generated `AGENTS.md`** (and `CLAUDE.md` pointing to it) gives AI coding agents the project's rules: WordPress Coding Standards, one-at-a-time plugin updates, browser QA checklists, and secrets handling. Edit it to match your own practices.

## Starting over

If a run fails, fix the problem and run `wp-project.sh resume` from the project folder. To start over instead:

```bash
cd <project> && lando destroy -y && cd .. && rm -rf <project>
```

If the failure message mentioned a database copy in a temporary folder, delete that folder too. It can hold personal data.

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

Before relying on a new preset, list what's on the server. Anything host-managed that the repo lacks must be excluded, or the deploy will delete it. `mu-plugins` and `languages` are protected for every rsync host and for WP Engine. Preset excludes match only at the root of their transfer.

## How the rsync deploy stays safe

`--delete` is never rooted at the docroot, because a docroot can hold sibling sites, host tools and logs. It runs in three passes: root files with no delete, then `wp-admin` and `wp-includes`, then `wp-content`. Run the deploy workflow by hand with `dry_run` before the first real deploy.

No deploy workflow runs until the repository variable `DEPLOY_ENABLED` is `true`, so pushing a new repo can't deploy. A `dry_run` works before that. Secrets use the same names in each GitHub environment; the reusable workflow's job picks the right set.

## Answering from a file

`--config FILE` reads answers from a shell-style file and skips the prompts. Anything missing uses its default.

```bash
PROJECT_NAME=acme-widgets
GITHUB_OWNER=your-github-name
THEME_KIND=child
PARENT_CHOICE=ollie
THEME_SOURCE=
ASSETS=true
DEPLOY_HOST=bigscoots
STAGING_URL=https://staging.acme.test
AUTO_COMMIT=true
```

Outward-facing steps never run from a config file. Creating a GitHub repo always needs a person to confirm it.

Every prompt can be answered this way. Yes/no answers take `true` or `false`.

| Key | Mode | Values |
|---|---|---|
| `MODE` | all | `new`, `adopt`, `clone` |
| `PROJECT_NAME` | new, adopt | Lowercase slug |
| `PHP_VERSION` | all | `major.minor`, e.g. `8.4` |
| `AUTHOR_NAME`, `AUTHOR_EMAIL` | all | Used in composer.json and for the admin user |
| `GITHUB_OWNER`, `GITHUB_REPO` | all | Name the Composer package and the repo |
| `THEME_KIND` | new | `child`, `standalone`, `none` |
| `PARENT_CHOICE` | new | `ollie`, `astra`, `other` |
| `PARENT_THEME` | new | wordpress.org theme slug, when `PARENT_CHOICE=other` |
| `THEME_SOURCE` | new | Zip, folder or URL; empty to scaffold |
| `THEME_NAME` | new, adopt | Theme folder name |
| `ASSETS` | new, adopt | Add the webpack + pnpm build |
| `ADMIN_USER`, `SITE_TITLE` | new, clone | For a fresh install |
| `PRODUCTION_URL` | new | Full URL |
| `PROD_INTEGRATION` | new, adopt | Load missing media from production |
| `WP_MIGRATE`, `GRAVITY_FORMS`, `YOAST_PREMIUM` | new, adopt | Premium Composer repos |
| `DEPLOY_HOST` | new, adopt | `none`, `bigscoots`, `wpengine`, `siteground`, `hostgator`, `godaddy`, `ssh`, `sftp` |
| `PROD_BRANCH`, `STAGING_BRANCH` | new, adopt | Branch names |
| `HAS_STAGING`, `STAGING_URL` | new, adopt | Staging site, and its full URL |
| `WPE_ENV_PRODUCTION`, `WPE_ENV_STAGING` | new, adopt | WP Engine install names |
| `PULL_SOURCE` | adopt | `ssh`, `backup` |
| `SSH_TARGET`, `REMOTE_PORT`, `REMOTE_DOCROOT` | adopt, clone | SSH source |
| `BACKUP_PATH`, `SQL_PATH` | adopt, clone | Local backup and `.sql` / `.sql.gz` paths |
| `OLD_URL`, `DB_TABLE_PREFIX` | adopt | Detected from the database when not set |
| `REPO_URL`, `PROJECT_FOLDER`, `CLONE_BRANCH` | clone | Repo to clone, and where |
| `DB_SOURCE` | clone | `fresh`, `dump`, `ssh`, `skip` |
| `AUTO_COMMIT` | all | Make the first commit without asking |
| `AUTO_REMOVE` | adopt | Remove pulled copies of Composer-managed plugins without asking |

## Extras

`bin/ollie-mcp.sh` connects [Claude Code](https://claude.com/claude-code) to a local site's [Ollie](https://olliewp.com) design tools over MCP. Skip it unless you use both. It needs the `claude` CLI and a running Lando site with an administrator account. Ollie Pro installs the MCP Adapter plugin for you; without it, pass the plugin's zip as `MCP_ADAPTER_ZIP`, and the server registers with no Ollie tools.

```bash
cd ~/Sites/myproject && ~/wp-starter/bin/ollie-mcp.sh
```

It mints a WordPress application password for the account you pick, rotating it on every run, and registers the server for that project folder only.

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

## License

MIT. See [LICENSE](LICENSE).
