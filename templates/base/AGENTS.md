# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## What this is

**{{PROJECT_NAME}}** is a composerized WordPress site.

- **WordPress core** is a Composer dependency (`johnpbloch/wordpress-core`), installed into `cms/`. It is never committed and never edited.
- **Plugins and themes** come from [wpackagist](https://wpackagist.org) via Composer, installed into `wp-content/`.
@@if HAS_THEME
- **Theme:** {{THEME_SUMMARY}}
@@endif
@@if ASSETS
- **Assets** in `wp-content/themes/{{THEME_NAME}}/assets/` compile with webpack via **pnpm**. Compiled files are gitignored and built in CI.
@@endif
- **Config** is environment-driven: `wp-config.php` reads `.env` via phpdotenv. No credentials are ever committed.

Local layout is a subdirectory install: core in `cms/`, `wp-content/` at the root, front-controller `index.php`.
@@if DEPLOY
The deploy pipeline reassembles this for the server. See `.github/workflows/deploy.yml`.
@@endif

## Project notes

<!-- Add what an agent can't work out from the code: client context, decisions, constraints, critical forms. -->

## Commands

Run everything through Lando.

| Task | Command |
|---|---|
| Install PHP deps (core + plugins) | `lando composer install` |
| PHP standards + static analysis | `lando composer lint` |
| WP-CLI | `lando wp <command>` |
@@if ASSETS
| Install JS deps | `lando pnpm install` |
| Build assets | `lando pnpm build` |
| Watch assets | `lando pnpm dev` |
| Lint JS/SCSS | `lando pnpm lint` |

Use **pnpm**, never npm or yarn. `packageManager` is pinned and CI uses `--frozen-lockfile`.
@@endif

Mail is caught by Mailpit: https://mail.{{PROJECT_NAME}}.lndo.site
@@if DEPLOY

## Branch → environment pipeline

| Branch | Environment | URL | Trigger |
|---|---|---|---|
@@if HAS_STAGING
| `{{STAGING_BRANCH}}` | staging | {{STAGING_URL}} | push (automatic) |
@@endif
| `{{PROD_BRANCH}}` | production | {{PRODUCTION_URL_OR_REPO}} | push (gate it with reviewers on the `production` GitHub environment) |

@@if HAS_STAGING
Flow: feature branch → PR into `{{STAGING_BRANCH}}` (CI must pass) → verify on staging → PR `{{STAGING_BRANCH}}` into `{{PROD_BRANCH}}` → production deploy.

Never push directly to `{{PROD_BRANCH}}`. Never fast-forward `{{STAGING_BRANCH}}` onto a commit already on `{{PROD_BRANCH}}`; that skips the staging deploy for those changes.
@@endif
@@if !HAS_STAGING
Flow: feature branch → PR into `{{PROD_BRANCH}}` (CI must pass) → production deploy. There is no staging site, so QA locally before merging.

Never push directly to `{{PROD_BRANCH}}`.
@@endif

## Hosting

Deploys to **{{HOST_LABEL}}**. {{DEPLOY_SUMMARY}}

Host names, users, paths and keys live in GitHub Actions **secrets**, bound to GitHub environments, never in this repo. Don't add them to this file. For SSH access, use a `Host` alias in your own `~/.ssh/config`; the examples below call it `{{SSH_ALIAS}}`.

Required secrets: {{SECRET_NAMES}}
@@endif

## Secrets policy

- `.env`, `auth.json`, private keys, database dumps: gitignored, and the deploy pipeline strips credentials from the release payload.
- Before committing, check added files for personal data (real emails, names, phone numbers, addresses). Strip `<wp:author>` blocks from WXR exports.
- Every PR runs **TruffleHog** (verified credentials) and **Gitleaks** (patterns). Every deploy runs TruffleHog. A hit fails the build.
- If you find a real credential in the repo or its history: stop, do not push, rotate the credential first, then scrub history.

## Plugin management: three sources, three update paths

Not every plugin arrives the same way. Know which kind you are touching
before you update anything, because each has a different update mechanism
and a different failure mode.

### 1. wpackagist (free wordpress.org plugins)

Composer-managed, gitignored, installed by `composer install`.

```
lando composer update wpackagist-plugin/safe-svg --with-dependencies
```

The change lands in `composer.lock` — that lockfile diff IS the update.
Commit it.

### 2. Premium plugins WITH a Composer repository

Vendors like Gravity Forms, Yoast Premium, ACF PRO, and Delicious Brains
publish authenticated Composer repos. These are also Composer-managed and
gitignored; credentials live in `auth.json` (gitignored locally, injected
in CI from the `COMPOSER_AUTH_JSON` secret — never committed).

```
lando composer update gravity/gravityforms --with-dependencies
```

Same rule: the `composer.lock` diff is the update; commit it. If Composer
suddenly can't resolve the package, suspect an expired license/token in
`auth.json` before suspecting the version constraint.

### 3. Premium plugins WITHOUT a Composer version (git-committed)

Some premium plugins offer no Composer channel at all. These are the
exception to "plugins are gitignored": their directory is force-included
in `.gitignore` and **committed directly to this repo**. Updating one is
manual:

1. Download the new zip from the vendor (license account).
2. Delete the old plugin directory entirely, extract the new one in its
   place (a plain overwrite leaves behind files the new version deleted).
3. Diff before committing: `git diff --stat wp-content/plugins/<plugin>/`.
   Confirm the changes look like a plugin update, not a corrupted extract.
4. Commit the plugin update **in its own commit**, named with the version:
   `Plugins: update <plugin> 4.2.1 → 4.3.0`.
5. Never hand-edit these plugins. If a patch is unavoidable, document it
   at the top of the commit message and in a `PATCHES.md` inside the
   plugin directory — otherwise the next update silently reverts it.

**The trap to avoid:** running WordPress's built-in updater on the server
updates the plugin *on the server only*. The git copy is now behind, and
the next deploy's `rsync --delete` will **downgrade the plugin in
production**. Auto-updates must stay disabled for git-committed plugins;
every update flows through the repo.

### Update cadence: stages, not batches

**Never update everything at once.** A ten-plugin `composer update` that
breaks the site tells you nothing about which plugin broke it.

1. Update **one plugin** (or one tightly-coupled group, e.g. a plugin and
   its add-ons) at a time.
2. Run the local smoke test: site boots, no new notices in `debug.log`,
   `wp plugin list` shows the expected version.
3. In-browser QA the surface that plugin owns (see below). A forms plugin
   update means testing forms *in a browser*, not just loading the homepage.
4. Commit that update on its own, with the version change in the message.
5. Only then move to the next update.
6. Core updates (`johnpbloch/wordpress-core`) get their own dedicated
   pass: update core alone, full QA sweep, own commit.

Staged commits mean a broken update is one `git revert` — not an
archaeology dig through a 40-file lockfile diff.

@@if DEPLOY
## Logged-in QA: WP-CLI magic links

Testing the logged-in experience (dashboard, admin screens, form entries,
member-only content) must not involve sharing passwords or creating
throwaway admin accounts by hand. Use WP-CLI's login command to mint a
**magic link** over SSH:

```bash
# One-time setup per environment (installs the login command package):
ssh {{SSH_ALIAS}} "cd <docroot> && wp package install aaemnnosttv/wp-cli-login-command && wp login install --activate --yes"

# Mint a single-use login link for an existing user:
ssh {{SSH_ALIAS}} "cd <docroot> && wp login create qa-admin"
```

Rules:

- Links are **single-use and short-lived**. Mint a fresh one per QA session; never store them in docs, tickets, or chat logs.
- Log in as a user with the **role you are testing** — an admin session tells you nothing about what a subscriber or shop-manager sees. Create role-scoped QA users with `wp user create qa-editor qa-editor@{{PROJECT_NAME}}.test --role=editor` if they don't exist.
- On production, prefer a dedicated `qa-` user over a real person's account, and remove or deactivate QA users when done: `wp user delete qa-editor --reassign=<admin-id>`.
- If `wp login create` fails, check that the companion mu-plugin is active (`wp login install --activate --yes`) — the package needs both halves.

@@endif
## QA testing

### Before opening a PR

1. `composer validate --strict` passes.
2. `lando composer lint` passes (PHPCS and PHPStan on authored code).
3. Spin up locally with Lando and verify the site boots with no PHP notices in `wp-content/debug.log`.
@@if ASSETS
4. `lando pnpm lint && lando pnpm build` succeeds. A broken webpack build fails the deploy.
@@endif

@@if HAS_STAGING
### After a staging deploy (before promoting to main)

1. **Deploy check**: the `Deploy staging` run is green; the rsync step completed.
2. **Smoke over SSH** (Cloudflare-style bot protection can 403 curl, so verify on the box, not over HTTP):
   ```
   ssh {{SSH_ALIAS}} "cd <docroot> && wp core verify-checksums && wp option get home && wp plugin list --update=available"
   ```
3. **Full in-browser QA** — see the checklist below. This is not optional and cannot be replaced by curl or HTTP status checks.
4. **Regression check on excluded paths**: uploads still present (rsync `--delete` must never touch `wp-content/uploads/`), server `wp-config.php` untouched.
5. **Accessibility spot check**: `npx @axe-core/cli {{STAGING_URL}} --tags wcag2a,wcag2aa`.

@@endif
@@if DEPLOY
### After a production deploy

Repeat the SSH smoke check against `{{SSH_ALIAS}}`, then run the
critical-path browser checklist (at minimum: homepage, one form
end-to-end, one logged-in dashboard screen). If anything is wrong,
redeploy the previous commit (`git revert` + push to `main`) — the
pipeline is the rollback mechanism; never hot-edit files on the server.

@@endif
## In-browser QA checklist

Run this in a **real browser** (not curl — bot protection, JS-rendered
markup, and form tokens all behave differently). Test the environment you
just deployed to, logged out first, then logged in via a magic link.

### Why a browser is required

- Consent/caching layers and bot protection serve different responses to non-browser clients.
- Forms depend on JavaScript: validation, conditional logic, AJAX submission, spam tokens (Turnstile/reCAPTCHA) — none of which execute under curl.
- A page can return HTTP 200 with broken assets, a JS exception, or an empty form where the plugin failed to render. Only eyes on a rendered page catch that.

### Critical paths (every staging verification)

1. **Homepage** — renders with styles, no console errors, no mixed-content warnings.
2. **One of each template type** — post, page, archive, search results, 404. Watch the console on each.
3. **Navigation** — primary menu works on desktop AND at a mobile viewport width (hamburger opens, links navigate).
4. **`/wp-admin` via magic link** — dashboard loads with no plugin error notices; open the settings screen of any plugin updated in this release.

### Forms — full end-to-end, every form that matters

**A forms-related
change (forms plugin update, SMTP plugin update, theme JS change, jQuery
or core update) means every critical form gets this treatment before the
change is promoted.** Keep a list of the site's critical forms (contact,
lead-gen, registration, payment) and walk it.

For each critical form:

1. **Render**: the form appears, all fields present, in a logged-OUT browser session (caching layers often serve logged-out users a cached — possibly stale — page; a form that works logged-in can be broken logged-out).
2. **Client-side validation**: submit empty → required-field errors appear inline. Enter a malformed email → rejected before submission.
3. **Conditional logic**: if the form shows/hides fields based on answers, exercise each branch.
4. **Successful submission**: fill with obviously-fake-but-valid test data (name like `QA Test — <date>`, email you control) and submit. Confirm the success state: confirmation message, or redirect to the thank-you page — whichever the form is configured for.
5. **The entry actually arrived**: check the plugin's entries screen in wp-admin (magic link) — the submission is stored with every field intact.
6. **Notifications sent**: the admin notification email AND any user-facing autoresponder arrived (check the SMTP plugin's log if it has one). Email is the most common silent failure — the form "works" but nobody is notified.
7. **Spam protection intact**: the Turnstile/reCAPTCHA widget renders; a submission completes normally with it present. If JS is combined/minified by a cache plugin, this is where it breaks first.
8. **Multi-step/payment forms**: complete every step; for payment forms use the gateway's test mode and confirm the transaction appears in the gateway dashboard.
9. **File uploads**: upload an allowed type (confirm it attaches) and a disallowed type (confirm it's rejected).
10. **Clean up**: delete QA entries afterward on production; leave them on staging if it gets database-refreshed.

Repeat step 4 once at a mobile viewport — touch targets, keyboard type, and sticky headers overlapping the submit button are all mobile-only failures.

### Logged-in experience

Via magic link (see above), as the lowest-privileged relevant role:

1. Dashboard loads without notices or fatal admin-ajax errors in the console.
2. Any front-end account/dashboard pages render with correct user data.
3. Content restricted to the role is visible; content above the role is not.
4. Log out; confirm restricted content is gone and the login page works.

### After dependency updates specifically

The in-browser pass above is scoped by what changed:

| What updated | Minimum browser QA |
|---|---|
| Forms plugin or its add-ons | The **full forms checklist**, every critical form |
| SMTP/email plugin | One form submission + confirm both notification emails |
| SEO plugin | View source on 2–3 pages: title/meta/schema present and sane |
| Caching/optimization plugin | Forms checklist steps 1, 4, 7 (JS combining breaks form JS first) + styles intact logged-out |
| Theme or parent theme | Every template type + navigation + one form render |
| WordPress core | Full critical-path list + full forms checklist + logged-in pass |
| Security/login plugin | Log in, log out, magic link still works, no admin lockout |

## Hard rules for agents

- Never commit `.env`, `auth.json`, keys, database dumps, or anything under `cms/` or `wp-content/vendor/`.
@@if HAS_THEME
- Never edit Composer-installed plugin or theme code. Changes go in `wp-content/themes/{{THEME_NAME}}` or a custom plugin. Git-committed premium plugins are updated whole, never hand-edited.
@@endif
@@if !HAS_THEME
- Never edit Composer-installed plugin or theme code. Git-committed premium plugins are updated whole, never hand-edited.
@@endif
- Never update dependencies in bulk: one at a time, QA between each, own commit per update.
- Follow WordPress Coding Standards. Sanitize input, escape output, verify nonces, and use WordPress APIs for post and meta changes, never raw SQL.
@@if DEPLOY
- Never let the server's built-in updater touch git-committed plugins; the next deploy would downgrade them.
- Never edit files directly on a server; every change flows through git and the pipeline.
- Deployment changes go in `deploy.yml` (shared), not duplicated into the per-environment callers.
- A plugin installed only on the server is removed by the next deploy unless the repo or the deploy excludes know about it.
@@endif
