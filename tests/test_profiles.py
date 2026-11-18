import os
import itertools
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / 'profile.sh'


class ProfileCatalogTest(unittest.TestCase):
    def test_names_are_unique_on_each_platform(self):
        categories = {'windows', 'linux', 'macos', 'unix'}
        for platform in ('windows', 'linux', 'macos'):
            names = []
            for path in ROOT.rglob('*.sh'):
                if path.name.startswith('.'):
                    continue
                category = path.relative_to(ROOT).parts[0]
                if (category not in categories or category == platform
                        or category == 'unix' and platform in ('linux', 'macos')):
                    names.append(path.stem)
            with self.subTest(platform=platform):
                self.assertEqual(len(names), len(set(names)))

    def test_windows_profiles(self):
        names = {path.stem for path in (ROOT / 'windows').rglob('*.sh')}
        self.assertEqual(names, {
            'vs2022', 'vs2022-x86', 'vs2022-clang-cl', 'llvm-mingw', 'zlib',
            'gdk-desktop', 'gdk-xbox-one', 'gdk-scarlett',
            'vs2026',
            'vs2026-clang-cl',
            'vs2026-x86',
            'msvc', 'clang-cl', 'x86', 'x64',
        })

    def test_sources_support_the_preset_platforms(self):
        platforms = {
            'windows': {'windows'}, 'linux': {'linux'}, 'macos': {'macos'},
            'unix': {'linux', 'macos'},
        }

        def supported(path):
            return platforms.get(path.relative_to(ROOT).parts[0],
                                 {'windows', 'linux', 'macos'})

        for path in ROOT.rglob('*.sh'):
            if path.name.startswith('.'):
                continue
            for relative in re.findall(r'source "\$dir/([^"]+)"',
                                       path.read_text(encoding='utf-8')):
                target = ROOT / relative
                with self.subTest(profile=str(path.relative_to(ROOT)),
                                  source=relative):
                    self.assertTrue(target.is_file())
                    self.assertLessEqual(supported(path), supported(target))


class ProfileLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = shutil.which('bash')
        if not cls.bash:
            installed = Path('C:/Program Files/Git/bin/bash.exe')
            if installed.is_file():
                cls.bash = str(installed)
        if not cls.bash:
            raise unittest.SkipTest('Bash is unavailable')
        probe = subprocess.run([cls.bash, '--noprofile', '--norc', '-c',
                                'printf %s "${BASH_VERSINFO[0]}"'],
                               capture_output=True, text=True)
        if probe.returncode:
            raise unittest.SkipTest('Bash cannot start in this sandbox')
        cls.bash_major = int(probe.stdout)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.profile-tests-',
                                                dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.loads = self.root / '.loads'
        self.launcher = self.root / '.launcher'
        self.launcher.write_text(
            LAUNCHER.read_text(encoding='utf-8'),
            encoding='utf-8', newline='\n')
        self.startup = self.root / '.startup'
        self.startup.write_text(
            'OSTYPE=$PROFILE_TEST_OSTYPE\nMSYSTEM=$PROFILE_TEST_MSYSTEM\n',
            encoding='utf-8', newline='\n')
        for relative in ('shared.sh', 'env/cache.sh',
                         'windows/compiler/windows-tool.sh',
                         'linux/compiler/linux-tool.sh',
                         'macos/compiler/mac-tool.sh',
                         'unix/target/unix-tool.sh'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                f'printf "%s\\n" "{path.stem}" >>"$PROFILE_TEST_LOADS"\n',
                encoding='utf-8', newline='\n')

    def run_profile(self, ostype, *args, msystem='', extra_env=None):
        env = dict(os.environ)
        env.update({
            'BASH_ENV': self.startup.as_posix(),
            'PROFILE_TEST_OSTYPE': ostype,
            'PROFILE_TEST_MSYSTEM': msystem,
            'PROFILE_TEST_LOADS': self.loads.as_posix(),
        })
        if extra_env:
            env.update(extra_env)
        return subprocess.run([self.bash, '--noprofile', '--norc',
                               self.launcher.as_posix(), *args],
                              env=env, capture_output=True, encoding='utf-8')

    def test_names_match_the_platform(self):
        for ostype, msystem, names in (
            ('linux-gnu', '', {'linux-tool', 'unix-tool'}),
            ('darwin24', '', {'mac-tool', 'unix-tool'}),
            ('msys', '', {'windows-tool'}),
            ('cygwin', 'MINGW64', {'windows-tool'}),
            ('cygwin', '', set()),
        ):
            with self.subTest(ostype=ostype, msystem=msystem):
                result = self.run_profile(ostype, '--names', msystem=msystem)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(set(result.stdout.splitlines()),
                                 names | {'cache'})
                self.assertEqual(result.stderr, '')
        self.assertFalse(self.loads.exists())

    def test_listing_sources_only_supported_profiles(self):
        result = self.run_profile('cygwin', '--list', msystem='MINGW64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(set(self.loads.read_text().splitlines()),
                         {'cache', 'windows-tool'})
        self.assertTrue(result.stdout.startswith('env ─'), result.stdout)
        self.assertNotIn('preset', result.stdout)
        self.assertIn('windows/compiler ─', result.stdout)
        self.assertNotIn('linux', result.stdout)
        self.assertNotIn('macos', result.stdout)
        self.assertNotIn('unix', result.stdout)
        self.assertNotIn('windows ─', result.stdout)

    def test_unsupported_profile_is_not_sourced(self):
        result = self.run_profile('cygwin', 'linux-tool', '--', 'true',
                                  msystem='MINGW64')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, 'Unknown profile: linux-tool\n')
        self.assertFalse(self.loads.exists())

    def test_supported_profiles_can_be_combined(self):
        result = self.run_profile('linux-gnu', 'linux-tool', 'unix-tool',
                                  '--', self.bash, '-c',
                                  'printf "%s\\n" "$PSPREFIX"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'linux-tool+unix-tool\n')
        self.assertEqual(self.loads.read_text().splitlines(),
                         ['linux-tool', 'unix-tool'])

    def test_android_listing_keeps_companion_checks(self):
        for helper in ('.common.sh', '.windows.sh', '.macos.sh'):
            shutil.copyfile(ROOT / helper, self.root / helper)
        shutil.copytree(ROOT / 'unix', self.root / 'unix', dirs_exist_ok=True)
        env = {'ANDROID_API': '', 'ANDROID_ARCH': '', 'ANDROID_HOME': '',
               'ANDROID_NDK_HOME': ''}
        result = self.run_profile('linux-gnu', '--list', extra_env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = {line.split()[0]: line for line in result.stdout.splitlines()
                if 'missing dependency:' in line or 'requires profile:' in line}
        self.assertIn('android-21', rows)
        self.assertIn('✗ missing dependency:', rows['android-21'])
        self.assertNotIn('requires profile:', rows['android-21'])
        self.assertIn('✗', rows['ndk-23'])
        self.assertIn('requires profile: android-<api>', rows['ndk-23'])
        result = self.run_profile('linux-gnu', '--list', extra_env={
            **env, 'ANDROID_API': '21', 'ANDROID_ARCH': 'x86_64',
        })
        rows = {line.split()[0]: line for line in result.stdout.splitlines()
                if 'missing dependency:' in line or 'requires profile:' in line}
        self.assertNotIn('requires profile:', rows['ndk-23'])

    def test_visual_studio_listing_accepts_version_without_newline(self):
        self.require_git_bash()
        for helper in ('.common.sh', '.windows.sh', '.macos.sh'):
            shutil.copyfile(ROOT / helper, self.root / helper)
        vs = self.root / '.vs'
        metadata = vs / 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
        metadata.parent.mkdir(parents=True)
        metadata.write_text('test', encoding='utf-8')
        (metadata.parent / 'vcvarsall.bat').touch()
        compiler = vs / 'VC/Tools/MSVC/test/bin/Hostx64/x64'
        compiler.mkdir(parents=True)
        for name in ('cl', 'cl.exe'):
            path = compiler / name
            path.touch()
            path.chmod(0o755)
        (self.root / 'windows/compiler/vs2026.sh').write_text(
            'load_windows vs2026\n', encoding='utf-8')
        with self.startup.open('a', encoding='utf-8') as startup:
            startup.write('''
if command -v cygpath >/dev/null 2>&1; then
    PROFILE_TEST_VS_ROOT=$(cygpath -u "$PROFILE_TEST_VS_ROOT")
fi
cygpath() {
    case "$2" in
        *Microsoft*Visual*Studio*18*Community*) printf '%s\\n' "$PROFILE_TEST_VS_ROOT" ;;
        *) printf '%s\\n' "$2" ;;
    esac
}
''')
        result = self.run_profile('cygwin', '--list', msystem='MINGW64',
                                  extra_env={'PROFILE_TEST_VS_ROOT': vs.as_posix()})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        row = next(line for line in result.stdout.splitlines()
                   if line.split()[:1] == ['vs2026'])
        self.assertNotIn('cl', row.partition('missing dependency: ')[2].split(', '))

    def require_git_bash(self):
        if self.bash_major < 4:
            self.skipTest('Git Bash profiles require Bash 4')

    def prepare_windows(self):
        self.require_git_bash()
        shutil.copyfile(ROOT / '.common.sh', self.root / '.common.sh')
        shutil.copyfile(ROOT / '.macos.sh', self.root / '.macos.sh')
        shutil.copyfile(ROOT / '.windows.sh', self.root / '.windows.sh')
        shutil.copytree(ROOT / 'windows', self.root / 'windows', dirs_exist_ok=True)
        shutil.copyfile(ROOT / 'env/sccache.sh', self.root / 'env/sccache.sh')
        self.calls = self.root / '.vcvars-calls'
        self.win_env = {'PROFILE_TEST_VC_CALLS': self.calls.as_posix()}
        for year in ('2022', '2026'):
            vs = self.root / f'.vs{year}'
            self.win_env[f'PROFILE_TEST_VS{year}'] = vs.as_posix()
            metadata = vs / 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
            metadata.parent.mkdir(parents=True)
            metadata.write_text('test', encoding='utf-8')
            (metadata.parent / 'vcvarsall.bat').touch()
            for arch in ('x64', 'x86'):
                compiler = vs / f'VC/Tools/MSVC/test/bin/Hostx64/{arch}'
                compiler.mkdir(parents=True)
                for name in ('cl', 'cl.exe'):
                    path = compiler / name
                    path.touch()
                    path.chmod(0o755)
            compiler = vs / 'VC/Tools/Llvm/x64/bin'
            compiler.mkdir(parents=True)
            for name in ('clang-cl', 'clang-cl.exe'):
                path = compiler / name
                path.touch()
                path.chmod(0o755)
        self.win_env['ZLIB_ROOT'] = (self.root / '.zlib').as_posix()
        zlib = self.root / '.zlib/install'
        for suffix in ('', '-x86', '-vs2026', '-vs2026-x86'):
            path = Path(str(zlib) + suffix)
            (path / 'lib').mkdir(parents=True)
            (path / 'include').mkdir()
            (path / 'lib/zlibstaticd.lib').touch()
            (path / 'include/zlib.h').touch()
        with self.startup.open('a', encoding='utf-8') as startup:
            startup.write('''
if command -v cygpath >/dev/null 2>&1; then
    PROFILE_TEST_VS2022=$(cygpath -u "$PROFILE_TEST_VS2022")
    PROFILE_TEST_VS2026=$(cygpath -u "$PROFILE_TEST_VS2026")
    ZLIB_ROOT=$(cygpath -u "$ZLIB_ROOT")
fi
cygpath() {
    case "$2" in
        *Microsoft*Visual*Studio*2022*Community*) printf '%s\\n' "$PROFILE_TEST_VS2022" ;;
        *Microsoft*Visual*Studio*18*Community*) printf '%s\\n' "$PROFILE_TEST_VS2026" ;;
        *) printf '%s\\n' "$2" ;;
    esac
}
vcvarsall.sh() {
    local root=$(cygpath -u "$VSINSTALLDIR")
    printf '%s %s\\n' "$VSINSTALLDIR" "$1" >>"$PROFILE_TEST_VC_CALLS"
    printf 'export VSINSTALLDIR=%q\\n' "$root/"
    printf 'export VCTOOLSINSTALLDIR=%q\\n' "$root/VC/Tools/MSVC/test/"
}
cmake() { :; }
python() { :; }
sccache() { :; }
''')

    def windows_config(self, *profiles, extra_env=None):
        command = '''printf '%s\\n' "$CC" "$CXX" "$CMAKE_GENERATOR" \
"$CMAKE_GENERATOR_PLATFORM" "${CMAKE_GENERATOR_TOOLSET:-}" \
"${VS_GENERATOR_TOOLSET:-}" "${TEST_X86:-}" "${USE_SCCACHE:-}" "$CMAKE_DEFINES"'''
        result = self.run_profile('cygwin', *profiles, '--', self.bash, '-c',
                                  command, msystem='MINGW64',
                                  extra_env={**self.win_env, **(extra_env or {})})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_windows_layers_are_order_independent(self):
        self.prepare_windows()
        for vs, arch, compiler in itertools.product(
                ('vs2022', 'vs2026'), ('x64', 'x86'), ('msvc', 'clang-cl')):
            for profiles in itertools.permutations((vs, arch, compiler)):
                with self.subTest(profiles=profiles):
                    before = len(self.calls.read_text().splitlines()) if self.calls.exists() else 0
                    values = self.windows_config(*profiles)
                    cc = 'cl' if compiler == 'msvc' else 'clang-cl'
                    generator = 'Visual Studio 17 2022' if vs == 'vs2022' else 'Visual Studio 18 2026'
                    toolset = 'ClangCL' if compiler == 'clang-cl' else ''
                    if arch == 'x86':
                        toolset += (',' if toolset else '') + 'host=x64'
                    self.assertEqual(values[:8], [
                        cc, cc, generator, 'Win32' if arch == 'x86' else 'x64',
                        toolset, 'ClangCL' if compiler == 'clang-cl' else '',
                        '1' if arch == 'x86' else '', '1' if arch == 'x64' else '',
                    ])
                    prefix = 'install' if vs == 'vs2022' else 'install-vs2026'
                    if arch == 'x86':
                        prefix += '-x86'
                    self.assertIn(prefix + '/lib/zlibstaticd.lib', values[8])
                    calls = self.calls.read_text().splitlines()
                    self.assertEqual(len(calls), before + 1)
                    self.assertTrue(calls[-1].endswith(' x64_x86' if arch == 'x86' else ' x64'))

    def test_windows_presets_match_components(self):
        self.prepare_windows()
        for vs in ('vs2022', 'vs2026'):
            with self.subTest(vs=vs):
                self.assertEqual(self.windows_config(vs),
                                 self.windows_config(vs, 'x64', 'msvc'))
                self.assertEqual(self.windows_config(vs + '-x86'),
                                 self.windows_config(vs, 'x86'))
                self.assertEqual(self.windows_config(vs + '-clang-cl'),
                                 self.windows_config(vs, 'clang-cl'))

    def test_conflicting_windows_choices_are_rejected_before_setup(self):
        self.prepare_windows()
        for profiles, choice in (
            (('vs2022', 'vs2026'), 'toolchain'),
            (('vs2026', 'x86', 'x64'), 'architecture'),
            (('vs2026', 'msvc', 'clang-cl'), 'compiler'),
        ):
            with self.subTest(profiles=profiles):
                result = self.run_profile('cygwin', *profiles, '--', 'true',
                                          msystem='MINGW64', extra_env=self.win_env)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f'choose one Windows {choice}:', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_repeated_windows_choices_initialize_once(self):
        self.prepare_windows()
        self.windows_config('vs2026', 'x86', 'clang-cl', 'vs2026', 'x86', 'clang-cl')
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_windows_components_require_a_vs_profile(self):
        self.prepare_windows()
        for component in ('msvc', 'clang-cl', 'x86', 'x64'):
            with self.subTest(component=component):
                result = self.run_profile('cygwin', component, '--', 'true',
                                          msystem='MINGW64', extra_env=self.win_env)
                self.assertEqual(result.returncode, 1)
                self.assertIn('requires profile: vs2022 or vs2026', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_windows_listing_uses_the_active_vs_profile(self):
        self.prepare_windows()
        for active in (False, True):
            env = dict(self.win_env)
            env.update({'CMAKE_GENERATOR': '', 'CMAKE_GENERATOR_PLATFORM': '', 'CC': '', 'CXX': ''})
            if active:
                env.update({'CMAKE_GENERATOR': 'Visual Studio 18 2026',
                            'CMAKE_GENERATOR_PLATFORM': 'Win32',
                            'CC': 'clang-cl', 'CXX': 'clang-cl'})
            result = self.run_profile('cygwin', '--list', msystem='MINGW64', extra_env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            for component in ('msvc', 'clang-cl', 'x86', 'x64'):
                row = next(line for line in result.stdout.splitlines()
                           if line.split()[:1] == [component])
                if active:
                    self.assertTrue(row.endswith('✓'), row)
                else:
                    self.assertIn('✗ requires profile: vs2022 or vs2026', row)
        self.assertFalse(self.calls.exists())

    def test_inherited_windows_choices_are_cleared(self):
        self.prepare_windows()
        inherited = {'CC': 'clang-cl', 'CXX': 'clang-cl', 'TEST_X86': '1',
                     'CMAKE_GENERATOR': 'Visual Studio 18 2026',
                     'CMAKE_GENERATOR_PLATFORM': 'Win32',
                     'CMAKE_GENERATOR_TOOLSET': 'ClangCL,host=x64',
                     'VS_GENERATOR_TOOLSET': 'ClangCL', 'USE_SCCACHE': '1'}
        self.assertEqual(self.windows_config('vs2022', extra_env=inherited),
                         self.windows_config('vs2022'))

    def test_llvm_mingw_and_gdk_reject_incompatible_components(self):
        self.prepare_windows()
        for profiles, message in (
            (('llvm-mingw', 'x86'), 'llvm-mingw selects x64'),
            (('llvm-mingw', 'clang-cl'), 'llvm-mingw selects its compiler'),
            (('gdk-desktop', 'x86'), 'GDK profiles select x64'),
        ):
            with self.subTest(profiles=profiles):
                result = self.run_profile('cygwin', *profiles, '--', 'true',
                                          msystem='MINGW64', extra_env=self.win_env)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_zlib_uses_the_llvm_mingw_library(self):
        self.prepare_windows()
        package = 'llvm-mingw-test-ucrt-x86_64'
        zlib = Path(self.win_env['ZLIB_ROOT']) / 'install-mingw' / package
        (zlib / 'lib').mkdir(parents=True)
        (zlib / 'include').mkdir()
        (zlib / 'lib/libzlibstatic.a').touch()
        (zlib / 'include/zlib.h').touch()
        result = self.run_profile('cygwin', 'zlib', '--', self.bash, '-c',
                                  'printf "%s\\n" "$CMAKE_DEFINES"', msystem='MINGW64',
                                  extra_env={**self.win_env, 'TEST_MINGW': '1',
                                             'LLVM_MINGW_ROOT': '/toolchains/' + package})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(package + '/lib/libzlibstatic.a', result.stdout)
        self.assertNotIn('zlibstaticd.lib', result.stdout)

    def test_zlib_requires_the_matching_llvm_mingw_library(self):
        self.prepare_windows()
        result = self.run_profile('cygwin', 'zlib', '--', 'true', msystem='MINGW64',
                                  extra_env={**self.win_env, 'TEST_MINGW': '1',
                                             'LLVM_MINGW_ROOT': '/toolchains/missing'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('install-mingw/missing/lib/libzlibstatic.a', result.stderr)

    def test_zlib_requires_a_root(self):
        self.prepare_windows()
        result = self.run_profile('cygwin', 'zlib', '--', 'true', msystem='MINGW64',
                                  extra_env={**self.win_env, 'ZLIB_ROOT': ''})
        self.assertEqual(result.returncode, 1)
        self.assertIn('ZLIB_ROOT (Zlib build)', result.stderr)

    def prepare_macos(self):
        for helper in ('.common.sh', '.windows.sh', '.macos.sh'):
            shutil.copyfile(ROOT / helper, self.root / helper)
        for category in ('macos', 'unix'):
            shutil.copytree(ROOT / category, self.root / category,
                            dirs_exist_ok=True)
        self.mac_env = {'PROFILE_TEST_ARCH': 'arm64'}
        for name in ('xcode', 'llvm18'):
            root = self.root / f'.{name}'
            self.mac_env[f'PROFILE_TEST_{name.upper()}'] = root.as_posix()
            (root / 'bin').mkdir(parents=True)
            for tool in ('clang', 'clang++', 'llvm-cov', 'llvm-profdata'):
                executable = root / 'bin' / tool
                executable.write_text('#!/bin/sh\n', encoding='utf-8')
                executable.chmod(0o755)
        sdk = self.root / '.sdk'
        sdk.mkdir()
        self.mac_env['PROFILE_TEST_SDK'] = sdk.as_posix()
        with self.startup.open('a', encoding='utf-8') as startup:
            startup.write('''
if command -v cygpath >/dev/null 2>&1; then
    PROFILE_TEST_XCODE=$(cygpath -u "$PROFILE_TEST_XCODE")
    PROFILE_TEST_LLVM18=$(cygpath -u "$PROFILE_TEST_LLVM18")
    PROFILE_TEST_SDK=$(cygpath -u "$PROFILE_TEST_SDK")
fi
xcrun() {
    case "$*" in
        '--find clang') printf '%s\\n' "$PROFILE_TEST_XCODE/bin/clang" ;;
        '--sdk macosx --show-sdk-path') printf '%s\\n' "$PROFILE_TEST_SDK" ;;
        '--sdk iphonesimulator --show-sdk-path') printf '%s\\n' "$PROFILE_TEST_SDK" ;;
        *) return 1 ;;
    esac
}
brew() {
    [[ $* == '--prefix llvm@18' ]] || return 1
    printf '%s\\n' "$PROFILE_TEST_LLVM18"
}
uname() { printf '%s\\n' "$PROFILE_TEST_ARCH"; }
cmake() { :; }
make() { :; }
python3() { :; }
xcodebuild() { :; }
''')

    def macos_config(self, *profiles, extra_env=None):
        command = '''printf '%s\\n' "${CC:-}" "${CXX:-}" "${SDKROOT:-}" \
"${ERROR_ON_WARNINGS:-}" "${SYSTEM_VERSION_COMPAT:-}" "$SENTRY_TEST_OOM_LIMIT" \
"${RUN_ANALYZER:-}" "${LLVM_COV:-}" "${LLVM_PROFDATA:-}" \
"${CMAKE_DEFINES:-}" "${CMAKE_GENERATOR:-}"'''
        result = self.run_profile('darwin25', *profiles, '--', self.bash, '-c',
                                  command,
                                  extra_env={**self.mac_env, **(extra_env or {})})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def bash_path(self, path):
        if os.name != 'nt':
            return path
        return subprocess.run([self.bash, '--noprofile', '--norc', '-c',
                               'cygpath -u "$1"', '_', path],
                              capture_output=True, text=True,
                              check=True).stdout.strip()

    def test_macos_coverage_uses_the_selected_toolchain(self):
        self.prepare_macos()
        sdk = self.bash_path(self.mac_env['PROFILE_TEST_SDK'])
        for compiler, root in (('xcode', 'XCODE'), ('clang-18', 'LLVM18')):
            bin = self.bash_path(self.mac_env[f'PROFILE_TEST_{root}']) + '/bin/'
            for profiles in itertools.permutations((compiler, 'asan', 'llvm-cov')):
                with self.subTest(profiles=profiles):
                    values = self.macos_config(*profiles)
                    self.assertEqual(values[:6], [
                        bin + 'clang', bin + 'clang++',
                        sdk, '1', '0', '4095',
                    ])
                    self.assertEqual(set(values[6].split(',')), {'asan', 'llvm-cov'})
                    self.assertEqual(values[7:9], [bin + 'llvm-cov', bin + 'llvm-profdata'])

    def test_macos_presets_match_components(self):
        self.prepare_macos()
        for preset, components in (
            ('xcode-universal', ('xcode', 'universal')),
            ('xcode-arm64e', ('xcode', 'arm64e')),
            ('clang-18-asan-cov', ('clang-18', 'asan', 'llvm-cov')),
        ):
            with self.subTest(preset=preset):
                self.assertEqual(self.macos_config(preset),
                                 self.macos_config(*components))
        for backend in ('inproc', 'breakpad'):
            with self.subTest(backend=backend):
                values = self.macos_config('ios-' + backend)
                self.assertEqual(values[:5], ['', '', '', '', ''])
                self.assertEqual(values[9:], [
                    f'-DCMAKE_SYSTEM_NAME=iOS -DSENTRY_BACKEND={backend}', 'Xcode',
                ])

    def test_macos_targets_reject_incompatible_choices(self):
        self.prepare_macos()
        for profiles, message in (
            (('universal', 'arm64e'), 'choose one macOS architecture:'),
            (('xcode', 'clang-18'), 'choose one compiler:'),
            (('ios', 'universal'), 'iOS cannot be combined with a macOS architecture'),
            (('universal', 'android-35'), 'macOS cannot be combined with Android'),
        ):
            with self.subTest(profiles=profiles):
                result = self.run_profile('darwin25', *profiles, '--', 'true',
                                          extra_env=self.mac_env)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
        result = self.run_profile('darwin25', 'xcode-arm64e', '--', 'true',
                                  extra_env={**self.mac_env, 'PROFILE_TEST_ARCH': 'x86_64'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('arm64e tests require an Arm64 Mac', result.stderr)

    def test_inherited_macos_choices_are_cleared(self):
        self.prepare_macos()
        inherited = {'CC': '/old/clang', 'CXX': '/old/clang++',
                     'SDKROOT': '/old/iphonesimulator.sdk',
                     'RUN_ANALYZER': 'tsan', 'LLVM_COV': '/old/llvm-cov',
                     'CMAKE_DEFINES': '-DCMAKE_OSX_ARCHITECTURES=arm64e',
                     'CMAKE_GENERATOR': 'Xcode', 'SYSTEM_VERSION_COMPAT': '1'}
        for profile in ('xcode', 'clang-18-asan-cov', 'ios-inproc'):
            with self.subTest(profile=profile):
                self.assertEqual(self.macos_config(profile, extra_env=inherited),
                                 self.macos_config(profile))

    def test_macos_missing_llvm_does_not_fall_back(self):
        self.prepare_macos()
        compiler = Path(self.mac_env['PROFILE_TEST_LLVM18']) / 'bin/clang'
        compiler.unlink()
        result = self.run_profile('darwin25', 'clang-18-asan-cov', '--', 'true',
                                  extra_env=self.mac_env)
        self.assertEqual(result.returncode, 1)
        self.assertIn(compiler.relative_to(self.root).as_posix(), result.stderr)

    def test_macos_coverage_listing_uses_the_active_compiler(self):
        self.prepare_macos()
        for active in (False, True):
            env = {**self.mac_env, 'CC': '', 'CXX': ''}
            if active:
                bin = self.mac_env['PROFILE_TEST_LLVM18'] + '/bin/'
                env.update({'CC': bin + 'clang', 'CXX': bin + 'clang++'})
            result = self.run_profile('darwin25', '--list', extra_env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            row = next(line for line in result.stdout.splitlines()
                       if line.split()[:1] == ['llvm-cov'])
            if active:
                self.assertTrue(row.endswith('✓'), row)
            else:
                self.assertIn('✗ requires profile: clang-<version>', row)


if __name__ == '__main__':
    unittest.main()
