#!/usr/bin/env python3
"""Validate/materialize legacy CLI packages; never execute archive PHP or SQL."""

import argparse
import contextlib
from decimal import Decimal, InvalidOperation
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import unicodedata
import zipfile

CHUNK = 256 * 1024
TEXT_LIMIT = 2 * 1024 * 1024


class InvalidPackage(ValueError):
    """An input cannot be adopted without guessing or unsafe extraction."""


class Members:
    def __init__(self):
        self.names = {}
        self.parents = set()

    def add(self, raw, directory):
        if not isinstance(raw, str) or '\0' in raw or '\\' in raw:
            raise InvalidPackage('an archive member has an unsupported path')
        path = PurePosixPath(raw)
        if path.is_absolute() or re.match(r'^[A-Za-z]:', raw) or '..' in path.parts:
            raise InvalidPackage('an archive member escapes its root')
        name = str(path)
        if name == '.':
            if not directory:
                raise InvalidPackage('the archive root must be a directory')
            if name in self.names:
                raise InvalidPackage('duplicate archive root directory')
            self.names[name] = 'directory'
            return None
        if name in self.names:
            raise InvalidPackage('duplicate archive member: ' + repr(name))
        if not directory and name in self.parents:
            raise InvalidPackage('an archive file replaces a parent directory')
        for parent in path.parents:
            parent = str(parent)
            if parent == '.':
                continue
            if self.names.get(parent) == 'file':
                raise InvalidPackage('an archive member has a file as its parent')
            self.parents.add(parent)
        self.names[name] = 'directory' if directory else 'file'
        return name


def php_tokens(text):
    """Tokenize literals/comments sufficiently to reject ambiguous assignments."""
    result, i = [], 0
    while i < len(text):
        start, char = i, text[i]
        if char.isspace():
            i += 1
        elif text.startswith(('//', '/*'), i) or char == '#':
            if text.startswith('/*', i):
                end = text.find('*/', i + 2)
                if end < 0:
                    raise InvalidPackage('unterminated PHP comment')
                i = end + 2
            else:
                end = text.find('\n', i)
                i = len(text) if end < 0 else end + 1
        elif char in "'\"`":
            quote, value, dynamic = char, [], char == '`'
            i += 1
            while i < len(text) and text[i] != quote:
                if text[i] == '\\':
                    if i + 1 >= len(text):
                        raise InvalidPackage('unterminated PHP literal')
                    escaped = text[i + 1]
                    if quote == "'":
                        value.append(escaped if escaped in "'\\" else '\\' + escaped)
                    else:
                        escapes = {'n': '\n', 'r': '\r', 't': '\t', '\\': '\\', '"': '"', '$': '$'}
                        if escaped not in escapes:
                            raise InvalidPackage('unsupported escape in PHP configuration literal')
                        value.append(escapes[escaped])
                    i += 2
                else:
                    dynamic = dynamic or (quote == '"' and text[i] == '$')
                    value.append(text[i])
                    i += 1
            if i == len(text):
                raise InvalidPackage('unterminated PHP literal')
            i += 1
            result.append(('dynamic' if dynamic else 'string', ''.join(value), start, i))
        elif text.startswith('<<<', i):
            raise InvalidPackage('heredoc configuration is not a simple PHP literal')
        else:
            match = re.match(r'[A-Za-z_][A-Za-z0-9_]*|===|!==|==|!=|=>|\.=|\+=|-=|<=|>=|.', text[i:])
            token = match.group()
            i += len(token)
            result.append(('code', token, start, i))
    return result


def assignments(text, keys):
    tokens, found = php_tokens(text), {key: [] for key in keys}
    for i in range(len(tokens) - 5):
        values = [token[1] for token in tokens[i:i + 6]]
        if values[:3] != ['$', 'config', '['] or values[4] != ']':
            continue
        key = values[3]
        if key not in found:
            continue
        if values[5] in ['.=', '+=', '-=']:
            raise InvalidPackage('ambiguous PHP configuration assignment: ' + key)
        if values[5] != '=':
            continue
        if i + 7 >= len(tokens) or tokens[i + 6][0] != 'string' or tokens[i + 7][1] != ';':
            raise InvalidPackage('a simple literal PHP assignment is required for ' + key)
        found[key].append((tokens[i + 6][1], tokens[i][2], tokens[i + 7][3]))
    for key, values in found.items():
        if len(values) > 1:
            raise InvalidPackage('ambiguous repeated PHP assignment: ' + key)
    return found


def read_text(data, label):
    if len(data) > TEXT_LIMIT:
        raise InvalidPackage(label + ' exceeds the configuration size limit')
    return data.decode('utf-8')


def safe_mode(mode, default):
    if mode & 0o6000:
        raise InvalidPackage('setuid/setgid archive members are unsupported')
    return mode & 0o777 if mode else default


def content_mtime_ns(member):
    try:
        timestamp = Decimal(member.pax_headers.get('mtime', str(member.mtime)))
    except (InvalidOperation, TypeError) as error:
        raise InvalidPackage('invalid content modification time') from error
    if not timestamp.is_finite() or not -(1 << 63) <= timestamp < (1 << 63):
        raise InvalidPackage('invalid content modification time')
    return int(timestamp * 1000000000)


def copy_bytes(source, destination=None):
    count = 0
    while True:
        chunk = source.read(CHUNK)
        if not chunk:
            return count
        count += len(chunk)
        if destination is not None:
            destination.write(chunk)


def read_application(source, www, modes):
    members, texts, total = Members(), {}, 0
    wanted = {'admin/include/setup.php', 'admin/include/setup_db.php', 'admin/include/version.php'}
    signature = None
    with zipfile.ZipFile(source) as archive:
        for member in archive.infolist():
            mode = member.external_attr >> 16
            kind = stat.S_IFMT(mode)
            directory = member.is_dir() or kind == stat.S_IFDIR
            if kind not in [0, stat.S_IFREG, stat.S_IFDIR] or member.flag_bits & 1:
                raise InvalidPackage('application ZIP contains a link, special or encrypted member')
            name = members.add(member.orig_filename, directory)
            if name is None:
                continue
            if name in ['metadata.json', 'database.sql.zst']:
                raise InvalidPackage('application ZIP contains reserved package metadata/SQL')
            target = www / name if www is not None else None
            if directory:
                if member.file_size != 0:
                    raise InvalidPackage('an application directory contains file data')
                if target is not None:
                    target.mkdir(parents=True, exist_ok=True)
                    modes[target] = safe_mode(mode, 0o755)
                continue
            if target is not None:
                target.parent.mkdir(parents=True, exist_ok=True)
            cached = bytearray()
            with archive.open(member) as stream, (target.open('wb') if target is not None else contextlib.nullcontext()) as output:
                size = 0
                while True:
                    chunk = stream.read(CHUNK)
                    if not chunk:
                        break
                    size += len(chunk)
                    if output is not None:
                        output.write(chunk)
                    if name in wanted:
                        cached.extend(chunk)
                        if len(cached) > TEXT_LIMIT:
                            raise InvalidPackage('application configuration is too large')
                    elif name == 'admin/include/functions_base.php' and len(cached) < 4096:
                        cached.extend(chunk[:4096 - len(cached)])
                if size != member.file_size:
                    raise InvalidPackage('truncated application ZIP member')
                total += size
            if name in wanted:
                texts[name] = read_text(cached, name)
            elif name == 'admin/include/functions_base.php':
                signature = bytes(cached)
            if target is not None:
                modes[target] = safe_mode(mode, 0o644)
    if set(texts) != wanted:
        raise InvalidPackage('application ZIP is missing setup.php, setup_db.php or version.php')
    version = assignments(texts['admin/include/version.php'], ['project_version'])['project_version']
    if not version:
        raise InvalidPackage('application version.php has no literal project_version')
    ioncube = 'unknown' if signature is None else 'no'
    if signature is not None and (re.match(rb'\s*<\?php\s+//[0-9a-f]{5,6}', signature)
                                  or b"extension_loaded('ionCube Loader')" in signature or b'_il_exec' in signature):
        ioncube = 'yes'
    return texts['admin/include/setup.php'], version[0][0], ioncube, total


def count_database(source, destination):
    process = subprocess.Popen(['zstd', '-q', '-d', '-c'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    errors = []

    def feed():
        try:
            with destination.open('wb') if destination is not None else contextlib.nullcontext() as output:
                while True:
                    chunk = source.read(CHUNK)
                    if not chunk:
                        break
                    if output is not None:
                        output.write(chunk)
                    process.stdin.write(chunk)
        except Exception as error:
            errors.append(error)
        finally:
            with contextlib.suppress(BrokenPipeError):
                process.stdin.close()

    feeder = threading.Thread(target=feed, daemon=True)
    feeder.start()
    try:
        total = copy_bytes(process.stdout)
        code = process.wait()
        feeder.join()
        if code != 0 or errors or total == 0:
            raise InvalidPackage('database.sql.zst is empty, invalid or truncated')
        return total
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
        process.stdout.close()
        feeder.join(timeout=2)


def json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidPackage('duplicate JSON metadata key')
        result[key] = value
    return result


def read_package(source, www, database, modes, mtimes):
    process = subprocess.Popen(['zstd', '-q', '-d', '-c'], stdin=source, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    members, metadata, sql_bytes, content_bytes, content_files, included = Members(), None, 0, 0, 0, False
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                if member.type not in [tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE] or member.sparse is not None or member.size < 0:
                    raise InvalidPackage('package contains a link, sparse or special member')
                name = members.add(member.name, member.isdir())
                if name is None:
                    continue
                if name not in ['metadata.json', 'database.sql.zst', 'content'] and not name.startswith('content/'):
                    raise InvalidPackage('unexpected member outside metadata, database and content')
                if name.startswith('content/') or name == 'content':
                    included = True
                    timestamp = content_mtime_ns(member)
                    target = www / 'contents' / name[len('content/'): ] if www is not None and name != 'content' else (www / 'contents' if www is not None else None)
                    if target is not None:
                        mtimes[target] = timestamp
                    if member.isdir():
                        if member.size != 0:
                            raise InvalidPackage('a package directory contains file data')
                        if target is not None:
                            target.mkdir(parents=True, exist_ok=True)
                            modes[target] = safe_mode(member.mode, 0o755)
                    else:
                        if name == 'content':
                            raise InvalidPackage('content must be a directory')
                        if target is not None:
                            target.parent.mkdir(parents=True, exist_ok=True)
                        with archive.extractfile(member) as stream, (target.open('wb') if target is not None else contextlib.nullcontext()) as output:
                            actual = copy_bytes(stream, output)
                        if actual != member.size:
                            raise InvalidPackage('truncated content member')
                        content_bytes += actual
                        content_files += 1
                        if target is not None:
                            modes[target] = safe_mode(member.mode, 0o644)
                elif member.isdir():
                    raise InvalidPackage('metadata and database must be regular files')
                elif name == 'metadata.json':
                    if member.size > TEXT_LIMIT:
                        raise InvalidPackage('package metadata is too large')
                    with archive.extractfile(member) as stream:
                        raw = stream.read(TEXT_LIMIT + 1)
                    if len(raw) != member.size:
                        raise InvalidPackage('truncated package metadata')
                    metadata = json.loads(read_text(raw, 'metadata'), object_pairs_hook=json_object,
                                          parse_constant=lambda value: (_ for _ in ()).throw(InvalidPackage('invalid JSON constant')))
                else:
                    with archive.extractfile(member) as stream:
                        sql_bytes = count_database(stream, database)
            # tarfile accepts missing end records; CLI packages must contain both.
            if archive.fileobj.tell() != archive.offset + 512 or archive.fileobj.read(512) != b'\0' * 512:
                raise InvalidPackage('truncated tar end records')
            trailer_bytes = 0
            while True:
                chunk = archive.fileobj.read(CHUNK)
                if not chunk:
                    break
                trailer_bytes += len(chunk)
                if chunk.strip(b'\0') or trailer_bytes > 1024 * 1024:
                    raise InvalidPackage('unexpected data after the tar end records')
        if process.wait() != 0:
            raise InvalidPackage('invalid or truncated outer Zstandard package')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
        process.stdout.close()
    return metadata, sql_bytes, content_bytes, content_files, included


def validate_metadata(metadata, version, included, sql_bytes):
    if not isinstance(metadata, dict) or metadata.get('version') != '1.0':
        raise InvalidPackage('only metadata version 1.0 is supported')
    if metadata.get('kvs_version') != version or not isinstance(version, str) or not version:
        raise InvalidPackage('metadata KVS version does not match application version.php')
    prefix, source = metadata.get('table_prefix'), metadata.get('source_path')
    if not isinstance(prefix, str) or not re.fullmatch(r'[A-Za-z0-9_]{1,32}', prefix):
        raise InvalidPackage('metadata table_prefix must contain 1 to 32 identifier characters')
    if not isinstance(source, str) or not source.startswith('/') or source == '/':
        raise InvalidPackage('metadata source_path must be an absolute, non-root path')
    if any(unicodedata.category(char) == 'Cc' for char in source + version) or any(char in source for char in "'\"\\"):
        raise InvalidPackage('source_path quotes, backslashes and controls cannot be represented by the shared PHP reader')
    if '..' in PurePosixPath(source).parts:
        raise InvalidPackage('metadata source_path contains parent traversal')
    source.encode('utf-8')
    database, content = metadata.get('database'), metadata.get('content')
    if not isinstance(database, dict) or database.get('file') != 'database.sql.zst' or not sql_bytes:
        raise InvalidPackage('metadata must name the existing database.sql.zst payload exactly')
    if not isinstance(content, dict) or type(content.get('included')) is not bool or content['included'] != included:
        raise InvalidPackage('content.included does not match the actual content members')
    return source, prefix


def adapt_setup(setup, source, prefix):
    fields = assignments(setup, ['project_path', 'tables_prefix', 'tables_prefix_multi'])
    if not fields['project_path'] or not fields['tables_prefix']:
        raise InvalidPackage('setup.php needs literal project_path and tables_prefix assignments')
    changes = []
    for key, value in [('project_path', source), ('tables_prefix', prefix), ('tables_prefix_multi', prefix)]:
        replacement = "\n$config['" + key + "']='" + value + "';\n"
        if fields[key]:
            _, start, end = fields[key][0]
            changes.append((start, end, replacement))
        else:
            _, _, end = fields['tables_prefix'][0]
            changes.append((end, end, replacement))
    for start, end, replacement in sorted(changes, reverse=True):
        setup = setup[:start] + replacement + setup[end:]
    return setup


def file_identity(stream):
    entry = os.fstat(stream.fileno())
    return entry.st_dev, entry.st_ino, entry.st_size, entry.st_mtime_ns, entry.st_ctime_ns


def remove_owned_tree(path):
    """Copied directory modes must not prevent removal of our own stage."""
    if path.is_symlink() or not path.is_dir():
        path.unlink()
        return
    path.chmod(0o700)
    with os.scandir(path) as entries:
        for entry in entries:
            remove_owned_tree(Path(entry.path))
    path.rmdir()


def materialize(package, application, stage):
    private, published, modes, mtimes = None, {}, {}, {}
    if stage is not None:
        absolute = Path(os.path.abspath(stage))
        if absolute != absolute.resolve(strict=True) or not absolute.is_dir():
            raise InvalidPackage('stage must be an existing directory without symbolic links')
        entry = absolute.stat()
        if entry.st_uid != os.geteuid() or entry.st_mode & 0o022 or any(absolute.iterdir()):
            raise InvalidPackage('stage must be empty and privately writable by its owner')
        stage = absolute
        private = Path(tempfile.mkdtemp(prefix='.cli-package-', dir=stage))
    try:
        if private is not None:
            (private / 'www').mkdir()
        with open(package, 'rb') as package_file, open(application, 'rb') as application_file:
            original = file_identity(package_file), file_identity(application_file)
            www = private / 'www' if private is not None else None
            database = private / 'database.sql.zst' if private is not None else None
            setup, version, ioncube, app_bytes = read_application(application_file, www, modes)
            metadata, sql_bytes, content_bytes, content_files, included = read_package(package_file, www, database, modes, mtimes)
            source, prefix = validate_metadata(metadata, version, included, sql_bytes)
            adapted = adapt_setup(setup, source, prefix)
            if original != (file_identity(package_file), file_identity(application_file)):
                raise InvalidPackage('an input archive changed while it was being read')
            if www is not None:
                (www / 'admin/include/setup.php').write_text(adapted, encoding='utf-8')
                os.chmod(database, 0o600)
                # Restore times after child writes, while every parent is still accessible.
                for path, timestamp in sorted(mtimes.items(), key=lambda item: len(item[0].parts), reverse=True):
                    try:
                        os.utime(path, ns=(path.lstat().st_atime_ns, timestamp), follow_symlinks=False)
                    except OverflowError as error:
                        raise InvalidPackage('content modification time is unsupported by the destination') from error
                    if path.lstat().st_mtime_ns != timestamp:
                        raise InvalidPackage('content modification time is unsupported by the destination')
                for path, mode in sorted(modes.items(), key=lambda item: len(item[0].parts), reverse=True):
                    os.chmod(path, mode)
                if {path.name for path in stage.iterdir()} != {private.name}:
                    raise InvalidPackage('stage changed during preparation; refusing publication')
                for name in ['www', 'database.sql.zst']:
                    origin, destination = private / name, stage / name
                    identity = origin.lstat()
                    published[destination] = identity.st_dev, identity.st_ino
                    if os.path.lexists(destination):
                        raise InvalidPackage('stage publication target already exists')
                    os.rename(origin, destination)
                remove_owned_tree(private)
                private = None
            return [version, source, prefix, 'yes' if included else 'no',
                    str(max(1, math.ceil((app_bytes + sql_bytes + content_bytes) / 1048576))), ioncube]
    except BaseException as error:
        cleanup_errors = []
        for path, identity in published.items():
            try:
                if os.path.lexists(path):
                    current = path.lstat()
                    if (current.st_dev, current.st_ino) != identity:
                        raise InvalidPackage('output ownership changed: ' + str(path))
                    remove_owned_tree(path)
            except (OSError, InvalidPackage) as cleanup_error:
                cleanup_errors.append(str(cleanup_error))
        if private is not None and os.path.lexists(private):
            try:
                remove_owned_tree(private)
            except OSError as cleanup_error:
                cleanup_errors.append(str(cleanup_error))
        if cleanup_errors:
            raise InvalidPackage('preparation failed; cleanup failed and manual cleanup is required: '
                                 + '; '.join(cleanup_errors)) from error
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['inspect', 'prepare'])
    parser.add_argument('package')
    parser.add_argument('application')
    parser.add_argument('stage', nargs='?')
    arguments = parser.parse_args()
    if (arguments.action == 'prepare') != (arguments.stage is not None):
        raise InvalidPackage('prepare requires an empty stage; inspect takes no stage')
    result = materialize(arguments.package, arguments.application, arguments.stage)
    if arguments.action == 'inspect':
        print('\t'.join(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, EOFError, tarfile.TarError, zipfile.BadZipFile, RuntimeError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('ERROR: package preparation interrupted.', file=sys.stderr)
        sys.exit(130)
