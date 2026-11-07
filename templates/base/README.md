# {{PROJECT_NAME}}

A composerized, versioned WordPress site. See [AGENTS.md](AGENTS.md) for operating rules, plugin update paths and QA checklists.

## Layout

```
.
├── index.php        # front controller, requires cms/wp-blog-header.php
├── wp-config.php    # reads config from .env (no secrets committed)
├── cms/             # WordPress core, installed by Composer (gitignored)
├── wp-content/      # themes, plugins, mu-plugins, vendor/
├── config/          # Lando nginx and PHP config
└── composer.json    # core → cms/, plugins and themes → wp-content/
```

@@if HAS_THEME
## Theme

{{THEME_SUMMARY}}

@@endif
## Local setup

Requires [Lando](https://docs.lando.dev/getting-started/installation.html) and a running Docker.

To set up by hand:

```bash
git clone git@github.com:{{GITHUB_OWNER}}/{{GITHUB_REPO}}.git {{PROJECT_NAME}} && cd {{PROJECT_NAME}}
cp .env.example .env   # then fill the salts: https://api.wordpress.org/secret-key/1.1/salt/
@@if HAS_AUTH
cp auth.json.example auth.json   # then add premium repository credentials
@@endif
lando start
lando composer install
@@if ASSETS
lando pnpm install
lando pnpm build
@@endif
lando wp core install --url=https://{{PROJECT_NAME}}.lndo.site --title="{{PROJECT_NAME}}" --admin_user=<user> --admin_password=<password> --admin_email=<email> --skip-email
@@if HAS_THEME
lando wp theme activate {{THEME_NAME}}
@@endif
```

- Site: https://{{PROJECT_NAME}}.lndo.site
- Mail (Mailpit): https://mail.{{PROJECT_NAME}}.lndo.site

## Common commands

| Command | Description |
|---|---|
| `lando start` / `stop` / `rebuild` | Manage the environment |
| `lando composer <cmd>` | Composer |
| `lando composer lint` | PHPCS and PHPStan |
| `lando phpcbf <path>` | Auto-fix coding standards |
| `lando wp <cmd>` | WP-CLI |
| `lando xdebug-on` / `xdebug-off` | Toggle Xdebug |
@@if ASSETS
| `lando pnpm <cmd>` | pnpm (`build`, `dev`, `lint`, `format`) |
@@endif
@@if HAS_THEME
| `lando make-pot` | Generate the theme's translation template |
@@endif

@@if DEPLOY
## Deployment

Deploys to **{{HOST_LABEL}}** through GitHub Actions. {{DEPLOY_SUMMARY}}

| Workflow | Trigger | Result |
|---|---|---|
| `ci.yml` | Pull request | Lint, build, secret scans |
@@if HAS_STAGING
| `deploy-staging.yml` | Push to `{{STAGING_BRANCH}}` | Deploy to staging |
@@endif
| `deploy-production.yml` | Push to `{{PROD_BRANCH}}` | Deploy to production |
| `deploy.yml` | Called by the above | Shared build and deploy |

Required secrets: {{SECRET_NAMES}}

Create `production`{{STAGING_ENV_NOTE}} under Settings → Environments, and add a required reviewer to `production`. Deploys stay off until the repository variable `DEPLOY_ENABLED` is `true`.

@@endif
@@if !DEPLOY
## Deployment

No deployment is configured yet. Only `ci.yml` runs.

@@endif
## Production integration

See [ENABLE-PRODUCTION.md](ENABLE-PRODUCTION.md) for WP Migrate DB Pro and production media proxying.
