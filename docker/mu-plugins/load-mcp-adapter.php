<?php
/**
 * Load mcp-adapter plugin with correct __FILE__ path
 */
$mcp_plugin_file = WP_CONTENT_DIR . '/plugins/mcp-adapter/mcp-adapter.php';
if ( file_exists( $mcp_plugin_file ) ) {
	// Use include instead of require_once to avoid "cannot redeclare" errors
	// and pass the plugin file path so plugin_dir_path works correctly
	include $mcp_plugin_file;
}
