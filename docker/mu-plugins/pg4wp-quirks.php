<?php
/**
 * PG4WP compatibility shims.
 *
 * WordPress core (and some plugins) occasionally issue MySQL-only SQL that
 * PG4WP's rewriter doesn't recognise. Rather than sed-patching PG4WP's
 * vendored source on every build (fragile, breaks on version bumps and hard
 * to review), we intercept the raw query here, via WP core's own `query`
 * filter, which fires before wpdb hands anything to the db.php driver.
 *
 * Every fix is logged to error_log (-> stdout/stderr -> Rock8Cloud log viewer)
 * so future breakage is traceable without guessing.
 *
 * Add new patterns here as they're discovered. Keep each one narrow and
 * commented with what triggered it.
 */

add_filter( 'query', function ( $sql ) {

	// --- Site Health / WP core "MyISAM table" check --------------------
	// Queries information_schema.TABLES filtering by ENGINE, a MySQL-only
	// column that doesn't exist in Postgres. Postgres has no storage
	// engines, so "no MyISAM tables found" is always the correct answer -
	// safe to just strip the condition rather than fail the query.
	if ( stripos( $sql, 'information_schema.TABLES' ) !== false && stripos( $sql, 'ENGINE' ) !== false ) {
		$patched = preg_replace( "/\s+AND\s+ENGINE\s*=\s*'[^']*'/i", '', $sql );
		if ( $patched !== $sql ) {
			error_log( '[pg4wp-quirks] stripped ENGINE clause from information_schema query' );
			$sql = $patched;
		}
	}

	// --- INSERT IGNORE ---------------------------------------------------
	// Postgres has no INSERT IGNORE; PG4WP doesn't rewrite it. Downgrading
	// to a plain INSERT is safe for WP's own usage (mostly de-dup on
	// options/postmeta) but re-check this if a plugin relies on the
	// "silently skip duplicate" behaviour for something important.
	if ( stripos( $sql, 'INSERT IGNORE' ) !== false ) {
		error_log( '[pg4wp-quirks] downgraded INSERT IGNORE to INSERT' );
		$sql = preg_replace( '/INSERT\s+IGNORE/i', 'INSERT', $sql );
	}

	// --- SHOW TABLES LIKE <table> ----------------------------------------
	// PG4WP's ShowTablesSQLRewriter rewrites ANY "SHOW TABLES" to
	// "SELECT tablename FROM pg_tables WHERE schemaname='public'",
	// silently DROPPING the LIKE clause. Any caller doing
	// get_var("SHOW TABLES LIKE 'x'") therefore gets an arbitrary table
	// name back and concludes its table doesn't exist - observed live
	// with Elementor's EventTracker (core/common/modules/event-tracker/
	// db.php), which re-ran CREATE TABLE wp_e_events on EVERY request
	// because of this. Rewrite to an equivalent Postgres query ourselves;
	// PG4WP routes SELECTs through SelectSQLRewriter, which leaves this
	// shape alone apart from LIKE -> ILIKE (fine: MySQL LIKE is also
	// case-insensitive by default).
	if ( stripos( $sql, 'SHOW TABLES LIKE' ) !== false ) {
		$patched = preg_replace(
			"/SHOW\s+TABLES\s+LIKE\s+('(?:[^']|\\\\')*')/i",
			"SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE $1",
			$sql
		);
		if ( null !== $patched && $patched !== $sql ) {
			error_log( '[pg4wp-quirks] rewrote SHOW TABLES LIKE to pg_tables query' );
			$sql = $patched;
		}
	}

	// --- CREATE TABLE with backticked name --------------------------------
	// PG4WP's CreateTableSQLRewriter turns every CREATE TABLE into
	// CREATE TABLE IF NOT EXISTS - but its regex (/CREATE TABLE ... (\w+)/)
	// cannot match a backticked table name (`wp_e_events`), so backticked
	// creates go through WITHOUT the idempotency clause and blow up with
	// 'relation already exists' if the table is already there. Strip the
	// backticks from the statement head so PG4WP's own IF NOT EXISTS logic
	// engages. (Trigger: Elementor EventTracker, see SHOW TABLES above.)
	if ( stripos( $sql, 'CREATE TABLE' ) !== false && strpos( $sql, '`' ) !== false ) {
		$patched = preg_replace( '/(CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?)`(\w+)`/i', '$1$2', $sql );
		if ( null !== $patched && $patched !== $sql ) {
			error_log( '[pg4wp-quirks] stripped backticks from CREATE TABLE name (restores PG4WP IF NOT EXISTS)' );
			$sql = $patched;
		}
	}

	return $sql;
}, 5 ); // priority 5: run before anything else that touches the query
