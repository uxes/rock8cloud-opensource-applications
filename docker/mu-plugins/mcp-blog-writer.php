<?php
/**
 * MCP for content publishing - a narrow, purpose-built MCP server, not the
 * mcp-adapter default one. The default server exposes every ability marked
 * public through a generic discover/execute pair, which is a much bigger
 * surface than "let an agent write blog posts". This file exposes exactly
 * two abilities instead.
 *
 * Auth: point your MCP client at this server using WordPress Application
 * Passwords for a dedicated, LOW-privilege user (Author role - NOT admin).
 * Endpoint: https://<your-site>/wp-json/my-blog/mcp
 */

// Activate mcp-adapter without touching the DB (`active_plugins` option) -
// keeps activation immutable/rebuild-driven like everything else here.
// (Restored: an earlier iteration replaced this with a raw `include` of the
// plugin file from a separate mu-plugin, which loads the code but skips
// WordPress's normal activation lifecycle entirely - any register_activation_hook
// setup the plugin relies on, e.g. flushing rewrite rules, would silently
// never run. This filter-based approach goes through WP's real plugin
// loader instead, and was confirmed working via wp-admin -> Plugins.)
add_filter( 'option_active_plugins', function ( $plugins ) {
	$plugins[] = 'mcp-adapter/mcp-adapter.php';
	return $plugins;
} );

// wp_register_ability() has a hard guard in WP core (wp-includes/abilities-api.php):
//   if ( ! doing_action( 'wp_abilities_api_init' ) ) { return null; }
// Registration is REJECTED unless called literally from within that action's
// callback stack - this isn't a "prefer this hook" convention, it's enforced.
// An earlier attempt registered on plain `init` instead (working around a
// suspected mcp-adapter timing race, issue #117) - that was based on a wrong
// premise and always returned null here, confirmed via the diagnostic
// logging below (logged "falsy" on every request while on `init`).
add_action( 'wp_abilities_api_categories_init', function () {
	wp_register_ability_category( 'content', [
		'label'       => 'Content',
		'description' => 'Abilities for creating and managing content.',
	] );
} );

add_action( 'wp_abilities_api_init', function () {

	error_log( '[mcp-blog-writer] init fired. function_exists(wp_register_ability): '
		. ( function_exists( 'wp_register_ability' ) ? 'yes' : 'NO - Abilities API not available' ) );

	$result_1 = wp_register_ability( 'blog-writer/create-post', [
		'label'       => 'Create Blog Post',
		'description' => 'Create a new WordPress post (draft by default).',
		'category'    => 'content',
		'meta'        => [
			'mcp' => [
				'public' => true,
			],
		],
		'input_schema' => [
			'type'       => 'object',
			'required'   => [ 'title', 'content' ],
			'properties' => [
				'title'   => [ 'type' => 'string' ],
				'content' => [ 'type' => 'string', 'description' => 'Post body as HTML.' ],
				'status'  => [
					'type'    => 'string',
					'enum'    => [ 'draft', 'publish' ],
					'default' => 'draft',
				],
			],
		],
		'output_schema' => [
			'type'       => 'object',
			'properties' => [
				'ID'  => [ 'type' => 'integer' ],
				'url' => [ 'type' => 'string' ],
			],
		],
		'execute_callback' => function ( $input ) {
			$post_id = wp_insert_post( [
				'post_title'   => $input['title'],
				'post_content' => $input['content'],
				'post_status'  => $input['status'] ?? 'draft',
			], true );

			if ( is_wp_error( $post_id ) ) {
				return $post_id;
			}

			return [ 'ID' => $post_id, 'url' => get_permalink( $post_id ) ];
		},
		// publish_posts, not the broader edit_others_posts/manage_options -
		// the Application Password's user should only ever hold this much.
		'permission_callback' => fn() => current_user_can( 'publish_posts' ),
	] );

	error_log( '[mcp-blog-writer] create-post registration result: ' . (
		is_wp_error( $result_1 ) ? 'WP_Error: ' . $result_1->get_error_message() :
		( $result_1 ? 'success' : 'falsy (registration failed silently)' )
	) );

	$result_2 = wp_register_ability( 'blog-writer/list-posts', [
		'label'       => 'List Blog Posts',
		'description' => 'List recent posts, any status.',
		'category'    => 'content',
		'meta'        => [
			'mcp' => [
				'public' => true,
			],
		],
		'input_schema' => [
			'type'       => 'object',
			'properties' => [
				'numberposts' => [ 'type' => 'integer', 'default' => 10, 'minimum' => 1, 'maximum' => 50 ],
			],
		],
		'output_schema' => [
			'type'  => 'array',
			'items' => [
				'type'       => 'object',
				'properties' => [
					'ID'          => [ 'type' => 'integer' ],
					'post_title'  => [ 'type' => 'string' ],
					'post_status' => [ 'type' => 'string' ],
					'post_date'   => [ 'type' => 'string' ],
				],
			],
		],
		'execute_callback' => function ( $input ) {
			// WP core rest_is_object() only accepts stdClass / JsonSerializable /
			// array for schema type "object" - raw WP_Post instances fail output
			// validation with "output[0] is not of type object". Map to plain
			// associative arrays matching the declared output_schema.
			$posts = get_posts( [
				'numberposts' => $input['numberposts'] ?? 10,
				'post_status' => [ 'draft', 'publish' ],
			] );

			return array_map( static fn( $p ) => [
				'ID'          => (int) $p->ID,
				'post_title'  => (string) $p->post_title,
				'post_status' => (string) $p->post_status,
				'post_date'   => (string) $p->post_date,
			], $posts );
		},
		'permission_callback' => fn() => current_user_can( 'edit_posts' ),
	] );

	error_log( '[mcp-blog-writer] list-posts registration result: ' . (
		is_wp_error( $result_2 ) ? 'WP_Error: ' . $result_2->get_error_message() :
		( $result_2 ? 'success' : 'falsy (registration failed silently)' )
	) );

} );

add_action( 'mcp_adapter_init', function ( $adapter ) {
	$adapter->create_server(
		'blog-writer',
		'my-blog',
		'mcp',
		'Blog Writer',
		'Create and list blog posts.',
		'v1.0.0',
		[ \WP\MCP\Transport\HttpTransport::class ],
		\WP\MCP\Infrastructure\ErrorHandling\ErrorLogMcpErrorHandler::class,
		\WP\MCP\Infrastructure\Observability\NullMcpObservabilityHandler::class,
		[ 'blog-writer/create-post', 'blog-writer/list-posts' ]
	);
} );
