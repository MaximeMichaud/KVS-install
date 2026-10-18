<?php
/* KVSCTL_CACHE_ROUTING: parse literal settings without executing site code. */
$path = '/var/www/kvs/admin/include/setup.php';
[$unused, $mode, $before, $after] = $argv;
try {
    if (is_link($path) || !is_file($path)) {
        if ($mode === 'inspect') {
            echo json_encode(['host' => '', 'port' => 11211, 'supported' => false]);
            exit(0);
        }
        throw new RuntimeException('setup.php must be a regular file');
    }
    $source = file_get_contents($path);
    if ($source === false) {
        throw new RuntimeException('Cannot read setup.php');
    }
    $tokens = [];
    $offset = 0;
    foreach (token_get_all($source, TOKEN_PARSE) as $token) {
        $text = is_array($token) ? $token[1] : $token;
        $id = is_array($token) ? $token[0] : 0;
        if (!in_array($id, [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            $tokens[] = [$id, $text, $offset];
        }
        $offset += strlen($text);
    }
    $values = [];
    $supported = true;
    $depth = 0;
    foreach ($tokens as $i => $token) {
        if ($token[1] === '{') { $depth++; }
        if ($token[1] === '}') { $depth--; }
        if ($token[0] !== T_VARIABLE || $token[1] !== '$config' || ($tokens[$i + 1][1] ?? '') !== '[') {
            continue;
        }
        $key = $tokens[$i + 2][1] ?? '';
        if (!in_array($key, ["'memcache_server'", '"memcache_server"', "'memcache_port'", '"memcache_port"'], true)) {
            continue;
        }
        // Any duplicate, conditional or computed access makes an automatic
        // rewrite ambiguous. A custom setting remains the operator's choice.
        $name = substr($key, 1, -1);
        $previous = $tokens[$i - 1] ?? [T_OPEN_TAG, '', 0];
        $literal = $tokens[$i + 5] ?? [0, '', 0];
        $plain = $depth === 0 && ($previous[0] === T_OPEN_TAG || $previous[1] === ';');
        $plain = $plain && ($tokens[$i + 3][1] ?? '') === ']' && ($tokens[$i + 4][1] ?? '') === '=';
        $plain = $plain && ($tokens[$i + 6][1] ?? '') === ';' && !isset($values[$name]);
        $raw = $literal[1];
        if ($literal[0] === T_CONSTANT_ENCAPSED_STRING && preg_match('/^[\x27\x22]([a-zA-Z0-9.:-]*)[\x27\x22]$/D', $raw, $matches)) {
            $value = $matches[1];
        } elseif ($name === 'memcache_port' && $literal[0] === T_LNUMBER && ctype_digit($raw)) {
            $value = $raw;
        } else {
            $plain = false;
            $value = '';
        }
        $supported = $supported && $plain;
        $values[$name] = ['value' => $value, 'offset' => $literal[2], 'raw' => $raw];
    }
    $host = $values['memcache_server']['value'] ?? '';
    $port = (int) ($values['memcache_port']['value'] ?? 11211);
    $supported = $supported && isset($values['memcache_server']);
    $relayHost = getenv('KVS_MEMCACHE_HOST');
    $relayPort = getenv('KVS_MEMCACHE_PORT');
    $supported = $supported && ($relayHost === false || $relayHost === '' || $relayHost === 'cache');
    $supported = $supported && ($relayPort === false || $relayPort === '' || $relayPort === '11211');
    if ($mode === 'inspect') {
        echo json_encode(['host' => $host, 'port' => $port, 'supported' => $supported]);
        exit(0);
    }
    if (!in_array($mode, ['apply', 'undo'], true) || !in_array($after, ['cache', 'localhost', '127.0.0.1'], true)) {
        throw new RuntimeException('Invalid cache migration');
    }
    if (!$supported || $port !== 11211 || !in_array($host, [$before, $after], true)) {
        if ($mode === 'undo') {
            echo json_encode(['preserved' => true]);
            exit(0);
        }
        throw new RuntimeException('The cache setting changed after the migration was prepared');
    }
    if ($after === 'cache' && $host !== $after) {
        $cache = new Memcached();
        $cache->setOption(Memcached::OPT_CONNECT_TIMEOUT, 1000);
        $cache->setOption(Memcached::OPT_RECV_TIMEOUT, 1000000);
        $cache->setOption(Memcached::OPT_SEND_TIMEOUT, 1000000);
        $cache->addServer('cache', 11211);
        $key = 'kvsctl:route:' . bin2hex(random_bytes(12));
        $value = bin2hex(random_bytes(12));
        try {
            if (!$cache->set($key, $value, 30) || $cache->get($key) !== $value) {
                throw new RuntimeException('The direct cache connection failed its write/read check');
            }
        } finally {
            $cache->delete($key);
            $cache->quit();
        }
    }
    if ($host !== $after) {
        $setting = $values['memcache_server'];
        $quote = $setting['raw'][0];
        $updated = substr_replace($source, $quote . $after . $quote, $setting['offset'], strlen($setting['raw']));
        $stat = stat($path);
        $temporary = tempnam(dirname($path), '.kvsctl-cache-');
        if ($temporary === false) { throw new RuntimeException('Cannot stage setup.php'); }
        try {
            $file = fopen($temporary, 'wb');
            if ($file === false) { throw new RuntimeException('Cannot open staged setup.php'); }
            try {
                if (fwrite($file, $updated) !== strlen($updated) || !fflush($file) || !fsync($file)) {
                    throw new RuntimeException('Cannot flush staged setup.php');
                }
            } finally { fclose($file); }
            if (!chown($temporary, $stat['uid']) || !chgrp($temporary, $stat['gid']) || !chmod($temporary, $stat['mode'] & 0777)) {
                throw new RuntimeException('Cannot preserve setup.php ownership and permissions');
            }
            if (file_get_contents($path) !== $source || !rename($temporary, $path)) {
                throw new RuntimeException('setup.php changed during the migration');
            }
        } finally { if (is_file($temporary)) { unlink($temporary); } }
    }
    echo '{}';
} catch (Throwable $error) {
    fwrite(STDERR, 'Cache routing: ' . $error->getMessage() . "\n");
    exit(1);
}
