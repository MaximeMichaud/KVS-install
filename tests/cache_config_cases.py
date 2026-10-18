"""Exercise the actual embedded PHP helper without running site code."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = (ROOT / "cli/internal/upgrade/cache_config.php").read_text().removeprefix("<?php\n")


class CacheConfigTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="cache-config-")
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name) / "setup.php"
        self.code = HELPER.replace("'/var/www/kvs/admin/include/setup.php'", repr(str(self.path)))

    def invoke(self, source, mode="inspect", before="", after=""):
        self.path.write_text(source)
        result = subprocess.run(["php", "-r", self.code, "--", mode, before, after],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_inspect_never_executes_site_code(self):
        source = "<?php\n$config['memcache_server'] = '127.0.0.1';\nthrow new Exception('site code must not run');\n"
        self.assertEqual(self.invoke(source), {"host": "127.0.0.1", "port": 11211, "supported": True})
        self.assertEqual(self.path.read_text(), source)

    def test_rewrite_preserves_unrelated_bytes_owner_and_mode(self):
        source = '''<?php
// A comment with $config['memcache_server'] = 'ignored';
$config [ "memcache_server" ] = "cache"; // keep this
$config['memcache_port'] = 11211;
$config['unrelated'] = 'keep this value';
'''
        self.path.write_text(source)
        self.path.chmod(0o640)
        original = self.path.stat()
        result = subprocess.run(["php", "-r", self.code, "--", "undo", "cache", "localhost"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_text(), source.replace('= "cache"', '= "localhost"'))
        current = self.path.stat()
        self.assertEqual((current.st_mode, current.st_uid, current.st_gid),
                         (original.st_mode, original.st_uid, original.st_gid))
        self.assertEqual(list(self.path.parent.glob(".kvsctl-cache-*")), [])

    def test_ambiguous_settings_are_not_eligible(self):
        cases = [
            "$config['memcache_server'] = getenv('CACHE_HOST');",
            "$config['memcache_server'] = '127.0.0.1'; $config['memcache_server'] = 'custom';",
            "if (false) { $config['memcache_server'] = '127.0.0.1'; }",
            "if (false) $config['memcache_server'] = '127.0.0.1';",
            "$config['memcache_server'] = '127.0.0.1'; $config['memcache_port'] = getenv('PORT');",
            "$example = <<<'TEXT'\n$config['memcache_server'] = '127.0.0.1';\nTEXT;",
            "/* $config['memcache_server'] = '127.0.0.1'; */",
        ]
        for settings in cases:
            with self.subTest(settings=settings):
                source = "<?php\n" + settings + "\n"
                self.assertFalse(self.invoke(source)["supported"])
                self.assertEqual(self.path.read_text(), source)

    def test_custom_port_is_reported_and_undo_preserves_it(self):
        source = "<?php\n$config['memcache_server']='cache';\n$config['memcache_port']='11212';\n"
        self.assertEqual(self.invoke(source)["port"], 11212)
        self.invoke(source, "undo", "cache", "localhost")
        self.assertEqual(self.path.read_text(), source)

    def test_undo_preserves_a_new_operator_choice(self):
        source = "<?php\n$config['memcache_server'] = 'custom-cache';\n"
        self.invoke(source, "undo", "cache", "localhost")
        self.assertEqual(self.path.read_text(), source)

    def test_custom_relay_target_is_preserved(self):
        self.path.write_text("<?php\n$config['memcache_server'] = '127.0.0.1';\n")
        result = subprocess.run(["php", "-r", self.code, "--", "inspect", "", ""],
                                env=dict(os.environ, KVS_MEMCACHE_HOST="operator-cache"),
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["supported"])

    def test_already_restored_cache_needs_no_backend_probe(self):
        source = "<?php\n$config['memcache_server'] = 'cache';\n"
        self.invoke(source, "undo", "localhost", "cache")
        self.assertEqual(self.path.read_text(), source)

    def test_undo_restores_direct_cache_without_a_live_backend(self):
        ready = subprocess.run(["php", "-n", "-r",
                                "exit(function_exists('token_get_all') && function_exists('ctype_digit') && function_exists('fsync') ? 0 : 1);"],
                               capture_output=True, check=False)
        if ready.returncode:
            self.skipTest("PHP needs tokenizer, ctype and fsync without extensions")
        source = "<?php\n$config['memcache_server'] = '127.0.0.1';\n"
        self.path.write_text(source)
        # No extensions: restoring a journaled value must not instantiate
        # Memcached while recovery still has the backend stopped.
        result = subprocess.run(["php", "-n", "-r", self.code, "--", "undo", "127.0.0.1", "cache"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_text(), source.replace("'127.0.0.1'", "'cache'"))

    def test_symlinked_setup_is_not_automatically_migrated(self):
        target = self.path.parent / "custom.php"
        target.write_text("<?php\n$config['memcache_server'] = '127.0.0.1';\n")
        self.path.symlink_to(target)
        result = subprocess.run(["php", "-r", self.code, "--", "inspect", "", ""],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["supported"])
        self.assertTrue(self.path.is_symlink())


if __name__ == "__main__":
    unittest.main()
