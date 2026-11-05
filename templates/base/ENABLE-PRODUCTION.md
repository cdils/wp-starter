# Production integration

Two optional features need a production site to exist:

- **WP Migrate DB Pro** syncs the database between environments.
- **mg-media-management** and the nginx proxy load missing media from production, so uploads stay out of git.

@@if PROD_INTEGRATION
Media proxying is **enabled** for {{PRODUCTION_URL}}.

@@endif
@@if !PROD_INTEGRATION
Media proxying is **not enabled**. To enable it:

1. Require the plugin:
   ```bash
   lando composer config repositories.mgratch vcs https://github.com/mgratch/mg-media-management
   lando composer require --dev mgratch/mg-media-management:1.1.0
   ```
2. In `config/lando.conf`, add an `@production` location above `location = /favicon.ico`:
   ```nginx
   location ~ ^/wp-content/uploads/(.*)$ {
       try_files $uri @production;
   }

   location @production {
     proxy_ssl_server_name on;
     proxy_intercept_errors on;
     proxy_pass https://your-production-url.example;
   }
   ```
3. Set `MG_MEDIA_SYNC_URL=https://your-production-url.example` in `.env`.
4. Run `lando rebuild -y`.

@@endif
@@if !WP_MIGRATE
## Adding WP Migrate DB Pro

```bash
lando composer config repositories.wp-migrate composer https://composer.deliciousbrains.com
lando composer require deliciousbrains-plugin/wp-migrate-db-pro:^2.7
```

Add the credentials to `auth.json`, set `WPMDB_LICENCE` in `.env`, then run `lando wp plugin activate wp-migrate-db-pro`.

@@endif
## Database sync rules

1. Never push your local database to production.
2. When pulling from production, check for personally identifiable information first. If PII exists, consult the team before proceeding.
3. Only push local database changes to staging or development after discussing with the team.
4. Make database changes on higher environments and pull them down (staging → development → local).
