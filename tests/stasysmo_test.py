#!/usr/bin/env python3
"""NIX-604. Every write uses a private fixture; never contacts a live daemon."""
import argparse
import fcntl
import json
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
RENDERED_INIT_JSON = None


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
        # Replace, never merge: `update` would keep inherited keys the fixture deliberately removed
        # (SSH_CONNECTION/SSH_TTY when the suite runs over ssh made line 1 grow an identity row).
        os.environ.clear()
        os.environ.update(environment, COLUMNS=str(cols), LINES='12')
        startup = 'if test "$TERM" != dumb; starship init fish | source; end\n' + init
        os.execvp('fish', ['fish', '--no-config', '--private', '-i', '-C', startup])
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 12, cols, 0, 0))
    screen = pyte.Screen(cols, 12)
    stream = pyte.ByteStream(screen)
    raw = bytearray()
    pending = b''
    last_read = time.monotonic()
    deadline = last_read + 10
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], .05)
            if not ready:
                if raw and time.monotonic() - last_read >= 1.0:
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
            # Drop complete DCS sequences (ESC P ... ESC \) with a linear scan: a regex over
            # terminal output is a polynomial-ReDoS shape (CodeQL py/polynomial-redos).
            kept = bytearray()
            pos = 0
            while True:
                start = pending.find(b'\x1bP', pos)
                end = pending.find(b'\x1b\\', start + 2) if start >= 0 else -1
                if start < 0 or end < 0:
                    kept += pending[pos:]  # no (complete) DCS left; an incomplete one stays pending
                    break
                kept += pending[pos:start]
                pos = end + 2
            pending = bytes(kept)
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
                        XDG_CONFIG_HOME=str(self.home / '.config'), XDG_CACHE_HOME=str(self.home / '.cache'),
                        XDG_DATA_HOME=str(self.home / '.local/share'),
                        TERM='xterm-256color', COLORTERM='truecolor', STARSHIP_CONFIG=str(self.config), STARSHIP_CACHE=str(self.home / 'starship-cache'))
        for key in list(self.env):
            if key.startswith('GIT_'):
                self.env.pop(key)
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(self.home / 'no-git-config'),
                        GIT_CEILING_DIRECTORIES=str(self.home))
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
    def assert_two_lines(self, output, width):
        lines = output.splitlines()
        self.assertEqual(len(lines), 2, (width, output))
        for line in lines:
            screen = pyte.Screen(1000, 1)
            pyte.Stream(screen).feed(line)
            self.assertLessEqual(screen.cursor.x, width - 1, (width, output))
        first = pyte.Screen(1000, 1)
        pyte.Stream(first).feed(lines[0])
        self.assertFalse(first.display[0].startswith('…'), (width, output))
        return first.display[0].rstrip()

    def test_real_starship_key_bindings(self):
        path = self.home / 'keymap-directory'
        path.mkdir()
        for binding, mode, command, expected in (
                ('fish_default_key_bindings', 'default', 'true', '❯'),
                ('fish_default_key_bindings', 'default', 'false', '✗'),
                ('fish_vi_key_bindings', 'insert', 'true', '❯'),
                ('fish_vi_key_bindings', 'insert', 'false', '✗'),
                ('fish_vi_key_bindings', 'default', 'true', '❮')):
            with self.subTest(binding=binding, mode=mode, command=command):
                init = self.init + f'cd {fish_quote(path)}; set -g fish_key_bindings {binding}; {binding}; set -g fish_bind_mode {mode}; {command}'
                screen, raw = pty_prompt(120, init, self.env)
                text = '\n'.join(screen.display)
                self.assertIn(expected, text, raw)
                if mode == 'insert' or binding == 'fish_default_key_bindings':
                    self.assertNotIn('❮', text, raw)
                # Prove the test exercised real Starship fish initialization.
                self.assertEqual(self.fish('starship init fish | source; printf "%s" "$STARSHIP_SHELL"').stdout, 'fish')

    def test_exact_fit_all_widths(self):
        paths = (self.home / ('non-repo-' + 'x' * 120), self.make_repo(True))
        paths[0].mkdir()
        # One fish process per path; real profiles/branch and real path shortening.
        for path in paths:
            script = f'cd {fish_quote(path)}\n'
            for width in range(5, 161):
                script += f'set -g COLUMNS {width}; __stasysmo_compose 0 0; or exit 42; printf "%s\\0" "$__stasysmo_output"\n'
            result = subprocess.run(['fish', '--no-config', '-c', self.init + script],
                                    env=self.env, text=True, capture_output=True, timeout=45, check=True)
            outputs = result.stdout.split('\0')
            self.assertEqual(len(outputs), 157)
            self.assertEqual(outputs[-1], '')
            for width, output in zip(range(5, 161), outputs[:-1]):
                first = self.assert_two_lines(output, width)
                # Strip the known chain decoration, leaving actual directory text.
                directory = first.replace('░▒▓', '').replace('', '').replace('', '').strip()
                self.assertTrue(directory, (width, path, output))
                if path.name not in directory:
                    self.assertIn(path.name[:max(1, width - 6)], directory, (width, path, output))
                    self.assertIn('…', directory, (width, path, output))
        # Force exactly zero padding at every width, without extra Starship startups.
        script = f'''function __stasysmo_render
    set -g __stasysmo_lines (string repeat -n (math "$COLUMNS - 1") x) '{int(time.time())} 12:00:00' '❯ '
end
'''
        for width in range(5, 161):
            script += f'set -g COLUMNS {width}; __stasysmo_compose 0 0; or exit 42; printf "%s\\0" "$__stasysmo_output"\n'
        outputs = self.fish(script).stdout.split('\0')
        self.assertEqual(len(outputs), 157)
        for width, output in zip(range(5, 161), outputs[:-1]):
            self.assertEqual(self.assert_two_lines(output, width), 'x' * (width - 1))
        for width in (5, 6, 24, 36, 37, 60):
            init = self.init + f'cd {fish_quote(paths[0])}; true'
            _, raw = pty_prompt(width, init, self.env)
            # Fish's own prompt markers isolate the prompt from startup warnings.
            start = raw.find(b'\x1b]133;A')
            self.assertGreaterEqual(start, 0, raw)
            payload = raw.find(b'\x1b\\', start)
            self.assertGreaterEqual(payload, 0, raw)
            end = raw.find(b'\x1b]133;B', payload + 2)
            self.assertGreater(end, payload, raw)
            screen = pyte.Screen(width, 12)
            pyte.ByteStream(screen).feed(raw[payload + 2:end])
            rows = [row.rstrip() for row in screen.display if row.strip()]
            self.assertEqual(len(rows), 2, (width, rows, raw))
            self.assertFalse(rows[0].startswith('…'), (width, rows, raw))
            self.assertIn('❯', rows[1], (width, rows, raw))
            for row in rows:
                self.assertLessEqual(wcswidth(row), width - 1, (width, rows, raw))

    def test_nonrepo_long_paths_never_empty(self):
        paths = [self.home / 'nix/store' / ('a' * 32 + '-source'), self.home / ('x' * 120)]
        for path in paths:
            path.mkdir(parents=True)
        # Read-only real store directory also exercises discovery outside the checkout
        # when the local sandbox requires fixtures to live inside the worktree.
        store_source = next((p for p in Path('/nix/store').glob('*-source') if p.is_dir()), None)
        if store_source:
            paths.append(store_source)
        for path in paths:
            git = subprocess.run(['git', '-C', str(path), 'rev-parse', '--show-toplevel'],
                                 env=self.env, capture_output=True)
            self.assertNotEqual(git.returncode, 0, path)
            for width in (24, 30, 40, 60):
                budget = width - 5  # compact chain's four decoration columns
                result = self.fish(f'cd {fish_quote(path)}; __stasysmo_path {budget}').stdout
                self.assertTrue(result, (path, width))
                self.assertLessEqual(wcswidth(result), budget)
                if wcswidth(path.name) > budget:
                    self.assertIn('…', result)
                    self.assertIn(path.name[:3], result)
                else:
                    self.assertIn(path.name, result)
                    self.assertTrue(result == path.name or result.startswith(('…/', '~/', '/')), result)
                first = self.assert_two_lines(self.compose(width, path), width)
                self.assertTrue(first.replace('', '').replace('', '').strip(), first)

    def test_double_slash_terminates(self):
        for width in (6, 3):
            script = self.init + f'cd //; set -g COLUMNS {width}; printf "%s\\n" "$PWD"; __stasysmo_path (math "max(1, $COLUMNS - 5)")'
            result = subprocess.run(['fish', '--no-config', '-c', script], env=self.env,
                                    text=True, capture_output=True, timeout=1, check=True)
            self.assertEqual(result.stdout.splitlines()[0], '//')
            self.assertTrue(result.stdout.splitlines()[1])

    def test_dumb_terminal_does_not_install_wrapper(self):
        env = dict(self.env, TERM='dumb')
        original = 'function fish_prompt; printf "plain> "; end\nfunction fish_right_prompt; printf "right"; end\n'
        result = subprocess.run(
            ['fish', '--no-config', '-c', original + self.init + 'fish_prompt; fish_right_prompt'],
            env=env, text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout, 'plain> right')
        self.assertNotIn('\x1b', result.stdout)
        # TERM can also change after the wrapper was installed.
        result = self.fish('set -gx TERM dumb; fish_prompt').stdout
        self.assertNotIn('', result)
        self.assertNotIn('\x1b', result)
        self.assertTrue(result.strip())
        result = subprocess.run(['fish', '--no-config', '-c', 'starship init fish | source\n' +
                                 self.init + 'set -gx TERM dumb; fish_prompt'],
                                env=self.env, text=True, capture_output=True, check=True)
        self.assertNotIn('\x1b', result.stdout)
        self.assertNotIn('', result.stdout)
        self.assertTrue(result.stdout.strip())

    def test_pty_waits_through_loaded_runner_pause(self):
        init = self.init + 'printf "pre-prompt\\n"; sleep 0.6; true'
        screen, raw = pty_prompt(120, init, self.env)
        self.assertIn('❯', '\n'.join(screen.display), raw)

    def test_fish_config_escaper_round_trips(self):
        # Exercise the production replacement table, not an independent copy.
        # Nix evaluation of the entire init is also gated by stasysmo-init-eval.nix.
        source = (MODULE / 'fish-init.nix').read_text()
        body = source.split('quote = value:', 1)[1].split(';', 1)[0].strip()
        decoder = json.JSONDecoder()
        prefix, end = decoder.raw_decode(body)
        body = body[end:].strip()
        self.assertTrue(body.startswith('+ lib.replaceStrings '), body)
        body = body[len('+ lib.replaceStrings '):].strip()
        tables = []
        for _ in range(2):
            self.assertTrue(body.startswith('['), body)
            body = body[1:].strip()
            table = []
            while not body.startswith(']'):
                value, end = decoder.raw_decode(body)
                table.append(value)
                body = body[end:].strip()
            tables.append(table)
            body = body[1:].strip()
        self.assertTrue(body.startswith('value + '), body)
        suffix = json.loads(body[len('value + '):])
        replacements = dict(zip(*tables, strict=True))
        values = ['trailing\\', "single'quote", "quote'and\\", 'two\\\\', '',
                  '$(touch MUST-NOT-EXIST); $HOME', 'line\nbreak']
        script = ''
        for i, value in enumerate(values):
            quoted = prefix + ''.join(replacements.get(char, char) for char in value) + suffix
            script += f'set -g STASYSMO_PROBE_{i} {quoted}\nprintf "%s\\0" "$STASYSMO_PROBE_{i}"\n'
        syntax = subprocess.run(['fish', '--no-config', '-n', '-c', script], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        result = self.fish(script).stdout.split('\0')
        self.assertEqual(result, values + [''])
        for value in ('snapshot', 'cfg.icons.${metric}', 'cfg.display.spacerIconValue', 'cfg.display.spacerMetrics'):
            self.assertIn('quote ' + value, source)

    def test_nix_generated_config_round_trips(self):
        if not RENDERED_INIT_JSON:
            self.skipTest('Nix evaluation is unavailable; OPS/CI nix-shell supplies STASYSMO_TEST_INIT_JSON')
        rendered = json.loads(Path(RENDERED_INIT_JSON).read_text())
        script = rendered['fishInit']
        expected = []
        for key, value in rendered['expected'].items():
            script += f'printf "%s\\0" ${key}\n'
            expected.extend(value if isinstance(value, list) else [value])
        syntax = subprocess.run(['fish', '--no-config', '-n', '-c', script], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        self.assertEqual(self.fish(script).stdout.split('\0'), expected + [''])

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
        normal = self.fish(f'cd {fish_quote(path)}; set -g COLUMNS 120; set -g STASYSMO_FISH_LAYOUT 0; fish_prompt').stdout
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
    def native_binary(self):
        if os.uname().sysname != 'Darwin':
            self.skipTest('Mach sampler runs on Darwin; Linux collector is tested here')
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('native compile requires cc (OPS hardware gate)')
        binary = self.home / 'sampler'
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        str(MODULE / 'sampler.c'), '-o', str(binary)], env=self.env, check=True)
        return binary

    def test_native_count_and_load_rounding(self):
        binary = self.native_binary()  # also compile the actual daemon without overrides
        harness = self.home / 'sampler-bounds.c'
        harness.write_text('''#include <mach/mach.h>
#include <stdbool.h>
static mach_msg_type_number_t returned_count;
static natural_t returned_processors = 2;
static integer_t fixture[CPU_STATE_MAX * 2];
static bool released;
static kern_return_t test_processor_info(host_t host, processor_flavor_t flavor,
        natural_t *processors, processor_info_array_t *info, mach_msg_type_number_t *count) {
    (void)host; (void)flavor;
    *processors = returned_processors; *info = fixture; *count = returned_count;
    return KERN_SUCCESS;
}
static kern_return_t test_deallocate(vm_map_t target, vm_address_t address, vm_size_t size) {
    (void)target; (void)address; (void)size; released = true; return KERN_SUCCESS;
}
#define host_processor_info test_processor_info
#define vm_deallocate test_deallocate
#define main sampler_entry
#include "''' + str(MODULE / 'sampler.c') + '''"
#undef main
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    host_cpu_load_info_data_t ticks;
    mach_msg_type_number_t invalid[] = {0, CPU_STATE_MAX - 1, CPU_STATE_MAX * 2 - 1,
                                       CPU_STATE_MAX * 2 + 1};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        returned_count = invalid[i]; released = false;
        if (cpu_ticks(&ticks) || !released) return 10;
    }
    returned_processors = 0; returned_count = 0; released = false;
    if (cpu_ticks(&ticks) || !released) return 11;
    returned_processors = 2; returned_count = CPU_STATE_MAX * 2; released = false;
    for (unsigned i = 0; i < CPU_STATE_MAX * 2; i++) fixture[i] = (integer_t)(i + 1);
    if (!cpu_ticks(&ticks) || !released) return 12;
    for (unsigned i = 0; i < CPU_STATE_MAX; i++)
        if (ticks.cpu_ticks[i] != 2 * i + CPU_STATE_MAX + 2) return 13;
    int dir = private_dir(argv[1]);
    if (dir < 0) return 14;
    double loads[] = {0, 1.234, 9999.994, 9999.995, 9999.999, 10000.0, 1e300};
    for (unsigned i = 0; i < sizeof(loads) / sizeof(loads[0]); i++) {
        if (!publish(dir, i, 16, 48, 12, loads[i], 10)) return 15;
        char name[40]; snprintf(name, sizeof(name), "record.%u", i);
        if (renameat(dir, "snapshot", dir, name)) return 16;
    }
    if (publish(dir, 100, 16, 48, 12, -1, 10) ||
        publish(dir, 101, 16, 48, 12, NAN, 10) ||
        publish(dir, 102, 16, 48, 12, INFINITY, 10)) return 17;
    close(dir); return 0;
}
''')
        subprocess.run([shutil.which('cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        '-include', 'math.h', str(harness), '-o', str(binary)], env=self.env, check=True)
        destination = self.home / 'bounds-cache'
        result = subprocess.run([str(binary), str(destination)], env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, 'native count/rounding harness: ' + str(result.returncode))
        for i, expected in enumerate(('0.00', '1.23', '9999.99', '9999.99', '9999.99', '9999.99', '9999.99')):
            self.assertEqual((destination / f'record.{i}').read_text().split()[5], expected)
        self.assertEqual(list(destination.glob('.snapshot.*')), [])

    def test_native_cache_deletion_and_replacement(self):
        binary = self.native_binary()
        for action in ('delete', 'replace'):
            destination = self.home / ('native-' + action)
            proc = subprocess.Popen([str(binary), '500', str(destination)], env=self.env, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not (destination / 'snapshot').exists() and proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                if not (destination / 'snapshot').exists():
                    proc.terminate()
                    diagnostics = proc.communicate(timeout=2)[1].decode()
                    if 'Operation not permitted' in diagnostics and os.environ.get('GITHUB_ACTIONS') != 'true':
                        self.skipTest('native sampling blocked by sandbox: ' + diagnostics.strip())
                    self.fail('native sampler did not publish: ' + diagnostics)
                self.check_snapshot(destination / 'snapshot', 0o600)
                if action == 'delete':
                    (destination / 'snapshot').unlink()
                    destination.rmdir()
                else:
                    destination.rename(self.home / 'old-native-cache')
                    destination.mkdir(mode=0o700)
                started = time.monotonic()
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    self.fail('sampler stayed alive after cache ' + action + ' for two intervals')
                self.assertNotEqual(proc.returncode, 0)
                self.assertLessEqual(time.monotonic() - started, 1.0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate(timeout=2)

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
        binary = self.native_binary()
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
    parser.add_argument('--rendered-init-json', default=os.environ.get('STASYSMO_TEST_INIT_JSON'),
                        help='OPS output from stasysmo-init-eval.nix for full Nix/fish round-trip')
    parser.add_argument('--case', help='single unittest method name')
    parser.add_argument('--suite', choices=('all', 'layout', 'reader', 'daemon'), default='all')
    args, remaining = parser.parse_known_args()
    RENDERED_INIT_JSON = args.rendered_init_json
    if args.benchmark:
        benchmark(args.benchmark_path)
        raise SystemExit(0)
    classes = {'reader': ReaderTests, 'layout': LayoutTests, 'daemon': DaemonTests}
    chosen = classes.values() if args.suite == 'all' else [classes[args.suite]]
    suite = unittest.TestSuite(unittest.TestSuite([cls(args.case)]) if args.case else unittest.defaultTestLoader.loadTestsFromTestCase(cls) for cls in chosen)
    outcome = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not outcome.wasSuccessful())
