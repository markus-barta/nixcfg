"""Focused tests for the paper IB Gateway session supervisor — HOSTD-58."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
ENGINE_DIR = REPO / "modules" / "shared" / "fleet-alerts"
SCRIPT = REPO / "modules" / "ib-gateway-session" / "supervisor.py"

sys.path.insert(0, str(ENGINE_DIR))
SPEC = importlib.util.spec_from_file_location("ib_gateway_session", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load ib-gateway session supervisor")
sup = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sup
SPEC.loader.exec_module(sup)

NOW = 1_780_000_000.0
# Same shape as tests/test_fleet_alerts_engine.py — tests only, never the helper.
FAKE_SHOUTRRR = "telegram://12345:AAbb--cc_ddeeffgghhiijj@telegram?chats=-100123"
PROC_RELAY_ONLY = """
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0FA4 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1
"""
PROC_API_AND_RELAY = PROC_RELAY_ONLY + "\n   1: 00000000:0FA2 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2\n"
PROC_TIME_WAIT_AND_REMOTE = """
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0FA4 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1
   1: 00000000:0FA2 0100007F:1234 06 00000000:00000000 00:00000000 00000000     0        0 2
   2: 0100007F:1234 00000000:0FA2 0A 00000000:00000000 00:00000000 00000000     0        0 3
"""
HISTORY = json.dumps(
    {
        "identities": ["fill-1"],
        "coverageDay": "2026-09-10",
        "generatedAt": "2026-09-12T03:48:00+02:00",
        "historyBasis": "joel.stage0-keep-excluded.v1",
    }
)
PUSH_DOWN = json.dumps(
    {
        "ok": True,
        "status": 200,
        "equity": 1234.5,
        "generatedAt": "2026-09-12T03:48:00+02:00",
        "gateway": False,
        "lastError": "broker upstream_lost (code 2110)",
    }
)
PUSH_UP = json.dumps(
    {
        "ok": True,
        "status": 200,
        "equity": 1234.5,
        "generatedAt": "2026-09-12T03:48:00+02:00",
        "gateway": True,
    }
)


def cfg(directory: Path, **overrides) -> sup.Config:
    values = dict(
        state_path=str(directory / "supervisor.json"),
        alert_state_path=str(directory / "alerts.json"),
        operator_clear_path=str(directory / "operator-clear"),
        compose_lock=str(directory / "compose-hsb0.lock"),
        compose_file="/etc/compose/hsb0/docker-compose.yml",
        compose_project="docker",
        compose_project_dir="/home/mba/Code/nixcfg/hosts/hsb0/docker",
        compose_bin="docker-compose",
        flock_bin="flock",
        alert_enable=False,
        alert_transport="none",
    )
    values.update(overrides)
    return sup.Config(**values)


def alert_ready_cfg(directory: Path, **overrides) -> sup.Config:
    env_path = directory / "watchtower.env"
    env_path.write_text(f"WATCHTOWER_NOTIFICATION_URL={FAKE_SHOUTRRR}\n", encoding="utf-8")
    return cfg(
        directory,
        alert_enable=True,
        alert_transport="shoutrrr",
        notification_env=str(env_path),
        **overrides,
    )


def obs(**overrides) -> sup.Observation:
    values = dict(
        now=NOW,
        container_running=True,
        container_started_at=NOW - 3 * 3600,
        relay_open=True,
        api_listening=False,
        login_state=sup.LOGIN_LOGGED_OUT,
        authenticating_since=None,
        manual_action=None,
        twofa_evidence=False,
        pusher=None,
        operator_clear=False,
        lock_available=True,
    )
    values.update(overrides)
    return sup.Observation(**values)


def fake_proc1_stat(start_ticks: int = 424242) -> str:
    after = ["S", "0", "1", "1", "0", "-1", "1077936192"] + ["0"] * 12
    after.append(str(start_ticks))
    return "1 (tini) " + " ".join(after) + "\n"


def pusher(
    *,
    gateway: bool,
    generated: str = "2026-09-12T03:48:00+02:00",
    observed_at: float | None = NOW,
    observed_at_raw: str | None = "2026-05-25T12:26:40.000000Z",
) -> sup.PusherView:
    return sup.PusherView(
        gateway=gateway,
        generated_at=sup.parse_iso_seconds(generated),
        generated_at_raw=generated,
        source="live_push_log",
        last_error=None if gateway else "broker upstream_lost (code 2110)",
        observed_at=observed_at,
        observed_at_raw=observed_at_raw,
    )


class ParseHelpers(unittest.TestCase):
    def test_relay_open_api_absent_from_proc_net(self) -> None:
        ports = sup.parse_listening_ports(PROC_RELAY_ONLY)
        self.assertIn(4004, ports)
        self.assertNotIn(4002, ports)

    def test_api_and_relay_listen(self) -> None:
        ports = sup.parse_listening_ports(PROC_API_AND_RELAY)
        self.assertEqual({4002, 4004}, ports)

    def test_time_wait_and_remote_0fa2_are_not_listening(self) -> None:
        ports = sup.parse_listening_ports(PROC_TIME_WAIT_AND_REMOTE)
        self.assertIn(4004, ports)
        self.assertNotIn(4002, ports)

    def test_history_generated_at_is_rejected(self) -> None:
        self.assertIsNone(sup.parse_pusher_published_state(HISTORY))

    def test_live_push_line_is_accepted(self) -> None:
        view = sup.parse_pusher_published_state(PUSH_DOWN)
        self.assertIsNotNone(view)
        self.assertFalse(view.gateway)
        self.assertEqual(view.generated_at_raw, "2026-09-12T03:48:00+02:00")
        self.assertEqual(view.source, "live_push_log")
        self.assertIsNone(view.observed_at)

    def test_timestamped_quiet_book_keeps_still_generated_at(self) -> None:
        line = "2026-05-25T12:26:40.000000Z " + PUSH_UP
        view = sup.parse_pusher_published_state(line)
        self.assertIsNotNone(view)
        self.assertTrue(view.gateway)
        self.assertEqual(view.generated_at_raw, "2026-09-12T03:48:00+02:00")
        self.assertEqual(view.observed_at_raw, "2026-05-25T12:26:40.000000Z")
        self.assertIsNotNone(view.observed_at)

    def test_generation_identity_is_id_and_startticks_not_rounded_age(self) -> None:
        ten = NOW - 10 * 60
        eleven = NOW - 11 * 60
        self.assertNotEqual(ten, eleven)
        self.assertEqual(
            sup.format_container_generation("deadbeef0123", 424242),
            sup.format_container_generation("deadbeef0123", 424242),
        )
        self.assertNotEqual(
            sup.format_container_generation("deadbeef0123", 424242),
            sup.format_container_generation("deadbeef0123", 424243),
        )
        self.assertNotEqual(
            sup.format_container_generation("deadbeef0123", 424242),
            sup.format_container_generation("cafef00d9999", 424242),
        )

    def test_parse_proc1_startticks_and_btime_epoch(self) -> None:
        stat = fake_proc1_stat(424242)
        self.assertEqual(sup.parse_proc1_startticks(stat), 424242)
        self.assertEqual(sup.parse_proc_btime("cpu 1\nbtime 1700000000\nintr 0\n"), 1700000000)
        self.assertEqual(
            sup.start_epoch_from_proc(1_700_000_000, 424242, ticks_per_sec=100),
            1_700_000_000 + 4242.42,
        )
        cid, status = sup.parse_docker_ps_id_status("deadbeef0123\tUp 10 minutes")
        self.assertEqual(cid, "deadbeef0123")
        self.assertEqual(status, "Up 10 minutes")
        cid11, status11 = sup.parse_docker_ps_id_status("deadbeef0123\tUp 11 minutes")
        self.assertEqual(cid11, cid)
        self.assertNotEqual(status, status11)

    def test_login_authenticating_is_not_2fa(self) -> None:
        state, manual, twofa = sup.classify_login(
            "LOGGED_OUT\nAttempt2Authenticating", []
        )
        self.assertEqual(state, sup.LOGIN_AUTHENTICATING)
        self.assertIsNone(manual)
        self.assertFalse(twofa)

    def test_authenticating_then_login_completed_is_logged_in(self) -> None:
        state, manual, twofa = sup.classify_login(
            "Authenticating\nLogin has completed", []
        )
        self.assertEqual(state, sup.LOGIN_LOGGED_IN)
        self.assertIsNone(manual)
        self.assertFalse(twofa)

    def test_pre_start_login_and_2fa_logs_do_not_classify_new_generation(self) -> None:
        blob = (
            "1970-01-01T00:16:40.000000Z 2FA challenge\n"
            "1970-01-01T00:16:41.000000Z Login has completed\n"
        )
        raw_state, _, raw_twofa = sup.classify_login(blob, [])
        self.assertEqual(raw_state, sup.LOGIN_LOGGED_IN)
        self.assertTrue(raw_twofa)
        filtered = sup.filter_logs_to_generation(blob, 9200.0)
        self.assertEqual(filtered, "")
        state, manual, twofa = sup.classify_login(filtered, [])
        self.assertEqual(state, sup.LOGIN_UNKNOWN)
        self.assertFalse(twofa)
        self.assertIsNone(manual)
        kept = sup.filter_logs_to_generation(
            blob + "1970-01-01T02:46:40.000000Z Authenticating\n", 9200.0
        )
        state2, _, twofa2 = sup.classify_login(kept, [])
        self.assertEqual(state2, sup.LOGIN_AUTHENTICATING)
        self.assertFalse(twofa2)

    def test_fullauthrequired_is_manual_with_evidence(self) -> None:
        state, manual, twofa = sup.classify_login("Authenticating", ["fullauthrequired"])
        self.assertEqual(manual, sup.MANUAL_FULLAUTH)
        self.assertTrue(twofa)
        self.assertEqual(state, sup.LOGIN_AUTHENTICATING)


class DecisionMatrix(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.cfg = cfg(self.dir)

    def test_relay_open_api_absent_restarts_once(self) -> None:
        decision = sup.decide(obs(), sup.SupervisorState(), self.cfg)
        self.assertEqual(decision.action, sup.ACTION_RESTART)
        self.assertEqual(decision.persist.restarts_this_outage, 0)
        self.assertIn("4002", decision.reason)

    def test_startup_grace_from_recent_container_start(self) -> None:
        decision = sup.decide(
            obs(container_started_at=NOW - 8 * 60, login_state=sup.LOGIN_AUTHENTICATING),
            sup.SupervisorState(),
            self.cfg,
        )
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertEqual(decision.phase, sup.PHASE_AUTHENTICATING)
        self.assertIn("grace", decision.reason)

    def test_known_recent_restart_starts_grace(self) -> None:
        prior = sup.SupervisorState(last_restart_at=NOW - 120, restarts_this_outage=1)
        decision = sup.decide(obs(), prior, self.cfg)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertIn(decision.phase, {sup.PHASE_SLOWSTARTING, sup.PHASE_AUTHENTICATING})

    def test_prolonged_auth_halts_without_2fa_label(self) -> None:
        prior = sup.SupervisorState(authenticating_since=NOW - 20 * 60)
        decision = sup.decide(
            obs(login_state=sup.LOGIN_AUTHENTICATING),
            prior,
            self.cfg,
        )
        self.assertEqual(decision.action, sup.ACTION_HALT)
        self.assertEqual(decision.phase, sup.PHASE_HALTED)
        self.assertNotIn("2FA", decision.reason)
        self.assertNotIn("2FA", decision.alert_problem.text)
        self.assertIn("prolonged-auth-not-labeled-2fa", decision.notes)

    def test_upstream_outage_with_api_alive_restarts_once(self) -> None:
        decision = sup.decide(
            obs(api_listening=True, pusher=pusher(gateway=False)),
            sup.SupervisorState(),
            self.cfg,
        )
        self.assertEqual(decision.phase, sup.PHASE_UPSTREAM_UNAVAILABLE)
        self.assertEqual(decision.action, sup.ACTION_RESTART)
        self.assertEqual(decision.persist.restarts_this_outage, 0)

    def test_budget_persists_and_second_attempt_halts(self) -> None:
        first = sup.decide(
            obs(api_listening=True, pusher=pusher(gateway=False)),
            sup.SupervisorState(),
            self.cfg,
        )
        spent = first.persist
        spent.restarts_this_outage = 1
        later_now = NOW + 20 * 60
        later = obs(
            now=later_now,
            container_started_at=NOW - 3 * 3600,
            api_listening=True,
            pusher=pusher(gateway=False, observed_at=later_now),
        )
        second = sup.decide(later, spent, self.cfg)
        self.assertEqual(second.action, sup.ACTION_HALT)
        self.assertTrue(second.persist.operator_clear_required)
        self.assertEqual(second.persist.restarts_this_outage, 1)

    def test_recovery_reset_only_on_real_healthy(self) -> None:
        prior = sup.SupervisorState(
            restarts_this_outage=1,
            last_restart_at=NOW - 20 * 60,
            halt_reason="budget",
            operator_clear_required=True,
        )
        tcp_only = sup.decide(
            obs(api_listening=True, pusher=None),
            prior,
            self.cfg,
        )
        self.assertEqual(tcp_only.action, sup.ACTION_NONE)
        self.assertEqual(tcp_only.persist.restarts_this_outage, 1)
        self.assertNotIn("recovery-reset", tcp_only.notes)

        healthy = sup.decide(
            obs(api_listening=True, pusher=pusher(gateway=True)),
            prior,
            self.cfg,
        )
        self.assertEqual(healthy.phase, sup.PHASE_API_READY)
        self.assertEqual(healthy.persist.restarts_this_outage, 0)
        self.assertIsNone(healthy.persist.halt_reason)
        self.assertIn("recovery-reset", healthy.notes)

    def test_quiet_book_still_generated_at_is_healthy_when_publish_is_current(self) -> None:
        decision = sup.decide(
            obs(api_listening=True, pusher=pusher(gateway=True)),
            sup.SupervisorState(restarts_this_outage=1),
            self.cfg,
        )
        self.assertEqual(decision.phase, sup.PHASE_API_READY)
        self.assertEqual(decision.action, sup.ACTION_NONE)

    def test_old_gateway_true_before_start_does_not_reset_budget(self) -> None:
        started = NOW - 3 * 3600
        prior = sup.SupervisorState(restarts_this_outage=1, last_restart_at=NOW - 20 * 60)
        decision = sup.decide(
            obs(
                api_listening=True,
                container_started_at=started,
                pusher=pusher(gateway=True, observed_at=started - 30),
            ),
            prior,
            self.cfg,
        )
        self.assertNotEqual(decision.phase, sup.PHASE_API_READY)
        self.assertEqual(decision.persist.restarts_this_outage, 1)
        self.assertNotIn("recovery-reset", decision.notes)
        self.assertIn("pre-start-or-stale-publish-ignored", decision.notes)

    def test_restart_argv_is_allowlisted_ib_gateway_compose_only(self) -> None:
        argv = sup.restart_argv(self.cfg)
        self.assertEqual(argv[-1], "ib-gateway")
        self.assertIn("restart", argv)
        self.assertIn("--no-deps", argv)
        self.assertNotIn(self.cfg.compose_lock, argv)
        self.assertNotIn("up", argv)
        self.assertNotIn("--force-recreate", argv)
        with self.assertRaises(ValueError):
            sup.restart_argv(self.cfg, "joe-board-pusher")

    def test_login_persists_across_relay_spam_same_generation(self) -> None:
        generation = "deadbeef0123:424242"
        prior = sup.SupervisorState(
            login_state=sup.LOGIN_LOGGED_IN,
            login_generation=generation,
        )
        decision = sup.decide(
            obs(
                login_state=sup.LOGIN_UNKNOWN,
                container_generation=generation,
                container_started_at=NOW - 3 * 3600,
            ),
            prior,
            self.cfg,
        )
        self.assertIn("login-persisted-across-relay-spam", decision.notes)
        self.assertEqual(decision.persist.login_state, sup.LOGIN_LOGGED_IN)

    def test_rounded_status_age_does_not_change_generation(self) -> None:
        generation = "deadbeef0123:424242"
        prior = sup.SupervisorState(
            login_state=sup.LOGIN_LOGGED_IN,
            login_generation=generation,
        )
        ten = sup.decide(
            obs(
                login_state=sup.LOGIN_UNKNOWN,
                container_generation=generation,
                container_started_at=NOW - 10 * 60,
            ),
            prior,
            self.cfg,
        )
        eleven = sup.decide(
            obs(
                login_state=sup.LOGIN_UNKNOWN,
                container_generation=generation,
                container_started_at=NOW - 11 * 60,
            ),
            ten.persist,
            self.cfg,
        )
        self.assertEqual(ten.persist.login_generation, generation)
        self.assertEqual(eleven.persist.login_state, sup.LOGIN_LOGGED_IN)
        self.assertEqual(eleven.persist.login_generation, generation)
        self.assertIn("login-persisted-across-relay-spam", eleven.notes)

    def test_login_clears_on_new_container_generation(self) -> None:
        prior = sup.SupervisorState(
            login_state=sup.LOGIN_LOGGED_IN,
            login_generation="deadbeef0123:424242",
        )
        decision = sup.decide(
            obs(
                login_state=sup.LOGIN_UNKNOWN,
                container_generation="deadbeef0123:424243",
                container_started_at=NOW - 60,
            ),
            prior,
            self.cfg,
        )
        self.assertNotIn("login-persisted-across-relay-spam", decision.notes)
        self.assertIsNone(decision.persist.login_state)

    def test_new_container_id_is_actual_restart(self) -> None:
        prior = sup.SupervisorState(
            login_state=sup.LOGIN_LOGGED_IN,
            login_generation="deadbeef0123:424242",
        )
        decision = sup.decide(
            obs(
                login_state=sup.LOGIN_UNKNOWN,
                container_generation="cafef00d9999:424242",
                container_started_at=NOW - 60,
            ),
            prior,
            self.cfg,
        )
        self.assertIsNone(decision.persist.login_state)
        self.assertIsNone(decision.persist.login_generation)

    def test_changed_generation_resets_auth_clock_before_new_logs(self) -> None:
        prior = sup.SupervisorState(
            phase=sup.PHASE_AUTHENTICATING,
            login_state=sup.LOGIN_AUTHENTICATING,
            login_generation="oldid:1",
            authenticating_since=1000.0,
        )
        decision = sup.decide(
            obs(
                now=10000.0,
                container_started_at=9200.0,
                container_generation="newid:2",
                login_state=sup.LOGIN_AUTHENTICATING,
            ),
            prior,
            self.cfg,
        )
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertNotEqual(decision.action, sup.ACTION_HALT)
        self.assertEqual(decision.persist.authenticating_since, 10000.0)
        self.assertEqual(decision.persist.login_generation, "newid:2")
        self.assertIn("generation-changed", decision.notes)
        self.assertLess(
            10000.0 - decision.persist.authenticating_since,
            self.cfg.auth_timeout_sec,
        )

    def test_pusher_without_proc_start_epoch_does_not_reset_budget(self) -> None:
        prior = sup.SupervisorState(restarts_this_outage=1)
        decision = sup.decide(
            obs(
                api_listening=True,
                container_started_at=None,
                pusher=pusher(gateway=True),
            ),
            prior,
            self.cfg,
        )
        self.assertEqual(decision.persist.restarts_this_outage, 1)
        self.assertNotIn("recovery-reset", decision.notes)

    def test_probe_unknown_does_not_restart_or_reset(self) -> None:
        prior = sup.SupervisorState(restarts_this_outage=1)
        decision = sup.decide(
            obs(
                container_running=None,
                api_listening=None,
                probe_unknown=True,
                probe_reason="docker ps timeout",
            ),
            prior,
            self.cfg,
        )
        self.assertEqual(decision.phase, sup.PHASE_UNKNOWN)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertEqual(decision.persist.restarts_this_outage, 1)
        self.assertIn("probe-unknown", decision.notes)

    def test_confirmed_stopped_requests_restart(self) -> None:
        decision = sup.decide(
            obs(container_running=False, api_listening=False, relay_open=False),
            sup.SupervisorState(),
            self.cfg,
        )
        self.assertEqual(decision.action, sup.ACTION_RESTART)
        self.assertEqual(decision.phase, sup.PHASE_CONTAINER_DOWN)


class RestartReservation(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.cfg = cfg(self.dir)

    def test_crash_after_reservation_consumes_budget(self) -> None:
        persist = sup.SupervisorState()

        def boom(_cfg: sup.Config) -> int:
            raise RuntimeError("crash after reservation")

        with self.assertRaises(RuntimeError):
            sup.execute_reserved_restart(
                self.cfg,
                persist,
                NOW,
                boom,
                locker=lambda: True,
                unlocker=lambda _held: None,
            )
        loaded = sup.load_supervisor_state(self.cfg.state_path)
        self.assertEqual(loaded.restarts_this_outage, 1)
        self.assertIsNotNone(loaded.last_restart_at)

    def test_directory_fsync_before_docker_side_effect(self) -> None:
        persist = sup.SupervisorState()
        order: list[str] = []

        def sync(directory: str) -> None:
            self.assertEqual(Path(directory).resolve(), Path(self.dir).resolve())
            loaded = sup.load_supervisor_state(self.cfg.state_path)
            self.assertEqual(loaded.restarts_this_outage, 1)
            order.append("dir_fsync")

        def restarter(_cfg: sup.Config) -> int:
            order.append("docker")
            return 0

        outcome, persist = sup.execute_reserved_restart(
            self.cfg,
            persist,
            NOW,
            restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
            dir_sync=sync,
        )
        self.assertEqual(outcome, "ok")
        self.assertEqual(order, ["dir_fsync", "docker"])
        self.assertEqual(persist.restarts_this_outage, 1)

    def test_nonzero_after_side_effect_does_not_refund(self) -> None:
        persist = sup.SupervisorState()
        outcome, persist = sup.execute_reserved_restart(
            self.cfg,
            persist,
            NOW,
            lambda _cfg: 1,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(outcome, "failed_after_reserve")
        self.assertEqual(persist.restarts_this_outage, 1)
        loaded = sup.load_supervisor_state(self.cfg.state_path)
        self.assertEqual(loaded.restarts_this_outage, 1)

    def test_lock_busy_before_side_effect_preserves_budget(self) -> None:
        persist = sup.SupervisorState()
        calls: list[str] = []

        def restarter(_cfg: sup.Config) -> int:
            calls.append("docker")
            return 0

        outcome, persist = sup.execute_reserved_restart(
            self.cfg,
            persist,
            NOW,
            restarter,
            locker=lambda: None,
            unlocker=lambda _held: None,
        )
        self.assertEqual(outcome, "lock_busy")
        self.assertEqual(persist.restarts_this_outage, 0)
        self.assertEqual(calls, [])
        self.assertFalse(Path(self.cfg.state_path).exists())

    def test_corrupt_state_halts_without_fresh_attempts(self) -> None:
        Path(self.cfg.state_path).write_text("{", encoding="utf-8")
        loaded = sup.load_supervisor_state(self.cfg.state_path)
        self.assertTrue(loaded.corrupt)
        decision = sup.decide(obs(), loaded, self.cfg)
        self.assertEqual(decision.action, sup.ACTION_HALT)
        self.assertGreaterEqual(decision.persist.restarts_this_outage, self.cfg.max_restarts_per_outage)
        Path(self.cfg.state_path).write_text("{}", encoding="utf-8")
        empty = sup.load_supervisor_state(self.cfg.state_path)
        self.assertTrue(empty.corrupt)
        missing = sup.load_supervisor_state(str(self.dir / "absent.json"))
        self.assertFalse(missing.corrupt)
        self.assertEqual(missing.restarts_this_outage, 0)


class DockerProbes(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.cfg = cfg(self.dir)

    def test_docker_timeout_is_unknown(self) -> None:
        with mock.patch.object(
            sup.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("docker", 15),
        ):
            result = sup.docker_command(self.cfg, ["ps"])
        self.assertEqual(result.kind, "timeout")

    def test_docker_permission_is_unknown(self) -> None:
        with mock.patch.object(sup.subprocess, "run", side_effect=PermissionError("denied")):
            result = sup.docker_command(self.cfg, ["ps"])
        self.assertEqual(result.kind, "permission")

    def test_observe_timeout_is_unknown_not_stopped(self) -> None:
        with mock.patch.object(sup, "docker_command", return_value=sup.DockerResult(kind="timeout")):
            observation = sup.observe_runtime(self.cfg, now=NOW)
        self.assertTrue(observation.probe_unknown)
        self.assertIsNone(observation.container_running)
        decision = sup.decide(observation, sup.SupervisorState(), self.cfg)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertEqual(decision.phase, sup.PHASE_UNKNOWN)

    def test_observe_confirmed_stopped_can_restart(self) -> None:
        def fake_docker(_cfg: sup.Config, args: list[str], timeout: int = 15) -> sup.DockerResult:
            del timeout
            if args[:1] == ["ps"]:
                return sup.DockerResult(kind="ok", stdout="Exited (0) 2 minutes ago\n")
            return sup.DockerResult(kind="nonzero", returncode=1)

        with mock.patch.object(sup, "docker_command", side_effect=fake_docker):
            observation = sup.observe_runtime(self.cfg, now=NOW)
        self.assertFalse(observation.probe_unknown)
        self.assertIs(observation.container_running, False)
        self.assertIs(observation.api_listening, False)
        decision = sup.decide(observation, sup.SupervisorState(), self.cfg)
        self.assertEqual(decision.action, sup.ACTION_RESTART)

    def test_observe_generation_stable_across_rounded_status_age(self) -> None:
        init = fake_proc1_stat(424242) + "btime 1700000000\n"

        def fake_docker(status: str):
            def inner(_cfg: sup.Config, args: list[str], timeout: int = 15) -> sup.DockerResult:
                del timeout
                joined = " ".join(args)
                if args[:1] == ["ps"]:
                    return sup.DockerResult(kind="ok", stdout=f"deadbeef0123\t{status}\n")
                if "/proc/1/stat" in joined:
                    return sup.DockerResult(kind="ok", stdout=init)
                if "/proc/net/tcp" in joined:
                    return sup.DockerResult(kind="ok", stdout=PROC_API_AND_RELAY)
                return sup.DockerResult(kind="ok", stdout="")

            return inner

        with mock.patch.object(sup, "docker_command", side_effect=fake_docker("Up 10 minutes")):
            first = sup.observe_runtime(self.cfg, now=NOW)
        with mock.patch.object(sup, "docker_command", side_effect=fake_docker("Up 11 minutes")):
            second = sup.observe_runtime(self.cfg, now=NOW + 60)
        self.assertEqual(first.container_generation, "deadbeef0123:424242")
        self.assertEqual(second.container_generation, first.container_generation)
        self.assertEqual(first.container_started_at, second.container_started_at)
        self.assertEqual(
            first.container_started_at,
            sup.start_epoch_from_proc(1_700_000_000, 424242),
        )
        self.assertNotEqual(NOW - 10 * 60, first.container_started_at)


class AlertAndCycle(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.sent: list[tuple[str, str]] = []
        self.deliver = True
        self.restarts: list[str] = []

    def send(self, text: str, identifier: str) -> bool:
        if not self.deliver:
            return False
        self.sent.append((text, identifier))
        return True

    def restarter(self, _cfg: sup.Config) -> int:
        self.restarts.append("ib-gateway")
        return 0

    def test_disabled_adapter_reports_blocker_and_does_not_claim_delivery(self) -> None:
        conf = cfg(self.dir, alert_enable=False)
        decision, code = sup.run_cycle(
            obs(),
            conf,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(self.restarts, ["ib-gateway"])
        self.assertEqual(decision.persist.restarts_this_outage, 1)
        self.assertTrue(decision.persist.last_alert_status.startswith("not-sent:"))
        self.assertIn("WATCHTOWER_NOTIFICATION_URL", decision.persist.last_alert_status)
        self.assertIn("openclaw-gateway is parked", decision.persist.last_alert_status)
        self.assertEqual(self.sent, [])
        self.assertIn(code, (0, 1))

    def test_alert_failure_is_retried_and_not_double_announced(self) -> None:
        conf = alert_ready_cfg(self.dir)
        unhealthy = obs(api_listening=True, pusher=pusher(gateway=False))
        first, _ = sup.run_cycle(
            unhealthy,
            conf,
            sender=self.send,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(self.restarts, ["ib-gateway"])
        self.assertEqual(self.sent, [])  # CONFIRM_RUNS = 2

        later_now = NOW + 20 * 60
        later = obs(
            now=later_now,
            container_started_at=NOW - 3 * 3600,
            api_listening=True,
            pusher=pusher(gateway=False, observed_at=later_now),
        )
        self.deliver = False
        second, code = sup.run_cycle(
            later,
            conf,
            state=first.persist,
            sender=self.send,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(code, sup.engine.EXIT_UNDELIVERED)
        self.assertEqual(self.sent, [])
        pending = json.loads(Path(conf.alert_state_path).read_text())
        self.assertIsNotNone(pending.get("pending"))

        self.deliver = True
        third, _ = sup.run_cycle(
            later,
            conf,
            state=second.persist,
            sender=self.send,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(len(self.sent), 1)
        self.assertNotIn("2FA", self.sent[0][0])
        fourth, _ = sup.run_cycle(
            later,
            conf,
            state=third.persist,
            sender=self.send,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(len(self.sent), 1, "must not re-announce while the outage persists")

    def test_healthy_clears_alert(self) -> None:
        conf = alert_ready_cfg(self.dir)
        bad = obs(api_listening=True, pusher=pusher(gateway=False))
        first, _ = sup.run_cycle(
            bad,
            conf,
            sender=self.send,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        later_now = NOW + 20 * 60
        later_bad = obs(
            now=later_now,
            container_started_at=NOW - 3 * 3600,
            api_listening=True,
            pusher=pusher(gateway=False, observed_at=later_now),
        )
        second, _ = sup.run_cycle(
            later_bad,
            conf,
            state=first.persist,
            sender=self.send,
            restarter=self.restarter,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(len(self.sent), 1)
        healthy_now = NOW + 40 * 60
        healthy = obs(
            now=healthy_now,
            api_listening=True,
            pusher=pusher(gateway=True, observed_at=healthy_now),
        )
        _, _ = sup.run_cycle(
            healthy,
            conf,
            state=second.persist,
            sender=self.send,
            restarter=lambda _c: 1,
            locker=lambda: True,
            unlocker=lambda _held: None,
        )
        self.assertEqual(len(self.sent), 2)
        self.assertIn("CLEARED", self.sent[1][0])
        self.assertEqual(self.restarts, ["ib-gateway"], "healthy must not restart")


class ActivationBlockers(unittest.TestCase):
    def test_agent_bus_names_openclaw_parked(self) -> None:
        conf = cfg(Path(tempfile.mkdtemp()), alert_enable=True, alert_transport="agent-bus")
        blocker = sup.resolve_alert_blocker(conf, {"openclaw_running": False})
        self.assertIn("openclaw-gateway is not running", blocker)

    def test_shoutrrr_names_missing_env(self) -> None:
        conf = cfg(Path(tempfile.mkdtemp()), alert_enable=True, alert_transport="shoutrrr")
        blocker = sup.resolve_alert_blocker(conf, {"notification_env_present": False})
        self.assertIn("no notification env file", blocker)
        sender, missing = sup.construct_declared_sender(conf)
        self.assertIsNone(sender)
        self.assertIn("notificationEnvFile", missing)

    def test_construct_declared_sender_from_declared_env(self) -> None:
        directory = Path(tempfile.mkdtemp())
        conf = alert_ready_cfg(directory)
        sender, blocker = sup.construct_declared_sender(conf)
        self.assertIsNone(blocker)
        self.assertIsNotNone(sender)
        self.assertTrue(callable(sender))

    def test_construct_declared_sender_missing_key(self) -> None:
        directory = Path(tempfile.mkdtemp())
        env_path = directory / "watchtower.env"
        env_path.write_text("OTHER=1\n", encoding="utf-8")
        conf = cfg(
            directory,
            alert_enable=True,
            alert_transport="shoutrrr",
            notification_env=str(env_path),
        )
        sender, blocker = sup.construct_declared_sender(conf)
        self.assertIsNone(sender)
        self.assertIn("WATCHTOWER_NOTIFICATION_URL missing", blocker)


if __name__ == "__main__":
    unittest.main()
