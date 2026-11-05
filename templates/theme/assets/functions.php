<?php
/**
 * {{THEME_TITLE}} theme bootstrap.
 *
 * @package {{THEME_NAME}}
 */

declare( strict_types=1 );

add_action(
	'wp_enqueue_scripts',
	static function (): void {
		$dist_dir = get_stylesheet_directory() . '/assets';
		$dist_url = get_stylesheet_directory_uri() . '/assets';

		if ( file_exists( $dist_dir . '/css/main.css' ) ) {
			wp_enqueue_style(
				'{{THEME_NAME}}',
				$dist_url . '/css/main.css',
				array(),
				(string) filemtime( $dist_dir . '/css/main.css' )
			);
		}

		if ( file_exists( $dist_dir . '/js/main.min.js' ) ) {
			wp_enqueue_script(
				'{{THEME_NAME}}',
				$dist_url . '/js/main.min.js',
				array(),
				(string) filemtime( $dist_dir . '/js/main.min.js' ),
				true
			);
		}
	}
);
