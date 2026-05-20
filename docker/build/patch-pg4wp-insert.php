<?php
/**
 * Patches PG4WP's INSERT-query parser (driver_pgsql.php) for edge cases
 * hit in production. Usage: php patch-pg4wp-insert.php <path-to-driver_pgsql.php>
 *
 * Fails loudly if none of the patches apply. If PG4WP's source changes
 * shape on a version bump, we want the build to break here, not silently
 * ship an unpatched driver that we already know is broken.
 */

$path = $argv[1] ?? null;
if (!$path || !is_file($path)) {
    fwrite(STDERR, "Usage: php patch-pg4wp-insert.php <path-to-driver_pgsql.php>\n");
    exit(1);
}

$data = file_get_contents($path);

$patches = [
    // Recognise "INSERT IGNORE INTO ..." as an INSERT, not just "INSERT INTO ...".
    // Without this the table name never matches and pg4wp_ins_table stays empty.
    [
        'old' => 'preg_match("/^INSERT INTO\s+`?([a-z0-9_]+)`?/i", $query, $matches);',
        'new' => 'preg_match("/^\s*INSERT\s+(?:IGNORE\s+)?INTO\s+`?([a-z0-9_]+)`?/i", $query, $matches);',
    ],
    // Bail out cleanly instead of a fatal when the table name regex above
    // didn't match anything (e.g. an unusual INSERT shape we don't expect).
    [
        'old' => '$tableName = $matches[1];',
        'new' => "\$tableName = \$matches[1];\n        if (!isset(\$matches[1]) || \$matches[1] === '') { return \$result; }",
    ],
    // Same idea for the primary-key lookup used to report the last insert ID.
    [
        'old' => '$GLOBALS["pg4wp_ins_id"] = $row[$primaryKey];',
        'new' => 'if ($primaryKey !== null && isset($row[$primaryKey])) { $GLOBALS["pg4wp_ins_id"] = $row[$primaryKey]; }',
    ],
];

$totalReplacements = 0;
foreach ($patches as $patch) {
    $data = str_replace($patch['old'], $patch['new'], $data, $count);
    $totalReplacements += $count;
}

if ($totalReplacements === 0) {
    fwrite(STDERR, "None of the expected patch targets were found in $path - PG4WP's source likely changed. Re-check the patches in " . __FILE__ . " against the new version before shipping.\n");
    exit(1);
}

file_put_contents($path, $data);
