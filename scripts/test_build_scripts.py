"""构建 / 部署脚本的单元测试：python3 -m unittest discover -s scripts -p 'test_*.py'（CI 的 checks 也跑）。"""

import contextlib
import http.client
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import build_tvos
import deploy_tvos

valid_module = {
    'id': 'hongguo',
    'repo': 'guoapp-modules/hongguo',
    'tag': 'v1.0.2',
    'sha256': {'manifest.json': 'c' * 64, 'main.js': '8' * 64},
}


class TemporaryLock(contextlib.ExitStack):
    """把 build_tvos 的锁文件、模块缓存、fork 目录、核心标记换到临时目录里。"""

    def __init__(self, modules):
        super().__init__()
        self.directory = Path(tempfile.mkdtemp())
        self.callback(shutil.rmtree, self.directory)
        self.lock = self.directory / 'modules.lock.json'
        self.lock.write_text(json.dumps({'modules': modules}))
        self.fork = self.directory / 'fork'
        (self.fork / 'core').mkdir(parents=True)
        (self.fork / 'core' / 'tvos_stream_revive.go').write_text('package core\n')
        self.stamp = self.directory / 'DuanjuCore.variant'
        for name, value in (('modules_lock', self.lock), ('modules_cache', self.directory / 'cache'),
                            ('fork', self.fork), ('core_stamp', self.stamp)):
            self.enter_context(mock.patch.object(build_tvos, name, value))


def module_with(**changes):
    return {**valid_module, **changes}


class LockFileTests(unittest.TestCase):
    def test_valid_lock_is_accepted(self):
        with TemporaryLock([valid_module]):
            self.assertEqual(build_tvos.read_module_lock(), [valid_module])

    def test_values_used_in_paths_and_urls_are_checked(self):
        bad = [
            module_with(id='../hongguo'), module_with(id='Hongguo'), module_with(id='-x'), module_with(id='a' * 33),
            module_with(repo='guoapp-modules'), module_with(repo='guoapp-modules/..'),
            module_with(repo='a/b/c'), module_with(repo='../hongguo'), module_with(repo='owner/name?x=1'),
            module_with(tag='../v1'), module_with(tag='v1/../../x'), module_with(tag='v1..2'), module_with(tag=''),
            module_with(tag=7),
            module_with(sha256={'manifest.json': 'C' * 64, 'main.js': '8' * 64}),
            module_with(sha256={'manifest.json': 'c' * 64}),
            module_with(sha256={'manifest.json': 'c' * 64, 'main.js': '8' * 64, '../x.js': 'a' * 64}),
        ]
        for module in bad:
            with self.subTest(module=module), TemporaryLock([module]), self.assertRaises(SystemExit):
                build_tvos.read_module_lock()

    def test_empty_and_duplicate_locks_are_rejected(self):
        for modules in ([], [valid_module, valid_module]):
            with self.subTest(modules=modules), TemporaryLock(modules), self.assertRaises(SystemExit):
                build_tvos.read_module_lock()

    def test_stamp_lists_id_tag_and_hash_prefixes(self):
        with TemporaryLock([valid_module]):
            self.assertEqual(build_tvos.bundled_modules_stamp(), f'hongguo@v1.0.2:{"c" * 16}:{"8" * 16}')


class DownloadTests(unittest.TestCase):
    def test_broken_downloads_end_with_the_friendly_message(self):
        failures = [http.client.IncompleteRead(b'partial'), ValueError('unknown url type'), OSError('offline')]
        for failure in failures:
            with self.subTest(failure=failure), TemporaryLock([valid_module]), \
                    mock.patch.object(build_tvos.urllib.request, 'urlopen', side_effect=failure), \
                    self.assertRaises(SystemExit) as raised:
                build_tvos.module_file(valid_module, 'main.js')
            self.assertIn('下载站源模块文件失败', str(raised.exception))


class CoreArchiveTests(unittest.TestCase):
    symbols = '0000000000000000 T _DuanjuRequest\n00000000000000b8 T _DuanjuReviveStream\n'

    def test_archive_with_the_overlay_passes(self):
        self.assertEqual(build_tvos.missing_overlay_markers(b'..."/__guoapp_health"...', self.symbols), [])

    def test_archive_without_the_overlay_is_reported(self):
        missing = build_tvos.missing_overlay_markers(b'no patch here', '0000 T _DuanjuRequest\n')
        self.assertEqual(missing, ['_DuanjuReviveStream', '/__guoapp_health'])


class CoreStampTests(unittest.TestCase):
    def test_stamp_covers_lock_and_fork_files(self):
        with TemporaryLock([valid_module]) as context:
            first = build_tvos.core_inputs_fingerprint()
            self.assertEqual(build_tvos.core_inputs_fingerprint(), first)
            (context.fork / 'core' / 'tvos_stream_revive.go').write_text('package core\n// changed\n')
            after_fork = build_tvos.core_inputs_fingerprint()
            self.assertNotEqual(after_fork, first)
            context.lock.write_text(json.dumps({'modules': [module_with(tag='v1.0.3')]}))
            self.assertNotEqual(build_tvos.core_inputs_fingerprint(), after_fork)

    def test_skip_core_rejects_a_stale_or_old_style_stamp(self):
        variant = build_tvos.BuildVariant()
        with TemporaryLock([valid_module]) as context:
            context.stamp.write_text(json.dumps({'variant': variant.slug, 'inputs': build_tvos.core_inputs_fingerprint()}))
            build_tvos.require_core(variant)
            (context.fork / 'patches').mkdir()
            (context.fork / 'patches' / 'app_stream.go.patch').write_text('diff\n')
            with self.assertRaises(SystemExit):
                build_tvos.require_core(variant)
            context.stamp.write_text(variant.slug + '\n')
            with self.assertRaises(SystemExit):
                build_tvos.require_core(variant)


class LaunchTests(unittest.TestCase):
    def launch(self, returncode, stderr=''):
        result = subprocess.CompletedProcess(args=[], returncode=returncode, stdout='', stderr=stderr)
        output = io.StringIO()
        with mock.patch.object(deploy_tvos.subprocess, 'run', return_value=result), contextlib.redirect_stdout(output):
            launched = deploy_tvos.launch_app('DEVICE', 'com.example.tv', 'Bureau')
        return launched, output.getvalue()

    def test_successful_launch(self):
        self.assertEqual(self.launch(0), (True, ''))

    def test_sleeping_tv_is_reported_without_failing(self):
        launched, output = self.launch(1, 'ERROR: The request was denied by service delegate (SBMainWorkspace).\n'
                                          'System is asleep - foreground app launch forbidden\n')
        self.assertFalse(launched)
        self.assertIn('应用已安装到 Bureau', output)
        self.assertIn('foreground app launch forbidden', output)
        self.assertIn('唤醒电视', output)


if __name__ == '__main__':
    unittest.main()
