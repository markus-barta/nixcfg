#!/usr/bin/env python3
"""NIX-604. Every write uses a private fixture; never contacts a live daemon."""
import argparse
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import tempfile
import termios
import time
import unittest

import pyte
from wcwidth import wcswidth

REPO = Path(__file__).resolve().parents[1]
MODULE = REPO / 'modules/uzumaki/stasysmo'
WIDTHS = (150, 120, 100, 80, 74, 60, 50, 46, 40, 30, 24)
COLORS = dict(LIGHTEST='b4f9f8', PRIMARY='7dcfff', SECONDARY='7aa2f7',
              MIDDARK='3d59a1', DARK='292e42', DARKER='1f2335', DARKEST='1a1b26',
              TEXT_ON_LIGHTEST='15161e', TEXT_ON_MEDIUM='15161e', TEXT_ON_SECONDARY='15161e',
              TEXT_ACCENT='c0caf5', TEXT_MUTED='565f89', TEXT_MUTED_LIGHT='a9b1d6',
              ROOT_BG='ff0000', ROOT_FG='ffffff', ERROR_BG='ff5555', ERROR_FG='ffffff',
              SUDO_FG='e0af68', STASYSMO_COLOR_MUTED='242', HOSTNAME='fixture',
              PALETTE_NAME='fixture', PALETTE_KEY='fixture', CATEGORY='fixture',
              PL_LEFT_HARD='', PL_RIGHT_HARD='', PL_LEFT_SOFT='', PL_RIGHT_SOFT='')


def fish_quote(value):
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"


def render_template(name, target):
    text = (REPO / 'modules/uzumaki/theme/starship-themes' / name).read_text()
    for key, value in COLORS.items():
        text = text.replace('__' + key + '__', value)
    assert not re.search(r'__[A-Z_]+__', text), text
    target.write_text(text)


def pty_prompt(cols, init, environment):
    """Controlling tty + DA1/CPR/kitty answers from the original QA harness."""
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 12, cols, 0, 0))
        os.environ.update(environment, TERM='xterm-256color', COLUMNS=str(cols), LINES='12')
        os.execvp('fish', ['fish', '--no-config', '-i', '-C', init])
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 12, cols, 0, 0))
    screen = pyte.Screen(cols, 12)
    stream = pyte.ByteStream(screen)
    raw = bytearray()
    pending = b''
    last_read = time.monotonic()
    deadline = last_read + 5
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], .05)
            if not ready:
                if raw and time.monotonic() - last_read > .3:
                    break
                continue
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            raw.extend(data)
            last_read = time.monotonic()
            # Preserve incomplete control sequences across PTY chunks.
            pending += data
            if b'\x1b[c' in pending or b'\x1b[0c' in pending:
                os.write(master, b'\x1b[?62;22c')
            if b'\x1b[6n' in pending:
                os.write(master, b'\x1b[%d;%dR' % (screen.cursor.y + 1, screen.cursor.x + 1))
            if b'\x1b[?u' in pending:
                os.write(master, b'\x1b[?0u')
            pending = re.sub(rb'\x1bP.*?\x1b\\', b'', pending, flags=re.S)
            dcs = pending.find(b'\x1bP')
            if dcs >= 0:
                stream.feed(pending[:dcs])
                pending = pending[dcs:]
            else:
                stream.feed(pending)
                pending = b''
        return screen, bytes(raw)
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        os.close(master)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='stasysmo-qa-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.cache = self.home / 'Library/Caches/stasysmo'
        self.cache.mkdir(parents=True, mode=0o700)
        self.snapshot = self.cache / 'snapshot'
        self.snapshot.write_text(f'v1 {int(time.time())} 16 48 12 1.23 10\n')
        self.snapshot.chmod(0o600)
        self.config = self.home / 'starship.toml'
        render_template('tokyonight-uzumaki.toml', self.config)
        self.env = dict(os.environ, HOME=str(self.home), USER='runner',
                        TERM='xterm-256color', COLORTERM='truecolor', STARSHIP_CONFIG=str(self.config), STARSHIP_CACHE=str(self.home / 'starship-cache'))
        self.env.pop('SSH_TTY', None)
        self.env.pop('SSH_CONNECTION', None)
        self.init = f'''
set -g STASYSMO_SNAPSHOT {fish_quote(self.snapshot)}
set -g STASYSMO_STALE_SECONDS 15
set -g STASYSMO_ELEVATED 50 70 50 0.7
set -g STASYSMO_CRITICAL 80 90 75 1.0
set -g STASYSMO_COLOR_MUTED 242
set -g STASYSMO_COLOR_ELEVATED 255
set -g STASYSMO_COLOR_CRITICAL 196
set -g STASYSMO_ICONS   󰾴 󰊚
set -g STASYSMO_SPACER_ICON_VALUE ' '
set -g STASYSMO_SPACER_METRICS '  '
set -g STASYSMO_DARKEST 1a1b26
set -g STASYSMO_DARKER 1f2335
set -g STASYSMO_MUTED_LIGHT a9b1d6
set -g STASYSMO_ERROR ff5555
set -g STASYSMO_ROOT_BG ff0000
set -g STASYSMO_ROOT_FG ffffff
set -g fish_greeting
set -g fish_color_autosuggestion normal
set -g fish_color_command normal
source {fish_quote(MODULE / 'reader.fish')}
source {fish_quote(MODULE / 'prompt.fish')}
'''

    def fish(self, command, check=True, env=None):
        return subprocess.run([shutil.which('fish'), '--no-config', '-c', self.init + command],
                              env=env or self.env, text=True, capture_output=True,
                              timeout=10, check=check)

    def compose(self, width, path, extra=''):
        script = f'cd {fish_quote(path)}; set -g COLUMNS {width}; {extra}; __stasysmo_compose 1 2500; or exit 42; printf "%s" "$__stasysmo_output"'
        return self.fish(script).stdout

    def make_repo(self, long=False):
        repo = self.home / ('Code/repository-root-with-a-long-name' if long else 'Code/ops')
        repo.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(repo)], env=self.env, check=True)
        subprocess.run(['git', '-C', str(repo), 'symbolic-ref', 'HEAD',
                        'refs/heads/feature/a-very-long-branch-name-for-layout-testing'],
                       env=self.env, check=True)
        # Fixture commit only: never mutates the working checkout's Git directory.
        (repo / 'tracked').write_text('fixture')
        subprocess.run(['git', '-C', str(repo), 'add', 'tracked'], env=self.env, check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@invalid', '-c', 'commit.gpgsign=false', 'commit',
                        '-qm', 'fixture'], env=self.env, check=True)
        (repo / 'untracked').write_text('dirty')
        (repo / 'main.py').write_text('pass')
        if long:
            repo = repo / 'intermediate-directory' / 'leaf-directory'
            repo.mkdir(parents=True)
        return repo


class ReaderTests(Fixture):
    def test_valid_and_stale(self):
        command = f'__stasysmo_read {int(time.time())}; printf "%s\\n" $__stasysmo_metrics'
        result = self.fish(command).stdout
        self.assertIn('16%', result)
        self.assertIn('48%', result)
        self.assertIn('1.23', result)
        for timestamp in (int(time.time()) - 16, int(time.time()) + 60):
            self.snapshot.write_text(f'v1 {timestamp} 16 48 12 1.23 10\n')
            self.assertEqual(re.sub(r'\x1b\[[0-9;]*m', '', self.fish(command).stdout), '?\n')

    def test_hostile_records_and_file_types(self):
        marker = self.home / 'MUST-NOT-EXIST'
        now = int(time.time())
        values = [f'PIPESTATUS[$(touch {marker})]', '\x1b[2J', '9' * 100000,
                  '-1', '101', '01', '+1']
        command = f'__stasysmo_read {now}; printf "%s" $__stasysmo_metrics'
        for field in range(1, 8):
            for value in values:
                fields = f'v1 {now} 16 48 12 1.23 10'.split()
                fields[field - 1] = '10000' if field == 7 and value == '101' else value
                self.snapshot.write_text(' '.join(fields) + '\n')
                self.assertEqual(self.fish(command).stdout, '', (field, value[:40]))
                self.assertFalse(marker.exists())
        self.snapshot.unlink()
        self.assertEqual(self.fish(command).stdout, '')
        target = self.home / 'target'
        target.write_text(f'v1 {now} 16 48 12 1.23 10\n')
        self.snapshot.symlink_to(target)
        self.assertEqual(self.fish(command).stdout, '')
        self.snapshot.unlink()
        os.mkfifo(self.snapshot)
        self.assertEqual(self.fish(command).stdout, '')

    def test_no_metrics_processes(self):
        # An empty PATH cannot hide a spawn: command-not-found would fail/emit stderr.
        result = self.fish(f'set -gx PATH {fish_quote(self.home / "empty-path")}; __stasysmo_read {int(time.time())}; printf "%s" $__stasysmo_metrics')
        self.assertEqual(result.stderr, '')
        self.assertIn('16%', result.stdout)


class LayoutTests(Fixture):
    def test_widths_profiles_and_real_tty(self):
        for long in (False, True):
            path = self.make_repo(long)
            previous = None
            for width in WIDTHS:
                output = self.compose(width, path, 'set -gx IN_NIX_SHELL impure')
                lines = output.splitlines()
                visible = re.sub(r'\x1b\[[0-9;]*m', '', lines[0])
                expected_path = '~/' + str(path.relative_to(self.home))
                if wcswidth(expected_path) + 4 <= width - 1:
                    self.assertIn(expected_path, visible, (width, visible))
                # Any leading ellipsis must belong to our explicit component shortening.
                self.assertFalse(visible.startswith('…'), (width, visible))
                active = {label for label in ('', '', '󰾴', '󰊚', '', '⏱', 'impure',
                          '', '#', '@', '!?', '', '', '', '') if label in visible}
                if previous is not None:
                    self.assertLessEqual(active, previous, (width, active, previous))
                previous = active
                if '@' not in visible or '' not in visible:
                    self.assertNotIn('', visible)
                    self.assertNotIn('', visible)
                for line in lines:
                    screen = pyte.Screen(1000, 1)
                    pyte.Stream(screen).feed(line)
                    self.assertLessEqual(wcswidth(screen.display[0].rstrip()), width - 1)
                init = self.init + f'cd {fish_quote(path)}; set -gx IN_NIX_SHELL impure; set -g CMD_DURATION 2500; false'
                screen, raw = pty_prompt(width, init, self.env)
                first = next(line.rstrip() for line in screen.display if '' in line or '░▒▓' in line)
                self.assertFalse(first.startswith('…'), (width, first, raw))
                self.assertNotIn('Unknown', '\n'.join(screen.display))
                self.assertLessEqual(wcswidth(first), width - 1)
                # Every soft right arrow has foreground = preceding segment's bg,
                # and background = following segment's bg (or default for the cap).
                for row in screen.buffer.values():
                    for x, cell in list(row.items()):
                        if cell.data == '' and x > 0:
                            self.assertEqual(cell.fg, row[x - 1].bg, (width, x, cell, row[x - 1]))
                            if x + 1 < width:
                                self.assertEqual(cell.bg, row[x + 1].bg, (width, x, cell, row[x + 1]))

    def test_kill_switch_error_and_missing_starship(self):
        path = self.make_repo()
        normal = self.fish(f'cd {fish_quote(path)}; set -g COLUMNS 120; set -g STASYSMO_COMPOSER 0; fish_prompt').stdout
        self.assertIn('Code/ops', normal)
        self.assertNotIn('', normal)
        broken = self.fish(f'cd {fish_quote(path)}; set -g COLUMNS 120; functions -e __stasysmo_read; fish_prompt').stdout
        self.assertIn('Code/ops', broken)
        self.assertNotIn('', broken)
        absent = self.fish(f'cd {fish_quote(path)}; set -g COLUMNS 30; set -gx PATH /nonexistent; fish_prompt').stdout
        self.assertIn('❯', absent)
        self.assertTrue(absent.strip())
        tools = self.home / 'failing-starship'
        tools.mkdir()
        failed = tools / 'starship'
        failed.write_text('#!' + shutil.which('bash') + '\nexit 1\n')
        failed.chmod(0o755)
        failing = self.fish(f'cd {fish_quote(path)}; set -g COLUMNS 30; set -gx PATH {fish_quote(tools)}; fish_prompt').stdout
        self.assertIn('❯', failing)

    def test_one_starship_run_and_no_metric_commands(self):
        path = self.make_repo()
        subprocess.run(['git', '-C', str(path), 'symbolic-ref', 'HEAD', 'refs/heads/main'], env=self.env, check=True)
        tools = self.home / 'tools'
        tools.mkdir()
        log = self.home / 'starship-spawns'
        wrapper = tools / 'starship'
        wrapper.write_text('#!' + shutil.which('bash') + '\n' +
                           'printf "starship\\n" >> ' + str(log) + '\n' +
                           'exec ' + shutil.which('starship') + ' "$@"\n')
        wrapper.chmod(0o755)
        env = dict(self.env, PATH=str(tools))
        # Only Starship exists on PATH. Accidental metrics CLI calls fail loudly.
        output = self.fish(f'cd {fish_quote(path)}; set -g COLUMNS 150; __stasysmo_compose 0 0; or exit 42; printf "%s" "$__stasysmo_output"', env=env)
        self.assertEqual(log.read_text().splitlines(), ['starship'])
        self.assertEqual(output.stderr, '')
        self.assertIn('', output.stdout)

    def test_hostile_snapshot_in_real_prompt(self):
        path = self.home / 'Code/ops'
        path.mkdir(parents=True)
        marker = self.home / 'MUST-NOT-EXIST'
        cases = ('payload', 'escape', 'huge', 'negative', 'missing', 'future', 'symlink', 'fifo')
        for case in cases:
            if self.snapshot.exists() or self.snapshot.is_symlink():
                self.snapshot.unlink()
            now = int(time.time())
            records = dict(payload=f'v1 {now} PIPESTATUS[$(touch {marker})] 48 12 1.23 10\n',
                           escape=f'v1 {now} 16 48 12 1.23 10\x1b[2J\n',
                           huge='9' * 100000, negative=f'v1 {now} -1 48 12 1.23 10\n',
                           future=f'v1 {now + 60} 16 48 12 1.23 10\n')
            if case in records:
                self.snapshot.write_text(records[case])
            elif case == 'symlink':
                target = self.home / 'target'
                target.write_text(f'v1 {now} 16 48 12 1.23 10\n')
                self.snapshot.symlink_to(target)
            elif case == 'fifo':
                os.mkfifo(self.snapshot)
            init = self.init + 'cd ' + fish_quote(path) + '; true'
            screen, raw = pty_prompt(120, init, self.env)
            text = '\n'.join(screen.display)
            self.assertIn('Code/ops', text, (case, text, raw))
            self.assertIn('❯', text, (case, text, raw))
            self.assertNotIn('PIPESTATUS', text)
            self.assertFalse(marker.exists())
            if case == 'future':
                self.assertIn('?', text)
            else:
                self.assertNotIn('', text)

    def test_default_prompt_outside_fish(self):
        result = subprocess.run(['starship', 'prompt', '--terminal-width=120'], env=self.env,
                                capture_output=True, text=True, check=True)
        self.assertNotIn('v1 ', result.stdout)
        self.assertNotIn('', result.stdout)
        self.assertNotRegex(result.stdout, r'[0-9]{10} [0-9]{2}:')
        self.assertNotIn('STASYSMO', result.stdout)

    def test_glyph_width_agreement(self):
        glyphs = '░▒▓󰾴󰊚⏱✘✦❯✗⚠…'
        for glyph in glyphs:
            actual = self.fish('string length --visible -- ' + fish_quote(glyph)).stdout.strip()
            self.assertEqual(int(actual), wcswidth(glyph), glyph)

    def test_remote_identity_and_severity_priority(self):
        path = self.make_repo()
        self.snapshot.write_text(f'v1 {int(time.time())} 16 99 12 1.23 10\n')
        for width in (150, 120, 100, 80, 60, 40, 30, 24):
            output = self.compose(width, path, 'set -gx SSH_CONNECTION fixture; set -gx IN_NIX_SHELL impure')
            self.assertIn('@', output)
            for line in output.splitlines():
                self.assertLessEqual(wcswidth(re.sub(r'\x1b\[[0-9;]*m', '', line)), width - 1)
            if '' in output:
                self.assertIn('', output)


class DaemonTests(Fixture):
    def check_snapshot(self, snapshot, mode):
        self.assertEqual(snapshot.stat().st_mode & 0o777, mode)
        record = snapshot.read_text()
        self.assertRegex(record, r'^v1 [1-9][0-9]{8,10} (100|[1-9]?[0-9]) (100|[1-9]?[0-9]) (100|[1-9]?[0-9]) (0|[1-9][0-9]{0,3})\.[0-9]{2} [1-9][0-9]{0,3}\n$')
        fields = record.split()
        self.assertLessEqual(abs(int(fields[1]) - int(time.time())), 5)
        for field in fields[2:5]:
            self.assertLessEqual(int(field), 100)
            self.assertGreaterEqual(int(field), 0)
        self.assertGreaterEqual(float(fields[5]), 0)
        self.assertGreater(int(fields[6]), 0)

    def test_native_sample_atomic_permissions_and_clamp(self):
        if os.uname().sysname != 'Darwin':
            self.skipTest('Mach sampler runs on Darwin; Linux collector is tested here')
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('native compile requires cc (OPS hardware gate)')
        binary = self.home / 'sampler'
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        str(MODULE / 'sampler.c'), '-o', str(binary)], check=True)
        destination = self.home / 'native-cache'
        # Empty PATH proves the helper does not invoke external sampler commands.
        env = dict(self.env, PATH=str(self.home / 'empty-path'))
        started = time.monotonic()
        proc = subprocess.Popen([str(binary), '1', str(destination), '4'], env=env, stderr=subprocess.PIPE)
        generations = set()
        while proc.poll() is None:
            snapshot = destination / 'snapshot'
            if snapshot.exists():
                self.check_snapshot(snapshot, 0o600)
                generations.add(snapshot.stat().st_ino)
            time.sleep(.005)
        diagnostics = proc.stderr.read().decode()
        proc.stderr.close()
        if proc.returncode and 'Operation not permitted' in diagnostics:
            if os.environ.get('GITHUB_ACTIONS') == 'true':
                self.fail('native CI gate blocked: ' + diagnostics.strip())
            self.skipTest('native sampling blocked by sandbox: ' + diagnostics.strip())
        self.assertEqual(proc.returncode, 0, diagnostics)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 1.55)  # 100ms warmup + 3 * 500ms
        self.assertLess(elapsed, 6)
        self.assertGreaterEqual(len(generations), 3)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(destination.glob('.snapshot.*')), [])
        # An unsafe directory or a symlink is never accepted/repaired silently.
        unsafe = self.home / 'unsafe'
        unsafe.mkdir(mode=0o755)
        self.assertNotEqual(subprocess.run([str(binary), '500', str(unsafe), '1'],
                                          capture_output=True).returncode, 0)
        link = self.home / 'symlink'
        link.symlink_to(destination, target_is_directory=True)
        self.assertNotEqual(subprocess.run([str(binary), '500', str(link), '1'],
                                          capture_output=True).returncode, 0)
        # Rename replaces a planted snapshot symlink, never writes its target.
        target = self.home / 'untouched'
        target.write_text('untouched')
        (destination / 'snapshot').unlink()
        (destination / 'snapshot').symlink_to(target)
        subprocess.run([str(binary), '500', str(destination), '1'], check=True)
        self.assertEqual(target.read_text(), 'untouched')
        self.assertFalse((destination / 'snapshot').is_symlink())
        self.assertNotEqual(subprocess.run([str(binary), '-1', str(destination), '1'],
                                          capture_output=True).returncode, 0)

    def test_linux_output_atomicity_failures_and_one_child(self):
        # Fixture /proc also runs on Darwin using GNU coreutils + Nix Bash.
        bash = shutil.which('bash')
        version = subprocess.run([bash, '-c', 'printf "%s" "$BASH_VERSION"'],
                                 capture_output=True, text=True, check=True).stdout
        if int(version.split('.')[0]) < 4:
            self.skipTest('Linux collector fixture requires Nix Bash >= 4.2')
        tools = self.home / 'tools'
        tools.mkdir()
        log = self.home / 'spawn-log'
        for name in ('mv', 'mkfifo', 'unlink'):
            executable = shutil.which(name)
            if not executable:
                self.fail(f'Linux collector fixture requires coreutils {name}')
            wrapper = tools / name
            wrapper.write_text(f'#!{bash}\nprintf "%s\\n" "{name}" >> "{log}"\nexec "{executable}" "$@"\n')
            wrapper.chmod(0o755)
        procroot = self.home / 'proc'
        procroot.mkdir()
        (procroot / 'meminfo').write_text('MemTotal: 1000 kB\nMemAvailable: 520 kB\nSwapTotal: 100 kB\nSwapFree: 88 kB\n')
        (procroot / 'loadavg').write_text('1.23 0.4 0.2 1/20 123\n')
        (procroot / 'stat').write_text('cpu 100 0 100 800 0 0 0 0 0 0\ncpu0 0\ncpu1 0\n')
        destination = self.home / 'linux-runtime'
        destination.mkdir(mode=0o755)
        env = dict(self.env, PATH=str(tools), STASYSMO_PROC_ROOT=str(procroot))
        started = time.monotonic()
        proc = subprocess.Popen([bash, str(MODULE / 'daemon.sh'), '1', str(destination), '5'],
                                env=env, stderr=subprocess.PIPE)
        inode_generations = set()
        tick = 100
        try:
            while proc.poll() is None:
                # Publish fixture CPU counters atomically so reads never see partial data.
                tick += 10
                stat_temp = procroot / 'stat.new'
                stat_temp.write_text(f'cpu {tick} 0 {tick} {tick * 8} 0 0 0 0 0 0\ncpu0 0\ncpu1 0\n')
                stat_temp.replace(procroot / 'stat')
                snapshot = destination / 'snapshot'
                if snapshot.exists():
                    self.check_snapshot(snapshot, 0o644)
                    fields = snapshot.read_text().split()
                    self.assertEqual(fields[3:7], ['48', '12', '1.23', '2'])
                    inode_generations.add(snapshot.stat().st_ino)
                self.assertLess(time.monotonic() - started, 8)
                time.sleep(.01)
            self.assertEqual(proc.returncode, 0, proc.stderr.read().decode())
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            proc.stderr.close()
        self.assertGreaterEqual(time.monotonic() - started, 2.05)
        self.assertGreaterEqual(len(inode_generations), 3)
        calls = log.read_text().splitlines()
        self.assertEqual(calls.count('mv'), 5, calls)
        self.assertEqual(calls.count('mkfifo'), 1, calls)
        self.assertEqual(calls.count('unlink'), 1, calls)
        self.assertEqual(len(calls), 7, calls)
        self.assertEqual(list(destination.glob('.snapshot.*')), [])
        self.assertEqual(list(destination.glob('.wait.*')), [])
        # A failed sample retains the old generation, instead of inventing zeros.
        before = (destination / 'snapshot').read_bytes()
        (procroot / 'meminfo').write_text('MemTotal: hostile\n')
        subprocess.run([bash, str(MODULE / 'daemon.sh'), '500', str(destination), '1'], env=env, check=True)
        self.assertEqual((destination / 'snapshot').read_bytes(), before)
        self.assertNotEqual(subprocess.run([bash, str(MODULE / 'daemon.sh'), '-1', str(destination), '1'], env=env).returncode, 0)

    def test_integration_contract(self):
        nixos = (MODULE / 'nixos.nix').read_text()
        home = (MODULE / 'home-manager.nix').read_text()
        self.assertIn('RuntimeDirectory = "stasysmo";', nixos)
        self.assertIn('DynamicUser = true;', nixos)
        self.assertNotIn('"/dev/shm"', nixos)
        self.assertNotIn('"/tmp/stasysmo', home)
        self.assertIn('com.stasysmo.daemon', home)
        self.assertIn('hasLaunchdDomain', home)
        self.assertIn('1600', home)
        template = (REPO / 'modules/uzumaki/theme/starship-themes/tokyonight-uzumaki.toml').read_text()
        for custom in ('custom.stasysmo', 'custom.githash', 'custom.root_alert'):
            self.assertNotIn('[' + custom + ']', template)
        self.assertIn('[git_commit]', template)
        self.assertIn('command_timeout = 500', template)


def benchmark(existing_path=None):
    """Same-minute A/B in a private git fixture; never reads live /tmp/stasysmo."""
    fixture = Fixture()
    fixture.setUp()
    try:
        if existing_path:
            path = Path(existing_path).expanduser().resolve()
            assert (path / '.git').exists(), 'benchmark path must be a git repository'
        else:
            path = fixture.make_repo()
            subprocess.run(['git', '-C', str(path), 'symbolic-ref', 'HEAD', 'refs/heads/main'],
                           env=fixture.env, check=True)
        legacy_config = fixture.home / 'legacy.toml'
        render_template('tokyonight-uzumaki-legacy.toml', legacy_config)
        old_directory = fixture.home / 'legacy-metrics'
        old_directory.mkdir()
        for name, value in dict(cpu='16', ram='48', swap='12', load='1.23', timestamp=str(int(time.time()))).items():
            (old_directory / name).write_text(value + '\n')
        old_reader = subprocess.run(['git', 'show', 'HEAD:modules/uzumaki/stasysmo/reader.sh'],
                                    text=True, capture_output=True, check=True).stdout
        reader = fixture.home / 'stasysmo-reader'
        reader.write_text('#!' + shutil.which('bash') + '\n' +
                          'export STASYSMO_DIR=' + str(old_directory) + '\n' +
                          'export STASYSMO_ICON_CPU= STASYSMO_ICON_RAM= STASYSMO_ICON_LOAD=󰊚 STASYSMO_ICON_SWAP=󰾴\n' +
                          old_reader)
        reader.chmod(0o755)
        legacy_config.write_text(legacy_config.read_text().replace(
            'test -f /dev/shm/stasysmo/timestamp || test -f /tmp/stasysmo/timestamp',
            'test -f ' + str(old_directory / 'timestamp')))
        env = dict(fixture.env, PATH=str(fixture.home) + ':' + fixture.env['PATH'])
        timings = {}
        for label in ('legacy', 'v2', 'metrics'):
            init = fixture.init + '\ncd ' + fish_quote(path) + '\nset -g COLUMNS 120\n'
            if label == 'legacy':
                init += 'set -gx STARSHIP_CONFIG ' + fish_quote(legacy_config) + '\n'
                command = 'command starship prompt --terminal-width=120 >/dev/null; command starship prompt --right --terminal-width=120 >/dev/null'
            elif label == 'v2':
                command = 'set -g CMD_DURATION 0; true; fish_prompt >/dev/null; set -q __stasysmo_output; or exit 42'
            else:
                command = f'__stasysmo_read {int(time.time())}'
            script = init + '\n'.join('time begin; ' + command + '; end' for _ in range(35))
            result = subprocess.run(['fish', '--no-config', '-c', script], env=env,
                                    capture_output=True, text=True, check=True, timeout=30)
            measured = re.findall(r'Executed in\s+([0-9.]+)\s+(micros|millis|secs)', result.stderr)
            assert len(measured) == 35, result.stderr
            scale = dict(micros=.001, millis=1, secs=1000)
            values = [float(value) * scale[unit] for value, unit in measured[5:]]
            timings[label] = dict(median_ms=round(statistics.median(values), 3),
                                  p95_ms=round(sorted(values)[int(len(values) * .95)], 3), samples=len(values))
        print('same-minute A/B, width=120, path=' + str(path) + ':', timings)
    finally:
        fixture.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--benchmark', action='store_true')
    parser.add_argument('--benchmark-path', help='read-only existing git repository')
    parser.add_argument('--case', help='single unittest method name')
    parser.add_argument('--suite', choices=('all', 'layout', 'reader', 'daemon'), default='all')
    args, remaining = parser.parse_known_args()
    if args.benchmark:
        benchmark(args.benchmark_path)
        raise SystemExit(0)
    classes = {'reader': ReaderTests, 'layout': LayoutTests, 'daemon': DaemonTests}
    chosen = classes.values() if args.suite == 'all' else [classes[args.suite]]
    suite = unittest.TestSuite(unittest.TestSuite([cls(args.case)]) if args.case else unittest.defaultTestLoader.loadTestsFromTestCase(cls) for cls in chosen)
    outcome = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not outcome.wasSuccessful())
