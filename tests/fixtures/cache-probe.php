<?php
// Synthetic cache operations shared by real FPM requests and cron ticks.
require '/var/www/kvs/admin/include/setup.php';

function check_cache($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

try {
    $host = $_GET['host'] ?? ($argv[1] ?? $config['memcache_server']);
    $cache = new Memcached();
    $cache->setOption(Memcached::OPT_CONNECT_TIMEOUT, 1000);
    $cache->setOption(Memcached::OPT_RECV_TIMEOUT, 1000000);
    $cache->setOption(Memcached::OPT_SEND_TIMEOUT, 1000000);
    check_cache($cache->addServer($host, (int) $config['memcache_port']), 'addServer failed');
    $stats = $cache->getStats();
    check_cache(is_array($stats) && count($stats) === 1 && reset($stats) !== false, 'audit stats failed');

    // An optional, locally extracted KVS audit block can be tested as well.
    foreach (glob('/fixture/audit-*.php') as $audit) {
        $audit_messages = [];
        require $audit;
        check_cache($audit_messages === [], 'KVS audit reported a cache error');
    }

    // These shared fixture keys live only in the disposable backend container.
    check_cache($cache->set('kvs_cache_fixture_' . PHP_SAPI, 'shared-runtime', 120), 'runtime write failed');
    $peer_runtime = $cache->get('kvs_cache_fixture_' . (PHP_SAPI === 'cli' ? 'fpm-fcgi' : 'cli'));

    $prefix = 'kvs_cache_fixture_' . bin2hex(random_bytes(8));
    $keys = [];
    $timings = [];
    try {
        foreach (['simple' => 'test', 'page' => str_repeat('cached page ', 4096)] as $kind => $value) {
            $key = $prefix . $kind;
            $keys[] = $key;
            $start = hrtime(true);
            for ($i = 0; $i < 50; $i++) {
                check_cache($cache->set($key, $value, 60), "$kind set failed");
                check_cache($cache->get($key) === $value, "$kind get failed");
            }
            $timings[$kind . '_pair_ms'] = (hrtime(true) - $start) / 1000000 / 50;
        }
        $items = [];
        for ($i = 0; $i < 100; $i++) {
            $key = $prefix . $i;
            $keys[] = $key;
            $items[$key] = "value-$i";
        }
        check_cache($cache->setMulti($items, 60), 'setMulti failed');
        $start = hrtime(true);
        $actual = $cache->getMulti(array_keys($items));
        $timings['first_multi_get_ms'] = (hrtime(true) - $start) / 1000000;
        check_cache(is_array($actual) && count($actual) === 100, 'getMulti is incomplete');
        foreach ($items as $key => $value) {
            check_cache(($actual[$key] ?? null) === $value, 'getMulti returned an incorrect value');
        }
        $writer = $prefix . 'shared';
        $keys[] = $writer;
        check_cache($cache->set($writer, 'shared-value', 60), 'shared write failed');
        if (($_GET['legacy'] ?? ($argv[2] ?? 'yes')) !== 'no') {
            $peer = new Memcached();
            check_cache($peer->addServer($host === 'cache' ? '127.0.0.1' : 'cache', 11211), 'peer addServer failed');
            check_cache($peer->get($writer) === 'shared-value', 'direct and legacy routes must share the backend');
            $peer->quit();
        }
    } finally {
        $cache->deleteMulti($keys);
        check_cache($cache->getMulti($keys) === [], 'fixture cleanup failed');
        $cache->quit();
    }
    header('Content-Type: application/json');
    echo json_encode(['ok' => true, 'host' => $host, 'sapi' => PHP_SAPI,
        'audit' => true, 'peer_runtime' => $peer_runtime, 'timings' => $timings], JSON_THROW_ON_ERROR) . "\n";
} catch (Throwable $error) {
    http_response_code(500);
    error_log($error->getMessage());
    echo json_encode(['ok' => false, 'error' => $error->getMessage()]) . "\n";
    exit(1);
}
