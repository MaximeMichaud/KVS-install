#!/bin/bash
# Validate legacy packages with real ZIP, tar and Zstandard payloads.
set -euo pipefail

ROOT=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
command -v python3 >/dev/null || { printf 'Python3 is required for this test.\n' >&2; exit 1; }
command -v zstd >/dev/null || { printf 'Zstandard is required for this test.\n' >&2; exit 1; }

python3 - "$ROOT" "$WORK" <<'PY'
import copy
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

sys.dont_write_bytecode = True

ROOT, WORK = map(Path, sys.argv[1:])
BASH, ZSTD = shutil.which('bash'), shutil.which('zstd')
LIB = ROOT / 'docker/lib/import-cli.sh'
SQL = b'CREATE TABLE `legacy_items` (`id` int, `label` text);\nINSERT INTO `legacy_items` VALUES (1, \'synthetic\');\n'


class LegacyPackageTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=WORK)
        self.addCleanup(self.directory.cleanup)
        self.case = Path(self.directory.name)
        self.sources = self.case / 'sources'
        self.sources.mkdir()
        self.outside = self.case / 'outside'
        self.outside.mkdir()
        (self.outside / 'sentinel').write_bytes(b'preserved target')
        self.meta = {'version': '1.0', 'kvs_version': '7.0.0',
                     'source_path': '/srv/source-site', 'table_prefix': 'legacy_',
                     'database': {'file': 'database.sql.zst', 'size': 999999999},
                     'content': {'included': True, 'files': 999999999, 'size': 999999999}}

    def call(self, function, *arguments, path=None):
        environment = os.environ.copy()
        if path is not None:
            environment['PATH'] = str(path)
        return subprocess.run([BASH, '-c', 'set -e; source "$1"; shift; "$@"',
                               'legacy-package-test', str(LIB), function, *map(str, arguments)],
                              cwd=self.case, env=environment, capture_output=True, text=True, timeout=30)

    def compress(self, data):
        return subprocess.run([ZSTD, '-q', '-c'], input=data, capture_output=True, check=True).stdout

    def application(self, additions=(), version='7.0.0', encoded=False, duplicate_version=False, setup=None):
        entries = [('admin/include/setup.php',
                    b"<?php\n$config['project_path']='/srv/default-site';\n$config['tables_prefix']='ktvs_';\n"
                    b"$config['tables_prefix_multi']='ktvs_';\n$config['project_url']='https://example.test';\n"),
                   ('admin/include/setup_db.php', b'<?php // operator-provided application defaults\n'),
                   ('admin/include/version.php',
                    ("<?php file_put_contents('PHP_MUST_NOT_RUN', 'bad');\n$config['project_version']='" + version + "';\n").encode()),
                   ('admin/include/functions_base.php', b'<?php //001ab\n' if encoded else b'<?php // plain PHP\n'),
                   ('index.php', b'<?php // synthetic application\n')]
        if setup is not None:
            entries[0] = (entries[0][0], setup)
        if duplicate_version:
            entries.append(entries[2])
        entries.extend(additions)
        target = self.sources / ('application-' + str(len(list(self.sources.glob('application-*')))) + '.zip')
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
                for name, data in entries:
                    if isinstance(name, zipfile.ZipInfo):
                        archive.writestr(name, data)
                    else:
                        info = zipfile.ZipInfo(name)
                        info.external_attr = (stat.S_IFREG | 0o644) << 16
                        archive.writestr(info, data)
        return target

    def package(self, metadata=None, additions=(), content=True, sql=SQL, db_payload=None, raw_transform=None, metadata_bytes=None, mtimes=None, modes=None):
        metadata = copy.deepcopy(self.meta if metadata is None else metadata)
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode='w', format=tarfile.PAX_FORMAT) as archive:
            entries = [('.', b'', tarfile.DIRTYPE, ''),
                       ('database.sql.zst', self.compress(sql) if db_payload is None else db_payload, tarfile.REGTYPE, '')]
            if content:
                entries.extend([('content', b'', tarfile.DIRTYPE, ''),
                                ('content/media/name with space.bin', b'synthetic media', tarfile.REGTYPE, '')])
            entries.extend(additions)
            entries.append(('metadata.json', json.dumps(metadata).encode() if metadata_bytes is None else metadata_bytes, tarfile.REGTYPE, ''))
            for name, data, kind, link in entries:
                info = tarfile.TarInfo(name)
                info.type, info.linkname = kind, link
                info.mode = 0o750 if kind == tarfile.DIRTYPE else 0o640
                if modes and name in modes:
                    info.mode = modes[name]
                if mtimes and name in mtimes:
                    info.pax_headers['mtime'] = str(mtimes[name])
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        data = raw.getvalue()
        if raw_transform:
            data = raw_transform(data)
        target = self.sources / ('package-' + str(len(list(self.sources.glob('package-*')))) + '.tar.zst')
        target.write_bytes(self.compress(data))
        return target

    def hashes(self):
        return {str(p.relative_to(self.sources)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.sources.iterdir() if p.is_file()}

    def refusal(self, package, application, stage_name='stage'):
        stage = self.case / stage_name
        stage.mkdir()
        before = self.hashes()
        result = self.call('import_cli_inspect', package, application)
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        result = self.call('import_cli_prepare', package, application, stage)
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual([], list(stage.iterdir()))
        self.assertEqual(before, self.hashes())
        self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())

    def test_recognition_is_root_specific_and_does_not_claim_full_site_archives(self):
        listing = self.case / 'listing'
        valid = 'f\t15\t./metadata.json\nf\t20\t./database.sql.zst\nd\t0\t./content\n'
        listing.write_text(valid)
        self.assertEqual(0, self.call('import_cli_archive_is_package', listing).returncode)
        for invalid in ['f\t15\tnested/metadata.json\nf\t20\tdatabase.sql.zst\n',
                        'f\t15\tmetadata.json\n', valid + 'f\t10\t./www/admin/include/setup.php\n']:
            listing.write_text(invalid)
            self.assertNotEqual(0, self.call('import_cli_archive_is_package', listing).returncode)
        package = self.package()
        result = subprocess.run([BASH, '-c', 'set -e; source "$1"; import_archive_list "$2" tar',
                                 'real-native-listing', str(ROOT / 'docker/lib/import.sh'), str(package)],
                                capture_output=True, text=True, check=True)
        listing.write_text(result.stdout)
        self.assertEqual(0, self.call('import_cli_archive_is_package', listing).returncode)

    def test_inspect_and_prepare_validate_real_bytes_and_keep_metadata_out_of_webroot(self):
        sql = SQL + b'-- synthetic uncompressed bytes\n' * 60000
        package, application = self.package(sql=sql), self.application()
        before = self.hashes()
        result = self.call('import_cli_inspect', package, application)
        self.assertEqual(0, result.returncode, result.stderr)
        fields = result.stdout.strip().split('\t')
        self.assertEqual(['7.0.0', '/srv/source-site', 'legacy_', 'yes'], fields[:4])
        self.assertEqual('no', fields[5])
        self.assertEqual(6, len(fields))
        self.assertLess(int(fields[4]), 10)
        self.assertGreaterEqual(int(fields[4]), math.ceil(len(sql) / 1048576))
        stage = self.case / 'stage'
        stage.mkdir()
        result = self.call('import_cli_prepare', package, application, stage)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({'www', 'database.sql.zst'}, {p.name for p in stage.iterdir()})
        self.assertEqual(b'synthetic media', (stage / 'www/contents/media/name with space.bin').read_bytes())
        self.assertEqual(sql, subprocess.run([ZSTD, '-d', '-c', str(stage / 'database.sql.zst')], capture_output=True, check=True).stdout)
        setup = (stage / 'www/admin/include/setup.php').read_text()
        self.assertIn("$config['tables_prefix']='legacy_';", setup)
        self.assertIn("$config['tables_prefix_multi']='legacy_';", setup)
        self.assertIn("$config['project_path']='/srv/source-site';", setup)
        self.assertIn('https://example.test', setup)
        self.assertFalse((stage / 'www/metadata.json').exists())
        self.assertFalse((stage / 'www/database.sql.zst').exists())
        self.assertFalse((self.case / 'PHP_MUST_NOT_RUN').exists())
        self.assertEqual(before, self.hashes())

    def test_database_only_and_empty_included_content_are_distinct_valid_states(self):
        meta = copy.deepcopy(self.meta)
        meta['content']['included'] = False
        package, application = self.package(meta, content=False), self.application(encoded=True)
        result = self.call('import_cli_inspect', package, application)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(['no', 'yes'], [result.stdout.strip().split('\t')[3], result.stdout.strip().split('\t')[5]])
        # A present, empty content directory is valid when inclusion is true.
        empty = self.package(content=False, additions=[('content', b'', tarfile.DIRTYPE, '')])
        result = self.call('import_cli_inspect', empty, application)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('yes', result.stdout.strip().split('\t')[3])

    def test_prepare_preserves_content_mtimes_after_children_and_before_closed_directory_modes(self):
        entries = [('content', b'', tarfile.DIRTYPE, ''),
                   ('content/media', b'', tarfile.DIRTYPE, ''),
                   ('content/media/first.bin', b'first media', tarfile.REGTYPE, ''),
                   ('content/media/sub', b'', tarfile.DIRTYPE, ''),
                   ('content/media/sub/second.bin', b'second media', tarfile.REGTYPE, ''),
                   ('content/closed/data.bin', b'closed directory media', tarfile.REGTYPE, '')]
        times = {'content': '946684800.123456789', 'content/media': '946684900.234567891',
                 'content/media/first.bin': '1577836800.345678912',
                 'content/media/sub': '946685000.456789123',
                 'content/media/sub/second.bin': '-0.125000001',
                 'content/closed/data.bin': '1577836900.567891234'}
        expected_ns = {'content': 946684800123456789, 'content/media': 946684900234567891,
                       'content/media/first.bin': 1577836800345678912,
                       'content/media/sub': 946685000456789123,
                       'content/media/sub/second.bin': -125000001,
                       'content/closed/data.bin': 1577836900567891234}
        directories = ['content', 'content/media', 'content/media/sub']
        package = self.package(content=False, additions=entries, mtimes=times,
                               modes={name: 0o400 for name in directories})
        closed = zipfile.ZipInfo('contents/closed/')
        closed.external_attr = stat.S_IFDIR << 16
        application = self.application([(closed, b'')])
        original = self.hashes()
        inspected = self.call('import_cli_inspect', package, application)
        self.assertEqual(0, inspected.returncode, inspected.stderr)
        stage = self.case / 'timestamp-stage'
        stage.mkdir()
        root = stage / 'www/contents'
        reopen = [root, root / 'media', root / 'media/sub', root / 'closed']
        try:
            result = self.call('import_cli_prepare', package, application, stage)
            self.assertEqual(0, result.returncode, result.stderr)
            for name in directories:
                target = root if name == 'content' else root / name.removeprefix('content/')
                self.assertEqual(0o400, stat.S_IMODE(target.stat().st_mode))
                self.assertEqual(expected_ns[name], target.stat().st_mtime_ns,
                                 'preparing child files must retain the archived directory modification time')
                target.chmod(0o700)
            self.assertEqual(0, stat.S_IMODE((root / 'closed').stat().st_mode))
            (root / 'closed').chmod(0o700)
            for name, data, kind, _ in entries:
                if kind != tarfile.REGTYPE:
                    continue
                target = root / name.removeprefix('content/')
                self.assertEqual(data, target.read_bytes())
                self.assertEqual(0o640, stat.S_IMODE(target.stat().st_mode))
                self.assertEqual(expected_ns[name], target.stat().st_mtime_ns,
                                 'prepared content must keep the exact archived nanosecond modification time')
            self.assertEqual(original, self.hashes())
            self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())
        finally:
            for target in reopen:
                if os.path.lexists(target):
                    target.chmod(0o700)

    def test_malformed_content_mtimes_are_refused_without_publishing_outputs(self):
        application = self.application()
        for index, timestamp in enumerate(['not-a-time', 'NaN', 'Infinity', '-Infinity', '1e999999']):
            with self.subTest(timestamp=timestamp):
                package = self.package(mtimes={'content/media/name with space.bin': timestamp})
                self.refusal(package, application, 'invalid-time-' + str(index))

    def test_shell_metacharacters_are_literal_and_newline_file_counts_are_not_trusted(self):
        meta = copy.deepcopy(self.meta)
        meta['source_path'] = '/srv/old site/$literal/$(touch COMMAND_RAN)/`touch BACKTICK_RAN`'
        meta['content']['files'] = 0
        package = self.package(meta, additions=[('content/media/line\nbreak.txt', b'one real file', tarfile.REGTYPE, '')])
        application = self.application()
        stage = self.case / 'stage'
        stage.mkdir()
        result = self.call('import_cli_prepare', package, application, stage)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(meta['source_path'], (stage / 'www/admin/include/setup.php').read_text())
        self.assertEqual(2, len([p for p in (stage / 'www/contents').rglob('*') if p.is_file()]))
        self.assertFalse((self.case / 'COMMAND_RAN').exists())
        self.assertFalse((self.case / 'BACKTICK_RAN').exists())

    def test_metadata_contract_and_content_presence_fail_without_publication(self):
        application = self.application()
        mutations = [lambda m: m.update(version='2.0'), lambda m: m.update(table_prefix='bad-prefix'),
                     lambda m: m.update(table_prefix='x' * 33), lambda m: m.update(source_path='/'),
                     lambda m: m.update(source_path='/srv/line\nbreak'), lambda m: m.update(source_path='/srv/tab\tpath'),
                     lambda m: m.update(source_path='/srv/escape\x1bpath'), lambda m: m.update(source_path="/srv/quote'path"),
                     lambda m: m.update(source_path='/srv/control\x85path'), lambda m: m.update(source_path='/srv/quote"path'),
                     lambda m: m.update(source_path='/srv/back\\slash'),
                     lambda m: m['database'].update(file='other.sql.zst'), lambda m: m['content'].update(included='true'),
                     lambda m: m['content'].update(included=False)]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                meta = copy.deepcopy(self.meta)
                mutation(meta)
                self.refusal(self.package(meta), application, 'stage-' + str(index))
        self.refusal(self.package(content=False), application, 'absent-content')

    def test_malformed_or_repeated_metadata_is_an_explicit_refusal(self):
        application = self.application()
        for index, raw in enumerate([b'{', b'{"version":"1.0","version":"1.0"}', b'NaN']):
            with self.subTest(index=index):
                self.refusal(self.package(metadata_bytes=raw), application, 'metadata-' + str(index))

    def test_ambiguous_php_configuration_is_rejected_without_execution(self):
        package = self.package()
        for index, setup in enumerate([
                b"<?php $config['project_path']='/srv/default'; $config['tables_prefix']='default_'; $config['tables_prefix']='again_';",
                b"<?php $config['project_path']=getenv('HOME'); $config['tables_prefix']='default_';",
                b"<?php $config['project_path']='/srv/default'; $config['tables_prefix']='default_'; $config['tables_prefix'].='extra';"]):
            with self.subTest(index=index):
                self.refusal(package, self.application(setup=setup), 'setup-' + str(index))
        application = self.application(setup=b"<?php $config['project_path']='/srv/default'; $config['tables_prefix']='default_';")
        stage = self.case / 'valid-setup'
        stage.mkdir()
        result = self.call('import_cli_prepare', package, application, stage)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("$config['tables_prefix_multi']='legacy_';", (stage / 'www/admin/include/setup.php').read_text())

    def test_matching_archive_uses_version_php_not_filename_and_never_executes_php(self):
        package = self.package()
        self.refusal(package, self.application(version='7.0.1'), 'mismatch')
        self.refusal(package, self.application(duplicate_version=True), 'duplicate-version')
        directory = self.case / 'archives'
        directory.mkdir()
        selected = directory / 'KVS_misleading-name.zip'
        shutil.copyfile(self.application(), selected)
        result = self.call('import_cli_application_archive', directory)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(str(selected), result.stdout.strip())
        shutil.copyfile(selected, directory / 'KVS_second.zip')
        self.assertNotEqual(0, self.call('import_cli_application_archive', directory).returncode)
        selected.unlink()
        (directory / 'KVS_second.zip').unlink()
        self.assertNotEqual(0, self.call('import_cli_application_archive', directory).returncode)

    def test_package_paths_links_duplicates_and_file_parents_are_rejected(self):
        application = self.application()
        cases = [[('../outside/sentinel', b'bad', tarfile.REGTYPE, '')],
                 [(str(self.outside / 'sentinel'), b'bad', tarfile.REGTYPE, '')],
                 [('content/link', b'', tarfile.SYMTYPE, str(self.outside))],
                 [('content/link', b'', tarfile.LNKTYPE, '../outside/sentinel')],
                 [('content/fifo', b'', tarfile.FIFOTYPE, '')],
                 [('.', b'', tarfile.DIRTYPE, '')],
                 [('./content/media/name with space.bin', b'duplicate', tarfile.REGTYPE, '')],
                 [('content/parent', b'file', tarfile.REGTYPE, ''), ('content/parent/child', b'bad', tarfile.REGTYPE, '')],
                 [('content/parent/child', b'bad', tarfile.REGTYPE, ''), ('content/parent', b'file', tarfile.REGTYPE, '')],
                 [('content/change', b'file', tarfile.REGTYPE, ''), ('content/change', b'', tarfile.SYMTYPE, str(self.outside))]]
        for index, entries in enumerate(cases):
            with self.subTest(index=index):
                self.refusal(self.package(additions=entries), application, 'package-path-' + str(index))

    def test_application_paths_links_duplicates_and_file_parents_are_rejected(self):
        package = self.package()
        link = zipfile.ZipInfo('contents')
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        cases = [[('../outside/sentinel', b'bad')], [(str(self.outside / 'sentinel'), b'bad')],
                 [(link, str(self.outside).encode())], [('index.php', b'duplicate')],
                 [('admin', b'file parent')], [('contents/change', b'file'), ('contents/change/child', b'bad')]]
        for index, entries in enumerate(cases):
            with self.subTest(index=index):
                self.refusal(package, self.application(entries), 'application-path-' + str(index))

    def test_truncated_outer_inner_and_application_archives_are_rejected(self):
        application = self.application()
        package = self.package()
        package.write_bytes(package.read_bytes()[:-3])
        self.refusal(package, application, 'outer-truncated')
        self.refusal(self.package(db_payload=self.compress(SQL)[:-3]), application, 'database-truncated')
        self.refusal(self.package(db_payload=b'plain text is not zstd'), application, 'database-not-compressed')
        def no_end_blocks(data):
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
                last = archive.getmembers()[-1]
                end = last.offset_data + ((last.size + 511) // 512) * 512
            return data[:end]
        self.refusal(self.package(raw_transform=no_end_blocks), application, 'tar-truncated')
        application.write_bytes(application.read_bytes()[:-20])
        self.refusal(self.package(), application, 'zip-truncated')

    def test_stage_sentinels_and_symlink_targets_are_never_modified(self):
        package, application = self.package(), self.application()
        stage = self.case / 'stage'
        stage.mkdir()
        (stage / 'sentinel').write_bytes(b'preserve existing stage')
        result = self.call('import_cli_prepare', package, application, stage)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([stage / 'sentinel'], list(stage.iterdir()))
        self.assertEqual(b'preserve existing stage', (stage / 'sentinel').read_bytes())
        linked = self.case / 'linked-stage'
        linked.symlink_to(self.outside, target_is_directory=True)
        self.assertNotEqual(0, self.call('import_cli_prepare', package, application, linked).returncode)
        self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())
        self.assertEqual([self.outside / 'sentinel'], list(self.outside.iterdir()))

    def test_preparation_failures_or_interrupt_remove_only_owned_outputs(self):
        spec = importlib.util.spec_from_file_location('legacy_package_private_test', LIB.with_name('import-cli-package.py'))
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        locked = zipfile.ZipInfo('locked/')
        locked.external_attr = (stat.S_IFDIR | 0o400) << 16
        package = self.package()
        application = self.application([(locked, b''), ('locked/data', b'owned bytes')])
        original = self.hashes()
        rename = helper.os.rename
        for index, exception in enumerate([OSError('synthetic second rename refusal'), KeyboardInterrupt()]):
            with self.subTest(index=index):
                stage = self.case / ('publication-' + str(index))
                stage.mkdir()
                def fail_second(source, destination):
                    if Path(destination).name == 'database.sql.zst':
                        raise exception
                    return rename(source, destination)
                try:
                    with mock.patch.object(helper.os, 'rename', side_effect=fail_second):
                        with self.assertRaises(type(exception)):
                            helper.materialize(package, application, stage)
                    self.assertEqual([], list(stage.iterdir()), 'a failed second publication left owned output behind')
                    self.assertEqual(original, self.hashes())
                    self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())
                finally:
                    for path in stage.rglob('*'):
                        if path.is_dir():
                            path.chmod(0o700)
        for index, exception in enumerate([PermissionError('synthetic timestamp refusal'),
                                           OverflowError('synthetic timestamp overflow')]):
            with self.subTest(timestamp_failure=index):
                stage = self.case / ('timestamp-failure-' + str(index))
                stage.mkdir()
                expected_error = type(exception) if index == 0 else helper.InvalidPackage
                try:
                    with mock.patch.object(helper.os, 'utime', side_effect=exception):
                        with self.assertRaises(expected_error):
                            helper.materialize(package, application, stage)
                    self.assertEqual([], list(stage.iterdir()))
                    self.assertEqual(original, self.hashes())
                    self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())
                finally:
                    for target in [stage / 'www', stage / 'www/locked']:
                        if os.path.lexists(target):
                            target.chmod(0o700)

    @unittest.skipIf(os.geteuid() == 0, 'root bypasses filesystem permission checks')
    def test_real_read_and_stage_write_refusals_leave_sources_and_stage_unchanged(self):
        package, application = self.package(), self.application()
        original = self.hashes()
        stage = self.case / 'permission-stage'
        stage.mkdir()
        try:
            for source in [package, application]:
                mode = source.stat().st_mode & 0o777
                source.chmod(0)
                try:
                    for function, arguments in [('import_cli_inspect', (package, application)),
                                                ('import_cli_prepare', (package, application, stage))]:
                        result = self.call(function, *arguments)
                        self.assertNotEqual(0, result.returncode)
                        self.assertIn('ERROR:', result.stderr)
                        self.assertEqual([], list(stage.iterdir()))
                finally:
                    source.chmod(mode)
            stage.chmod(0o500)
            result = self.call('import_cli_prepare', package, application, stage)
            self.assertNotEqual(0, result.returncode)
            self.assertIn('ERROR:', result.stderr)
        finally:
            stage.chmod(0o700)
        self.assertEqual([], list(stage.iterdir()))
        self.assertEqual(original, self.hashes())
        self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())

    def test_missing_dependencies_are_real_refusals_without_automatic_install(self):
        package, application = self.package(), self.application()
        tools = self.case / 'tools'
        tools.mkdir()
        result = self.call('import_cli_inspect', package, application, path=tools)
        self.assertNotEqual(0, result.returncode)
        self.assertIn('python3', result.stderr)
        (tools / 'python3').symlink_to(sys.executable)
        result = self.call('import_cli_inspect', package, application, path=tools)
        self.assertNotEqual(0, result.returncode)
        self.assertIn('zstd', result.stderr)
        self.assertEqual(b'preserved target', (self.outside / 'sentinel').read_bytes())


unittest.main(argv=['legacy-package-tests'], verbosity=2)
PY
