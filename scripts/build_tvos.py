import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

from app_build import BuildVariant, add_variant_argument, variant_from

root = Path(__file__).resolve().parents[1]
project = root / 'tvos' / 'GuoAppTV' / 'GuoAppTV.xcodeproj'
app_name = 'GuoAppTV'
# Go 核心在上游仓库的 native/ 目录；上游整仓以 git submodule 形式
# 放在 upstream/（见 .gitmodules），核心路径即 upstream/native。
core = root / 'upstream' / 'native'
# 记下 xcframework 是为哪个版本编的，复用已编好的核心时据此拒绝装错版本。
core_stamp = root / 'tvos' / 'DuanjuCore' / 'DuanjuCore.variant'
# 本仓库对核心的改动：fork/core、fork/bridge 里是新增的 Go 文件，fork/patches 里是对核心原有文件的补丁
# （文件名即 native/core 下的目标文件）。编译时用 go build -overlay 叠加：新增文件直接映射，
# 打过补丁的副本生成在 upstream/native/build/tvos/patched 里替换原文件，upstream/ 子模块本身不改。
fork = root / 'fork'
# 内置站源模块：仓库与版本、文件的 sha256 记在 tvos/modules.lock.json。构建时下载到 build/modules
# （模块仓库没有许可证，模块文件不进本仓库），校验后放进核心的 native/core/bundled/<标识>/，由 go:embed 编进核心。
modules_lock = root / 'tvos' / 'modules.lock.json'
modules_cache = root / 'build' / 'modules'
bundled_modules = core / 'core' / 'bundled'
module_files = ('manifest.json', 'main.js')


def run(arguments, **kwargs):
    subprocess.run(arguments, cwd=kwargs.pop('cwd', root), check=True, **kwargs)


def validate_unsigned_application(application):
    executable = application / app_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise SystemExit('tvOS 包缺少可执行的 GuoAppTV。')
    run(['xcrun', 'lipo', str(executable), '-verify_arch', 'arm64'])
    if (application / 'embedded.mobileprovision').exists():
        raise SystemExit('未签名 tvOS 包不应包含 provisioning profile。')
    signature = subprocess.run(['codesign', '-d', str(application)],
                               capture_output=True, text=True)
    if signature.returncode == 0 or 'not signed at all' not in signature.stderr:
        raise SystemExit('GuoAppTV.app 未通过无签名检查：' + signature.stderr)


def validate_package(package, prefix):
    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        for name in [prefix + '/GuoAppTV', prefix + '/Info.plist']:
            if name not in names or archive.getinfo(name).file_size == 0:
                raise SystemExit('tvOS 压缩包缺少必要文件：' + name)
        # 安装工具靠 Info.plist 里的 CFBundleExecutable 找可执行文件；
        # 这里直接读包内 plist 校验，缺失就让 CI 失败，不再产出装不上的包。
        info = plistlib.loads(archive.read(prefix + '/Info.plist'))
        executable = info.get('CFBundleExecutable')
        if not executable:
            raise SystemExit('tvOS 压缩包 Info.plist 缺少 CFBundleExecutable，安装工具无法确定可执行文件。')
        if prefix + '/' + executable not in names:
            raise SystemExit('tvOS 压缩包缺少可执行文件：' + executable)
        print('tvOS 包可执行文件：' + executable)
        corrupt = archive.testzip()
        if corrupt:
            raise SystemExit('tvOS 压缩包损坏：' + corrupt)


def require_core_checkout():
    if not (core / 'core').is_dir():
        raise SystemExit('upstream/ 子模块还没有检出，请先运行 git submodule update --init --recursive。')


def patched_core_files():
    """把 fork/patches 里的补丁打在核心原文件的副本上，返回 {原文件: 打过补丁的副本}。"""
    output = core / 'build' / 'tvos' / 'patched'
    if output.exists():
        shutil.rmtree(output)
    replaced = {}
    for patch in sorted((fork / 'patches').glob('*.patch')):
        relative = Path('core') / patch.name.removesuffix('.patch')
        original = core / relative
        if not original.is_file():
            raise SystemExit(f'补丁 {patch.name} 的目标 upstream/native/{relative} 不存在，请按当前核心重做这个补丁。')
        # 补丁路径相对上游仓库根目录（native/core/…）：在系统临时目录里摆出同样的结构再打，
        # GIT_CEILING_DIRECTORIES 让 git 不把它当成某个仓库的一部分。
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            target = work / 'native' / relative
            target.parent.mkdir(parents=True)
            shutil.copy2(original, target)
            result = subprocess.run(['git', 'apply', str(patch)], cwd=work, capture_output=True, text=True,
                                    env=os.environ | {'GIT_CEILING_DIRECTORIES': str(work.parent)})
            if result.returncode != 0:
                raise SystemExit(f'补丁打不上：{patch.name}，核心改了同一处代码，请按当前核心重做这个补丁'
                                 f'（不要跳过）：\n{result.stderr}')
            copy = output / relative
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, copy)
        replaced[str(original)] = str(copy)
    return replaced


def write_core_overlay():
    """生成 go build / go test 用的 -overlay 文件，返回它的路径。"""
    require_core_checkout()
    replace = {
        str(core / part / source.name): str(source)
        for part in ('core', 'bridge')
        for source in sorted((fork / part).glob('*.go'))
    }
    replace |= patched_core_files()
    directory = core / 'build' / 'tvos'
    directory.mkdir(parents=True, exist_ok=True)
    overlay = directory / 'overlay.json'
    overlay.write_text(json.dumps({'Replace': replace}, indent=2))
    return overlay


def read_module_lock():
    try:
        modules = json.loads(modules_lock.read_text())['modules']
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'读不了 {modules_lock.name}：{error!r}')
    if not isinstance(modules, list) or not modules:
        raise SystemExit(f'{modules_lock.name} 里没有站源模块，核心不能不带站源。')
    for module in modules:
        valid = (isinstance(module, dict)
                 and all(isinstance(module.get(key), str) and module[key] for key in ('id', 'repo', 'tag'))
                 and re.fullmatch(r'[a-z0-9_-]{1,32}', module['id'])
                 and isinstance(module.get('sha256'), dict) and sorted(module['sha256']) == sorted(module_files)
                 and all(re.fullmatch(r'[0-9a-f]{64}', str(value)) for value in module['sha256'].values()))
        if not valid:
            raise SystemExit(f'{modules_lock.name} 的条目无效：{module!r}'
                             f'（要有 id、repo、tag，以及 {"、".join(module_files)} 的 sha256）')
    return modules


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


def module_file(module, name):
    """返回校验过的模块文件：缓存里有且 sha256 对得上就直接用（可离线重编），否则从模块仓库的标签下载。"""
    expected = module['sha256'][name]
    cached = modules_cache / module['id'] / module['tag'] / name
    if cached.is_file() and sha256_of(cached.read_bytes()) == expected:
        return cached
    address = f'https://raw.githubusercontent.com/{module["repo"]}/{module["tag"]}/{name}'
    try:
        with urllib.request.urlopen(address, timeout=60) as response:
            data = response.read()
    except OSError as error:
        raise SystemExit(f'下载站源模块文件失败：{address}（{error}）。联网后重试；下载成功过的文件缓存在 '
                         f'{modules_cache.relative_to(root)}，之后不联网也能构建。')
    actual = sha256_of(data)
    if actual != expected:
        raise SystemExit(f'{address} 的 sha256 是 {actual}，与 {modules_lock.name} 记的 {expected} 不符，'
                         '拒绝使用。确认模块新版本后再改锁文件。')
    cached.parent.mkdir(parents=True, exist_ok=True)
    partial = cached.with_name(cached.name + '.partial')
    partial.write_bytes(data)
    partial.replace(cached)
    return cached


def bundle_modules():
    """按锁文件重建 upstream/native/core/bundled（除 .gitkeep 外先清空），核心编译时把它们编进去。"""
    require_core_checkout()
    modules = read_module_lock()
    bundled_modules.mkdir(exist_ok=True)
    for entry in bundled_modules.iterdir():
        if entry.name == '.gitkeep':
            continue
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()
    for module in modules:
        target = bundled_modules / module['id']
        target.mkdir()
        for name in module_files:
            shutil.copyfile(module_file(module, name), target / name)
        try:
            manifest = json.loads((target / 'manifest.json').read_text())
        except ValueError as error:
            raise SystemExit(f'站源模块 {module["id"]} 的 manifest.json 无效：{error}')
        if not isinstance(manifest, dict) or manifest.get('id') != module['id']:
            raise SystemExit(f'站源模块 {module["id"]} 的 manifest.json 里 id 不是 {module["id"]}，核心不会加载它。')
        print(f'内置站源模块：{module["id"]} {manifest.get("version", "")}（{module["repo"]}@{module["tag"]}）')
    if not any(entry.is_dir() for entry in bundled_modules.iterdir()):
        raise SystemExit('upstream/native/core/bundled 里没有站源模块，编出来的核心没有任何站源，停止构建。')


def go_environment():
    go = shutil.which('go')
    if not go:
        raise SystemExit('请安装 Go 1.26 或更新版本。')
    environment = os.environ.copy()
    environment.setdefault('GOPROXY', 'https://goproxy.cn,direct')
    environment.setdefault('GOSUMDB', 'off')
    return go, environment


def test_core_overlay():
    """在本机跑核心补丁的 Go 测试（名字以 TestTVOS 开头）。"""
    go, environment = go_environment()
    run([go, 'test', '-overlay', str(write_core_overlay()), './core', '-run', 'TestTVOS', '-count=1'],
        cwd=core, env=environment)


def build_core(simulator=False, variant=BuildVariant()):
    if platform.system() != 'Darwin':
        raise SystemExit('tvOS 构建需要 macOS 和完整 Xcode。')
    go, environment = go_environment()
    bundle_modules()
    overlay = write_core_overlay()
    environment['CGO_ENABLED'] = '1'
    environment['GOTOOLCHAIN'] = os.environ.get('GOTOOLCHAIN', 'auto')
    # Go 没有 tvos GOOS：用 GOOS=ios + tvOS SDK 编译是 Go 维护者确认的
    # “最接近 tvOS” 的组合（golang/go#63203），与 iOS 核心同理；
    # CGO 对象与最终链接都必须用 tvOS SDK，否则会报未定义符号
    # （如 _darwin_arm_init_mach_exception_handler）。
    # 注意：GOOS=ios 下 internal/cpu 不检测 ARM64 加密扩展，AES-GCM /
    # SHA-256 走纯 Go 实现，CPU 占用会高于 iOS；如需优化可用 -overlay
    # 替换 cpu_arm64_other.go（sing-box#4486 的做法）。
    slices = [('appletvos', 'arm64', 'arm64-apple-tvos16.0')]
    if simulator:
        slices.extend([
            ('appletvsimulator', 'arm64', 'arm64-apple-tvos16.0-simulator'),
            ('appletvsimulator', 'amd64', 'x86_64-apple-tvos16.0-simulator'),
        ])
    libraries = []
    for sdk, architecture, triple in slices:
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        compiler = subprocess.check_output(['xcrun', '--sdk', sdk, '--find', 'clang'], text=True).strip()
        directory = core / 'build' / 'tvos' / f'{sdk}-{architecture}'
        headers = directory / 'Headers'
        headers.mkdir(parents=True, exist_ok=True)
        output = directory / 'libDuanjuCore.a'
        flags = shlex.join(['-isysroot', sdk_path, '-target', triple])
        build_env = environment | {
            'GOOS': 'ios', 'GOARCH': architecture, 'CC': compiler,
            'CGO_CFLAGS': flags, 'CGO_LDFLAGS': flags,
        }
        run([go, 'build', '-trimpath', '-buildmode=c-archive', '-overlay', str(overlay),
             '-ldflags=' + variant.linker_flags, '-o', str(output), './bridge'], cwd=core, env=build_env)
        shutil.copy2(output.with_suffix('.h'), headers / 'DuanjuCore.h')
        libraries.append((sdk, output, headers))
    arguments = ['xcodebuild', '-create-xcframework']
    device = libraries[0]
    arguments.extend(['-library', str(device[1]), '-headers', str(device[2])])
    if simulator:
        universal = core / 'build' / 'tvos' / 'simulator-universal'
        universal.mkdir(parents=True, exist_ok=True)
        archive = universal / 'libDuanjuCore.a'
        run(['xcrun', 'lipo', '-create', str(libraries[1][1]), str(libraries[2][1]), '-output', str(archive)])
        arguments.extend(['-library', str(archive), '-headers', str(libraries[1][2])])
    framework = root / 'tvos' / 'DuanjuCore' / 'DuanjuCore.xcframework'
    if framework.exists():
        shutil.rmtree(framework)
    run(arguments + ['-output', str(framework)])
    # 桥接头 #import "DuanjuCore.h"：把生成的 C 头文件复制到 Swift 工程目录，
    # 与 GuoAppTV-Bridging-Header.h 同目录，clang 按引号包含规则找到它。
    header = root / 'tvos' / 'GuoAppTV' / 'GuoAppTV' / 'DuanjuCore.h'
    shutil.copy2(device[2] / 'DuanjuCore.h', header)
    core_stamp.write_text(variant.slug + '\n')


def require_core(variant):
    built = core_stamp.read_text().strip() if core_stamp.is_file() else ''
    if built != variant.slug:
        raise SystemExit(f'现有 Go 核心是 {built or "未知"} 版本，与要构建的 {variant.slug} 不符；'
                         '请去掉 --skip-core 重新编译核心。')


def verify_display_name(application, variant):
    # 两个版本共用一个工程，显示名由构建设置写入；这里核对没写错版本。
    with open(application / 'Info.plist', 'rb') as handle:
        display_name = plistlib.load(handle).get('CFBundleDisplayName')
    if display_name != variant.display_name:
        raise SystemExit(f'tvOS 包显示名应为 {variant.display_name}，实际为 {display_name!r}')


def core_revision():
    # 「我的」里显示的核心版本：upstream 子模块当前提交的短哈希；取不到（如下载的 ZIP）时为空。
    result = subprocess.run(
        ['git', '-C', str(root / 'upstream'), 'rev-parse', '--short', 'HEAD'],
        capture_output=True, text=True, check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ''


def bundled_modules_stamp():
    # 内置了哪些模块、哪个版本：「标识@标签:manifest sha 前 16 位:main.js sha 前 16 位」，逗号分隔。
    # 写进 Info.plist 的 GUOAppBundledModules；应用启动时它和上次的不同，就让核心从内置副本重装这些模块
    # （见 tvos/GuoAppTV/GuoAppTV/Core/Logic/BundledModuleRefresh.swift）。
    return ','.join(f'{module["id"]}@{module["tag"]}:{module["sha256"]["manifest.json"][:16]}:'
                    f'{module["sha256"]["main.js"][:16]}' for module in read_module_lock())


def xcode_settings(variant, version):
    # 关于页显示的版本以根目录 VERSION 为准：构建时覆盖工程里的 MARKETING_VERSION；
    # 显示名按版本区分（火龙果短剧 / 真果鉴），作为构建设置在签名前写进 Info.plist；
    # 核心版本（upstream 短哈希）同样写进 Info.plist 的 GUOAppCoreRevision。
    return [
        f'MARKETING_VERSION={version}',
        f'GUOAPP_DISPLAY_NAME={variant.display_name}',
        f'GUOAPP_CORE_REVISION={core_revision()}',
        f'GUOAPP_BUNDLED_MODULES={bundled_modules_stamp()}',
    ]


def resolve_packages(derived):
    # 先解析 SPM 依赖（MPVKit 的 libmpv 二进制）：拉取失败时直接报错，不等到
    # 编译阶段才暴露。只认提交进仓库的 Package.resolved，不让 Xcode 静默改版本。
    run(['xcodebuild', '-project', str(project), '-scheme', app_name, '-derivedDataPath', str(derived),
         '-onlyUsePackageVersionsFromResolvedFile', '-resolvePackageDependencies'])


def read_version():
    # 独立仓用根目录 VERSION 文件；旧 fork 里兼容 pubspec.yaml。
    version_file = root / 'VERSION'
    if version_file.is_file():
        return version_file.read_text().strip()
    return re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.MULTILINE).group(1)


def main():
    parser = argparse.ArgumentParser(description='构建火龙果短剧 / 真果鉴 tvOS 核心和应用')
    parser.add_argument('--core-only', action='store_true')
    parser.add_argument('--simulator', action='store_true', help='额外生成模拟器核心；不启动模拟器')
    parser.add_argument('--export-options', type=Path, help='使用自己的 Xcode 签名配置导出 IPA')
    parser.add_argument('--test-overlay', action='store_true',
                        help='只在本机跑 fork/ 里核心补丁的 Go 测试，不构建')
    add_variant_argument(parser)
    options = parser.parse_args()
    if options.test_overlay:
        test_core_overlay()
        return
    variant = variant_from(options)
    build_core(options.simulator, variant)
    if options.core_only:
        return
    if not project.is_dir():
        raise SystemExit('缺少 tvOS 工程：' + str(project))
    output = root / 'dist' / 'tvos'
    output.mkdir(parents=True, exist_ok=True)
    version = read_version()
    artifacts = []
    derived = root / 'tvos' / 'GuoAppTV' / 'build'
    if options.export_options:
        config = options.export_options.expanduser().resolve()
        if not config.is_file():
            raise SystemExit('ExportOptions.plist 不存在。')
        archive = derived / 'GuoAppTV.xcarchive'
        if archive.exists():
            shutil.rmtree(archive)
        resolve_packages(derived)
        # 注意：xcodebuild 要求 -derivedDataPath 必须配合 -scheme，
        # 用 -target 会直接报错退出（exit 64）。
        run(['xcodebuild', '-project', str(project), '-scheme', app_name,
             '-sdk', 'appletvos', '-configuration', 'Release',
             '-derivedDataPath', str(derived), '-archivePath', str(archive),
             '-onlyUsePackageVersionsFromResolvedFile',
             *xcode_settings(variant, version), 'archive'])
        verify_display_name(archive / 'Products' / 'Applications' / f'{app_name}.app', variant)
        exported = derived / 'export'
        if exported.exists():
            shutil.rmtree(exported)
        run(['xcodebuild', '-exportArchive', '-archivePath', str(archive),
             '-exportOptionsPlist', str(config), '-exportPath', str(exported)])
        for package in exported.glob('*.ipa'):
            destination = output / f'{variant.slug}-{version}-tvos.ipa'
            shutil.copy2(package, destination)
            artifacts.append(destination)
    else:
        resolve_packages(derived)
        run(['xcodebuild', '-project', str(project), '-scheme', app_name,
             '-sdk', 'appletvos', '-configuration', 'Release',
             '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO',
             '-onlyUsePackageVersionsFromResolvedFile',
             *xcode_settings(variant, version), 'build'])
        application = derived / 'Build' / 'Products' / 'Release-appletvos' / f'{app_name}.app'
        validate_unsigned_application(application)
        verify_display_name(application, variant)
        symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(application / app_name)], text=True)
        for symbol in ['_DuanjuRequest', '_DuanjuFree']:
            if symbol not in symbols:
                raise SystemExit('tvOS 包缺少 FFI 入口：' + symbol)
        # IPA 结构为 zip 内 Payload/GuoAppTV.app；Apple TV 需在 Mac 上用 Xcode
        # 签名后安装，未签名包不能直接在设备上安装。
        payload = output / 'Payload'
        if payload.exists():
            shutil.rmtree(payload)
        payload.mkdir(parents=True)
        shutil.copytree(application, payload / application.name, symlinks=True)
        ipa = output / f'{variant.slug}-{version}-tvos-unsigned.ipa'
        if ipa.exists():
            ipa.unlink()
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(ipa)])
        validate_package(ipa, 'Payload/GuoAppTV.app')
        shutil.rmtree(payload)
        artifacts.append(ipa)
    if not artifacts:
        raise SystemExit('未生成 tvOS 安装包。')
    for artifact in artifacts:
        print(artifact)


if __name__ == '__main__':
    main()
