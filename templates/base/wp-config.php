<?php

/**
 * The base configuration for WordPress
 *
 * The wp-config.php creation script uses this file during the
 * installation. You don't have to use the web site, you can
 * copy this file to "wp-config.php" and fill in the values.
 *
 * This file contains the following configurations:
 *
 * * MySQL settings
 * * Secret keys
 * * Database table prefix
 * * ABSPATH
 *
 * @link https://wordpress.org/support/article/editing-wp-config-php/
 *
 * @package WordPress
 */
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https' ) {
	$_SERVER['HTTPS']       = 'on';
	$_SERVER['SERVER_PORT'] = 443;
}

/**
 * Composer Vendor Autoload
 */
if ( file_exists( __DIR__ . '/wp-content/vendor/autoload.php' ) ) {
	require_once __DIR__ . '/wp-content/vendor/autoload.php';
}

/**
 * Load Environment Configuration
 */
try {
	$dotenv = Dotenv\Dotenv::createImmutable( __DIR__ );
	// safeLoad() so a missing .env doesn't fatal when config is supplied via real
	// environment variables (e.g. on a production host). required() still enforces
	// that the values are present from whichever source.
	$dotenv->safeLoad();

	$dotenv->required( array( 'WP_HOME', 'WP_DIR' ) );
	$dotenv->required( array( 'DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST', 'DB_CHARSET', 'DB_COLLATE' ) );
	$dotenv->required( array( 'AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY', 'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT' ) );
} catch ( Exception $e ) {
	// Required configuration is missing or invalid. Fail loudly instead of booting a
	// half-configured site with cryptic "undefined array key" warnings.
	if ( 'cli' !== PHP_SAPI ) {
		http_response_code( 500 );
	}
	exit( 'WordPress configuration error: ' . $e->getMessage() . ' — copy .env.example to .env and set the required values.' );
}

/**
 * Site Configs
 */
define( 'WP_HOME', $_ENV['WP_HOME'] );
define( 'WP_SITEURL', $_ENV['WP_HOME'] . '/' . $_ENV['WP_DIR'] );
define( 'WP_CONTENT_URL', $_ENV['WP_HOME'] . '/wp-content' );
define( 'WP_CONTENT_DIR', __DIR__ . '/wp-content' );

/**
 * MySQL
 */
define( 'DB_NAME', $_ENV['DB_NAME'] );
define( 'DB_USER', $_ENV['DB_USER'] );
define( 'DB_PASSWORD', $_ENV['DB_PASSWORD'] );
define( 'DB_HOST', $_ENV['DB_HOST'] );
define( 'DB_CHARSET', $_ENV['DB_CHARSET'] );
define( 'DB_COLLATE', $_ENV['DB_COLLATE'] );

$table_prefix = $_ENV['DB_TABLE_PREFIX'];

/**
 * Authentication Keys and Salts
 */
define( 'AUTH_KEY', $_ENV['AUTH_KEY'] );
define( 'SECURE_AUTH_KEY', $_ENV['SECURE_AUTH_KEY'] );
define( 'LOGGED_IN_KEY', $_ENV['LOGGED_IN_KEY'] );
define( 'NONCE_KEY', $_ENV['NONCE_KEY'] );
define( 'AUTH_SALT', $_ENV['AUTH_SALT'] );
define( 'SECURE_AUTH_SALT', $_ENV['SECURE_AUTH_SALT'] );
define( 'LOGGED_IN_SALT', $_ENV['LOGGED_IN_SALT'] );
define( 'NONCE_SALT', $_ENV['NONCE_SALT'] );

/**
 * Developer Flags
 */
define( 'WP_DEBUG', filter_var( $_ENV['WP_DEBUG'], FILTER_VALIDATE_BOOLEAN ) );
define( 'WP_DEBUG_LOG', filter_var( $_ENV['WP_DEBUG_LOG'], FILTER_VALIDATE_BOOLEAN ) );
define( 'SCRIPT_DEBUG', filter_var( $_ENV['SCRIPT_DEBUG'], FILTER_VALIDATE_BOOLEAN ) );
define( 'DISALLOW_FILE_EDIT', filter_var( $_ENV['DISALLOW_FILE_EDIT'], FILTER_VALIDATE_BOOLEAN ) );
define( 'WP_DEBUG_DISPLAY', filter_var( $_ENV['WP_DEBUG_DISPLAY'], FILTER_VALIDATE_BOOLEAN ) );
define( 'WP_LOCAL_DEV', filter_var( $_ENV['WP_LOCAL_DEV'], FILTER_VALIDATE_BOOLEAN ) );

/**
 * Environment Type
 *
 * WordPress reads this via getenv(), but phpdotenv's immutable loader only populates
 * $_ENV/$_SERVER — so the .env value is invisible to core without an explicit define().
 * Left undefined, wp_get_environment_type() falls back to 'production', which disables
 * Application Passwords over non-production TLS and breaks REST Basic auth locally.
 */
if ( ! defined( 'WP_ENVIRONMENT_TYPE' ) && isset( $_ENV['WP_ENVIRONMENT_TYPE'] ) ) {
	define( 'WP_ENVIRONMENT_TYPE', $_ENV['WP_ENVIRONMENT_TYPE'] );
}

/**
 * WordPress Cache
 */
if ( ! defined( 'WP_CACHE' ) && ! empty( $_ENV['WP_CACHE'] ) ) {
	define( 'WP_CACHE', filter_var( $_ENV['WP_CACHE'], FILTER_VALIDATE_BOOLEAN ) );
}

/**
 * WP Migrate License
 */
if ( ! defined( 'WPMDB_LICENCE' ) && isset( $_ENV['WPMDB_LICENCE'] ) ) {
	define( 'WPMDB_LICENCE', filter_var( $_ENV['WPMDB_LICENCE'], FILTER_SANITIZE_FULL_SPECIAL_CHARS ) );
}

/**
 * Sync Images for Media Management
 */
if ( ! defined( 'MG_MEDIA_SYNC_URL' ) && isset( $_ENV['MG_MEDIA_SYNC_URL'] ) ) {
	define( 'MG_MEDIA_SYNC_URL', filter_var( $_ENV['MG_MEDIA_SYNC_URL'], FILTER_SANITIZE_URL ) );
}

/**
 * WordPress Setup
 */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';
