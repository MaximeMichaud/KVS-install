<?php
/* KVSCTL_CACHE_ROUTING: parse literal settings without executing site code. */
// Only certify simple setup expressions. Unknown calls and indirect access
// can change globals even when the cache keys never appear at the call site.
function readableProbeToken($tokens, $i) {
    [$id, $text] = $tokens[$i];
    if ($id === T_VARIABLE) { return $text !== '$GLOBALS'; }
    if ($id === T_NEW) {
        // Built-in exceptions in setup guards cannot rewrite the settings.
        $class = $tokens[$i + 1] ?? [0, ''];
        return $class[0] === T_STRING && in_array(strtolower($class[1]), ['exception', 'runtimeexception'], true);
    }
    if ($id !== 0) {
        return in_array($id, [
            T_OPEN_TAG, T_CLOSE_TAG, T_IF, T_ELSEIF, T_ELSE, T_ISSET, T_ARRAY, T_THROW,
            T_CONSTANT_ENCAPSED_STRING, T_ENCAPSED_AND_WHITESPACE, T_STRING,
            T_LNUMBER, T_DNUMBER, T_NUM_STRING, T_DIR, T_FILE, T_DOUBLE_ARROW, T_INT_CAST, T_STRING_CAST,
            T_COALESCE, T_BOOLEAN_AND, T_BOOLEAN_OR, T_IS_EQUAL, T_IS_IDENTICAL, T_IS_NOT_IDENTICAL,
        ], true);
    }
    if ($text === '(') {
        [$prev, $name] = $tokens[$i - 1];
        return ($prev === 0 && $name === '=') || in_array($prev, [T_IF, T_ELSEIF, T_ISSET, T_ARRAY], true)
            || ($prev === T_STRING && (($tokens[$i - 2][0] ?? 0) === T_NEW
                || in_array(strtolower($name), ['getenv', 'dirname', 'realpath', 'intval', 'umask', 'error_reporting',
                    'ini_set', 'str_replace', 'strpos', 'trim', 'substr'], true)));
    }
    return in_array($text, ['[', ']', '{', '}', ')', '=', ';', ',', '"', '.', '!', '?', ':', '|', '+', '-', '*', '/'], true);
}

// Check the include search path as well as the sibling that PHP would
// otherwise find beside setup.php. Never execute the version file.
function versionOnlyInclude($dir) {
    $path = $dir . '/version.php';
    $resolved = stream_resolve_include_path('version.php');
    if (($resolved !== false && $resolved !== $path) || realpath($path) !== $path || !is_file($path)) {
        return false;
    }
    $source = @file_get_contents($path, false, null, 0, 8193);
    if ($source === false || strlen($source) > 8192) { return false; }
    $words = [];
    foreach (token_get_all($source, TOKEN_PARSE) as $token) {
        if (is_array($token) && in_array($token[0], [T_COMMENT, T_DOC_COMMENT, T_WHITESPACE], true)) { continue; }
        $words[] = is_array($token) ? $token[1] : $token;
    }
    return count($words) === 8 && trim($words[0]) === '<?php'
        && $words[1] === '$config' && $words[2] === '['
        && in_array($words[3], ["'project_version'", '"project_version"'], true)
        && $words[4] === ']' && $words[5] === '=' && $words[7] === ';'
        && preg_match('/^([\'"])[0-9][a-zA-Z0-9._-]*\1$/D', $words[6]);
}

// A missing or inactive development directory makes the initial guard's
// entire braced body unreachable, including its delegated setup and return.
function skipProbePreamble(&$tokens, $dir) {
    $words = array_column($tokens, 1);
    $i = 1;
    $strict = ['declare', '(', 'strict_types', '=', '1', ')', ';'];
    if (array_slice($words, $i, count($strict)) === $strict) { $i += count($strict); }
    $path = ['$_SERVER', '[', "'KVS_DEV_PATH'", ']'];
    $guard = array_merge(['if', '(', 'isset', '('], $path, [')', '&&', 'is_dir', '('], $path, [')', ')', '{']);
    $devPath = $_SERVER['KVS_DEV_PATH'] ?? '';
    // Relative paths may resolve differently for a web request.
    if (array_slice($words, $i, count($guard)) === $guard
        && ($devPath === '' || ($devPath[0] === '/' && !is_dir($devPath)))) {
        $i += count($guard);
        $depth = 1;
        while ($depth && isset($tokens[$i])) {
            [$id, $text] = $tokens[$i++];
            if (($id === 0 && $text === '{') || $id === T_CURLY_OPEN || $id === T_DOLLAR_OPEN_CURLY_BRACES) { $depth++; }
            if ($id === 0 && $text === '}') { $depth--; }
        }
    }
    if (($tokens[$i][0] ?? 0) === T_INCLUDE_ONCE
        && in_array($words[$i + 1] ?? '', ["'version.php'", '"version.php"'], true)
        && ($words[$i + 2] ?? '') === ';' && versionOnlyInclude($dir)) {
        $i += 3;
    }
    array_splice($tokens, 1, $i - 1);
}

function cacheAnswers($host, $port) {
    $socket = @fsockopen($host === '::1' ? '[::1]' : $host, $port, $errno, $error, 3);
    if (!$socket) { return false; }
    stream_set_timeout($socket, 3);
    fwrite($socket, "version\r\n");
    $line = fgets($socket, 256);
    fclose($socket);
    return is_string($line) && strpos($line, 'VERSION ') === 0;
}

function probeComposeAlias($service, $reason = 'unknown') {
    $status = $service === '' ? 'no-backend' : (cacheAnswers('cache', 11211) ? 'ok' : 'failed');
    echo "alias-$status\n$reason";
    exit;
}

$path = '/var/www/kvs/admin/include/setup.php';
[$unused, $mode, $before, $after] = $argv;
try {
    if (is_link($path) || !is_file($path) || ($mode === 'probe' && realpath($path) !== $path)) {
        if ($mode === 'inspect') {
            echo json_encode(['host' => '', 'port' => 11211, 'supported' => false]);
            exit(0);
        }
        throw new RuntimeException('setup.php must be a regular file');
    }
    $source = @file_get_contents($path);
    if ($source === false) {
        throw new RuntimeException('Cannot read setup.php');
    }
    if ($mode === 'probe') {
        // TOKEN_PARSE alone accepts some files that fail to compile, such
        // as a break outside a loop. Lint the exact bytes we will inspect.
        $lint = proc_open([PHP_BINARY, '-d', 'display_errors=1', '-d', 'log_errors=0', '-l'],
            [['pipe', 'r'], ['pipe', 'w'], ['redirect', 1]], $pipes);
        if (!is_resource($lint)) { throw new RuntimeException('Cannot start PHP lint'); }
        $written = @fwrite($pipes[0], $source);
        fclose($pipes[0]);
        $output = stream_get_contents($pipes[1]);
        fclose($pipes[1]);
        if (proc_close($lint) !== 0 || $written !== strlen($source)) {
            $reason = 'lint-error';
            if (preg_match('/^(?:PHP )?(Parse|Fatal) error: .* in Standard input code on line ([0-9]+)$/msi', $output, $m)) {
                $reason .= ': ' . $m[1] . ' error on line ' . $m[2];
            }
            probeComposeAlias($before, $reason);
        }
    }
    $tokens = [];
    $offset = 0;
    $inString = false;
    foreach (token_get_all($source, TOKEN_PARSE) as $token) {
        $text = is_array($token) ? $token[1] : $token;
        $id = is_array($token) ? $token[0] : 0;
        if ($id === T_START_HEREDOC) { $inString = true; }
        if ($id === 0 && $text === '"') { $inString = !$inString; }
        if (!in_array($id, [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            $tokens[] = [$id, $text, $offset, $inString];
        }
        if ($id === T_END_HEREDOC) { $inString = false; }
        $offset += strlen($text);
    }
    if ($mode === 'probe') { skipProbePreamble($tokens, dirname($path)); }
    $values = [];
    $supported = true;
    $depth = 0;
    foreach ($tokens as $i => $token) {
        if ($mode === 'probe' && !readableProbeToken($tokens, $i)) {
            probeComposeAlias($before);
        }
        // Alternative control flow has no braces for the depth check below.
        // Leave such files alone rather than guessing which branch runs.
        if (in_array($token[0], [T_ENDIF, T_ENDFOR, T_ENDFOREACH, T_ENDWHILE, T_ENDSWITCH, T_ENDDECLARE], true)) {
            $supported = false;
        }
        if ($token[0] === 0 && !$token[3] && $token[1] === '{') { $depth++; }
        if ($token[0] === 0 && !$token[3] && $token[1] === '}') { $depth--; }
        if ($token[0] !== T_VARIABLE || $token[1] !== '$config') {
            continue;
        }
        // Standard setup files initialize an absent array before setting its
        // keys and interpolate paths as "$config[project_path]/...".
        if (($tokens[$i - 2][0] ?? 0) === T_ISSET && ($tokens[$i - 1][1] ?? '') === '('
            && ($tokens[$i + 1][1] ?? '') === ')') {
            continue;
        }
        if ($values === [] && ($tokens[$i + 1][1] ?? '') === '=' && ($tokens[$i + 2][1] ?? '') === '['
            && ($tokens[$i + 3][1] ?? '') === ']' && ($tokens[$i + 4][1] ?? '') === ';') {
            continue;
        }
        if ($values === [] && ($tokens[$i + 1][1] ?? '') === '=' && ($tokens[$i + 2][0] ?? 0) === T_ARRAY
            && ($tokens[$i + 3][1] ?? '') === '(' && ($tokens[$i + 4][1] ?? '') === ')'
            && ($tokens[$i + 5][1] ?? '') === ';') {
            continue;
        }
        if ($token[3] && ($tokens[$i + 1][1] ?? '') === '[' && ($tokens[$i + 2][0] ?? 0) === T_STRING
            && ($tokens[$i + 3][1] ?? '') === ']') {
            continue;
        }
        // Whole-array access can replace or alias the settings. A computed
        // or escaped key could be the cache port even when no plain port
        // assignment is present, so it must not imply the default 11211.
        $key = $tokens[$i + 2][1] ?? '';
        if (($tokens[$i + 1][1] ?? '') !== '[' || ($tokens[$i + 3][1] ?? '') !== ']'
            || ($tokens[$i + 2][0] ?? 0) !== T_CONSTANT_ENCAPSED_STRING || strpos($key, '\\') !== false) {
            $supported = false;
            continue;
        }
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
        if ($mode === 'probe' && (!$plain || isset($values[$name]))) { probeComposeAlias($before); }
        // A negative integer or a string containing non-digits is a
        // literal invalid port. Expressions still use the alias.
        if ($mode === 'probe' && $name === 'memcache_port') {
            $negative = $literal[1] === '-' && ($tokens[$i + 6][0] ?? 0) === T_LNUMBER
                && ($tokens[$i + 7][1] ?? '') === ';';
            $invalidString = $literal[0] === T_CONSTANT_ENCAPSED_STRING && ($tokens[$i + 6][1] ?? '') === ';'
                && strpos($literal[1], '\\') === false && !ctype_digit(substr($literal[1], 1, -1));
            if ($negative || $invalidString) {
                $values[$name] = ['plain' => true, 'value' => ''];
                continue;
            }
        }
        $plain = $plain && ($tokens[$i + 6][1] ?? '') === ';' && !isset($values[$name]);
        $raw = $literal[1];
        if ($literal[0] === T_CONSTANT_ENCAPSED_STRING && preg_match('/^[\x27\x22]([a-zA-Z0-9._:-]*)[\x27\x22]$/D', $raw, $matches)) {
            $value = $matches[1];
        } elseif ($name === 'memcache_port' && $literal[0] === T_LNUMBER && preg_match('/^(0|[1-9][0-9]*)$/D', $raw)) {
            $value = $raw;
        } else {
            $plain = false;
            $value = '';
        }
        $values[$name] = ['plain' => $plain, 'value' => $value, 'offset' => $literal[2], 'raw' => $raw];
    }
    $host = $values['memcache_server']['value'] ?? '';
    $port = (int) ($values['memcache_port']['value'] ?? 11211);
    $supported = $supported && ($values['memcache_server']['plain'] ?? false);
    $plainPort = $values['memcache_port']['plain'] ?? true;
    if ($mode === 'probe') {
        if (!$supported) { probeComposeAlias($before); }
        if ($host === '') { echo 'disabled'; exit; }
        $loopback = in_array($host, ['127.0.0.1', 'localhost', '::1'], true);
        $local = ['cache', $before, $after];
        if ($before === '') {
            // An inactive profile may have no container to inspect. The
            // shipped Compose file names both containers from SITE_PREFIX.
            $prefix = $argv[4] ?? 'kvs';
            $local = array_merge(['cache', 'dragonfly', 'memcached', "$prefix-dragonfly", "$prefix-memcached"], array_slice($argv, 5));
        }
        if (!$loopback && !in_array($host, $local, true)) { probeComposeAlias($before, 'other'); }
        if ($before === '') { echo 'no-backend'; exit; }
        if (!$plainPort) { probeComposeAlias($before); }
        if (!ctype_digit((string) ($values['memcache_port']['value'] ?? '11211')) || $port < 1 || $port > 65535) {
            echo 'invalid-port'; exit;
        }
        if (cacheAnswers($host, $port)) { echo 'ok'; exit; }
        echo $loopback ? 'loopback-failed' : 'failed';
        exit;
    }
    $supported = $supported && $plainPort;
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
    // A new route must work before it is applied. Undo only restores a
    // journaled setting: recovery may still have the backend stopped for a
    // database replay, and verifies services after restarting them.
    if ($mode === 'apply' && $after === 'cache' && $host !== $after) {
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
    if ($mode === 'probe') { probeComposeAlias($before); }
    fwrite(STDERR, 'Cache routing: ' . $error->getMessage() . "\n");
    exit(1);
}
