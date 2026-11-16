from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False

    @property
    def slug(self):
        return 'zhenguojian' if self.all_sources else 'hongguojian'

    @property
    def display_name(self):
        # 主屏显示名，经 Xcode 构建设置 GUOAPP_DISPLAY_NAME 写入 Info.plist（签名前生效）。
        return '真果鉴' if self.all_sources else '火龙果短剧'

    @property
    def arguments(self):
        return ['--all-sources'] if self.all_sources else []

    @property
    def flutter_arguments(self):
        return ['--dart-define=ALL_SOURCES=' + str(self.all_sources).lower()]

    @property
    def linker_flags(self):
        return '-s -w'


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的真果鉴（模块核心暂不支持）；默认构建仅红果的火龙果短剧')


def variant_from(options):
    # 核心的站源由构建时内置的模块决定（tvos/modules.lock.json），目前只有红果。
    if options.all_sources:
        raise SystemExit('模块核心目前只内置红果站源（tvos/modules.lock.json），暂时不能构建真果鉴（--all-sources）。')
    return BuildVariant()
