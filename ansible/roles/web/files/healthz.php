<?php
// Health check dla load balancera: węzeł jest zdrowy, gdy lokalny węzeł Galery
// przyjmuje zapytania (wsrep_ready=ON) i istnieje aktywne wydanie WordPressa.
header('Content-Type: text/plain');
header('Cache-Control: no-store');

$cfg = parse_ini_file('/etc/wp-lab/health.ini');
mysqli_report(MYSQLI_REPORT_OFF);
$db = @mysqli_connect('127.0.0.1', $cfg['user'], $cfg['password'], $cfg['database'], 3306);
if (!$db) {
    http_response_code(503);
    exit("DB DOWN\n");
}

$row = mysqli_fetch_row(mysqli_query($db, "SHOW STATUS LIKE 'wsrep_ready'"));
if (!$row || $row[1] !== 'ON') {
    http_response_code(503);
    exit("GALERA NOT READY\n");
}

if (!is_file('/var/www/wordpress/current/wp-load.php')) {
    http_response_code(503);
    exit("NO RELEASE\n");
}

echo 'OK ' . gethostname() . "\n";
