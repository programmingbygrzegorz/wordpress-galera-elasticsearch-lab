<?php
/**
 * Plugin Name: Lab – który węzeł?
 * Description: Pokazuje w stopce i w pasku admina, który serwer obsłużył żądanie oraz commit aktywnego wydania.
 * Version: 1.0.0
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

function lab_release_info() {
	$revision = @file_get_contents( ABSPATH . 'REVISION' );
	return sprintf( '%s · commit %s', gethostname(), $revision ? substr( trim( $revision ), 0, 7 ) : '?' );
}

add_action( 'send_headers', function () {
	header( 'X-WP-Release: ' . lab_release_info() );
} );

add_action( 'wp_footer', function () {
	printf(
		'<div style="position:fixed;bottom:0;right:0;padding:4px 10px;background:#1d2327;color:#fff;font:12px monospace;z-index:9999">%s</div>',
		esc_html( lab_release_info() )
	);
} );

add_action( 'admin_bar_menu', function ( $bar ) {
	$bar->add_node( array( 'id' => 'lab-node', 'title' => esc_html( lab_release_info() ) ) );
}, 100 );
