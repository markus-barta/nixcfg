"""Focused tests for the paper IB Gateway session supervisor — HOSTD-58."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
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

    def test_flood_beyond_tail_80_preserves_current_generation_login(self) -> None:
        started = 9200.0
        auth = "1970-01-01T02:46:40.000000Z Attempt 1 Authenticating\n"
        flood = [
            f"1970-01-01T02:46:41.{i:06d}Z socat[1] N opening connection from 127.0.0.1\n"
            for i in range(90)
        ]
        lines = [auth, *flood]
        naive_tail = "".join(lines[-80:])
        naive = sup.filter_logs_to_generation(naive_tail, started)
        self.assertEqual(sup.login_state_from_log(naive), sup.LOGIN_UNKNOWN)
        collected = sup.collect_meaningful_events_from_lines(lines, started)
        self.assertEqual(collected.kind, "ok")
        self.assertNotIn("socat", collected.text.lower())
        self.assertEqual(sup.login_state_from_log(collected.text), sup.LOGIN_AUTHENTICATING)
        self.assertGreater(collected.scanned_lines, 80)
        self.assertEqual(collected.kept_lines, 1)

    def test_collector_drops_previous_generation_stale_events(self) -> None:
        started = 9200.0
        lines = [
            "1970-01-01T00:16:40.000000Z 2FA challenge\n",
            "1970-01-01T00:16:41.000000Z Login has completed\n",
            "1970-01-01T02:46:40.000000Z Authenticating\n",
            "1970-01-01T02:46:41.000000Z socat[1] N opening connection\n",
        ]
        collected = sup.collect_meaningful_events_from_lines(lines, started)
        self.assertEqual(collected.kind, "ok")
        state, manual, twofa = sup.classify_login(collected.text, [])
        self.assertEqual(state, sup.LOGIN_AUTHENTICATING)
        self.assertFalse(twofa)
        self.assertIsNone(manual)
        self.assertIsNone(collected.auth_failure_class)

    def test_collector_timeout_or_overflow_is_unknown_not_restart(self) -> None:
        started = 9200.0
        auth = "1970-01-01T02:46:40.000000Z Authenticating\n"
        timed_out = sup.collect_meaningful_events_from_lines(
            [auth],
            started,
            deadline=0.0,
            now_fn=lambda: 1.0,
        )
        self.assertEqual(timed_out.kind, "timeout")
        self.assertEqual(timed_out.text, "")
        overflow_scan = sup.collect_meaningful_events_from_lines(
            ["1970-01-01T02:46:40.000000Z socat flood\n"] * 5,
            started,
            max_scan_lines=3,
        )
        self.assertEqual(overflow_scan.kind, "overflow")
        self.assertEqual(overflow_scan.text, "")
        overflow_keep = sup.collect_meaningful_events_from_lines(
            [
                "1970-01-01T02:46:40.000000Z Authenticating\n",
                "1970-01-01T02:46:41.000000Z Authenticating\n",
                "1970-01-01T02:46:42.000000Z Authenticating\n",
            ],
            started,
            max_keep_lines=2,
        )
        self.assertEqual(overflow_keep.kind, "overflow")
        self.assertEqual(overflow_keep.text, "")
        for failed in (timed_out, overflow_scan, overflow_keep):
            observation = obs(
                login_state=sup.LOGIN_UNKNOWN,
                probe_unknown=True,
                probe_reason=f"docker login-log {failed.kind}; not restarting or resetting budget",
                container_generation="deadbeef0123:424242",
            )
            decision = sup.decide(observation, sup.SupervisorState(), cfg(Path(tempfile.mkdtemp())))
            self.assertEqual(decision.action, sup.ACTION_NONE)
            self.assertEqual(decision.phase, sup.PHASE_UNKNOWN)
            self.assertEqual(decision.persist.restarts_this_outage, 0)

    def test_collector_preserves_real_login_chronology_despite_flood(self) -> None:
        started = 9200.0
        flood = ["1970-01-01T02:46:41.000000Z socat[1] N opening connection\n"] * 90
        lines = [
            "1970-01-01T02:46:40.000000Z Authenticating\n",
            *flood,
            "1970-01-01T02:47:40.000000Z Login has completed\n",
            *flood,
        ]
        naive = sup.filter_logs_to_generation("".join(lines[-80:]), started)
        self.assertEqual(sup.login_state_from_log(naive), sup.LOGIN_UNKNOWN)
        collected = sup.collect_meaningful_events_from_lines(lines, started)
        self.assertEqual(collected.kind, "ok")
        self.assertEqual(sup.login_state_from_log(collected.text), sup.LOGIN_LOGGED_IN)
        _, _, twofa = sup.classify_login(collected.text, [])
        self.assertFalse(twofa)

    def test_auth_failure_classes_are_named_and_not_2fa(self) -> None:
        started = 9200.0
        cases = [
            (
                "1970-01-01T02:46:40.000000Z Authenticating\n"
                "1970-01-01T02:47:40.000000Z Connectivity between TWS and server is broken 2110\n",
                sup.AUTH_CLASS_UPSTREAM_UNAVAILABLE,
                sup.LOGIN_AUTHENTICATING,
            ),
            (
                "1970-01-01T02:46:40.000000Z session conflict: already logged in from another computer\n",
                sup.AUTH_CLASS_SESSION_CONFLICT,
                sup.LOGIN_UNKNOWN,
            ),
            (
                "1970-01-01T02:46:40.000000Z invalid username or password\n",
                sup.AUTH_CLASS_INVALID_CREDENTIALS,
                sup.LOGIN_UNKNOWN,
            ),
            (
                "1970-01-01T02:46:40.000000Z SSL handshake failed\n",
                sup.AUTH_CLASS_TLS,
                sup.LOGIN_UNKNOWN,
            ),
        ]
        for blob, expected_class, login in cases:
            collected = sup.collect_meaningful_events_from_lines(blob.splitlines(keepends=True), started)
            self.assertEqual(collected.kind, "ok", expected_class)
            self.assertEqual(collected.auth_failure_class, expected_class)
            state, manual, twofa = sup.classify_login(collected.text, [])
            self.assertEqual(state, login)
            self.assertFalse(twofa)
            self.assertIsNone(manual)
            decision = sup.decide(
                obs(
                    login_state=state,
                    auth_failure_class=expected_class,
                    twofa_evidence=False,
                    container_started_at=NOW - 60,
                    container_generation="deadbeef0123:424242",
                ),
                sup.SupervisorState(),
                cfg(Path(tempfile.mkdtemp())),
            )
            self.assertNotIn("2FA", decision.reason)
            self.assertIn(f"auth-class:{expected_class}", decision.notes)
            self.assertEqual(decision.action, sup.ACTION_NONE)

    def test_login_log_argv_is_since_not_unbounded_tail(self) -> None:
        argv = sup.docker_login_logs_argv(cfg(Path(tempfile.mkdtemp())), 9200.0)
        self.assertNotIn("--tail", argv)
        self.assertNotIn("--follow", argv)
        self.assertIn("--since", argv)
        self.assertIn("--timestamps", argv)
        self.assertEqual(argv[-1], "ib-gateway")
        self.assertNotIn("80", argv)


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

    def test_iter_fd_lines_yields_complete_lines(self) -> None:
        r_fd, w_fd = os.pipe()
        try:
            os.write(w_fd, b"one\npartial")
            os.write(w_fd, b"-two\n")
            os.close(w_fd)
            w_fd = -1
            lines = list(sup._iter_fd_lines(r_fd, time.monotonic() + 1))
        finally:
            os.close(r_fd)
            if w_fd >= 0:
                os.close(w_fd)
        self.assertEqual(lines, ["one\n", "partial-two\n"])

    def test_newline_free_raw_read_hits_buffer_cap(self) -> None:
        r_fd, w_fd = os.pipe()
        try:
            os.write(w_fd, b"x" * 4096)
            os.close(w_fd)
            w_fd = -1
            with self.assertRaises(sup.CollectBoundExceeded):
                list(
                    sup._iter_fd_lines(
                        r_fd,
                        time.monotonic() + 1,
                        max_buf_bytes=1024,
                        max_raw_bytes=64 * 1024,
                    )
                )
        finally:
            os.close(r_fd)
            if w_fd >= 0:
                os.close(w_fd)

    def test_stderr_stdout_multiplex_drains_and_orders_by_timestamp(self) -> None:
        started = 9200.0
        out_r, out_w = os.pipe()
        err_r, err_w = os.pipe()
        kinds: list[str] = []

        def fill_stderr() -> None:
            os.write(err_w, b"1970-01-01T02:46:40.000000Z Authenticating\n")
            os.write(err_w, b"permission denied\n")
            os.write(err_w, b"1970-01-01T02:46:41.000000Z socat relay\n" * 4000)
            os.close(err_w)

        try:
            os.write(out_w, b"1970-01-01T02:47:40.000000Z Login has completed\n")
            os.close(out_w)
            out_w = -1
            writer = threading.Thread(target=fill_stderr)
            writer.start()
            lines = list(
                sup._iter_multiplexed_log_lines(
                    out_r,
                    err_r,
                    time.monotonic() + 2,
                    client_kinds=kinds,
                )
            )
            writer.join(2)
            self.assertFalse(writer.is_alive())
        finally:
            os.close(out_r)
            os.close(err_r)
            if out_w >= 0:
                os.close(out_w)
        joined = "".join(lines)
        self.assertNotIn("permission denied", joined.lower())
        self.assertIn("permission", kinds)
        collected = sup.collect_meaningful_events_from_lines(lines, started)
        self.assertEqual(collected.kind, "ok")
        self.assertEqual(sup.login_state_from_log(collected.text), sup.LOGIN_LOGGED_IN)
        self.assertNotIn("socat", collected.text.lower())

    def test_lookback_window_retains_auth_and_recognizes_health(self) -> None:
        started = NOW - 3 * 3600
        since = sup.login_logs_since_epoch(started, NOW)
        self.assertGreater(since, started)
        self.assertAlmostEqual(since, NOW - sup.LOG_LOOKBACK_SEC, delta=0.01)
        self.assertEqual(sup.login_logs_since_epoch(NOW - 30, NOW), NOW - 30)
        argv = sup.docker_login_logs_argv(cfg(Path(tempfile.mkdtemp())), since)
        self.assertIn(sup.docker_since_stamp(since), argv)
        self.assertNotIn(sup.docker_since_stamp(started), argv)
        self.assertNotIn("--tail", argv)
        recent = ["1970-01-01T02:46:41.000000Z socat[1] N opening connection\n"] * 90
        collected = sup.collect_meaningful_events_from_lines(recent, started)
        self.assertEqual(collected.kind, "ok")
        self.assertEqual(sup.login_state_from_log(collected.text), sup.LOGIN_UNKNOWN)
        generation = "deadbeef0123:424242"
        decision = sup.decide(
            obs(
                api_listening=True,
                login_state=sup.LOGIN_UNKNOWN,
                container_started_at=started,
                container_generation=generation,
                pusher=pusher(gateway=True),
            ),
            sup.SupervisorState(
                login_state=sup.LOGIN_LOGGED_IN,
                login_generation=generation,
            ),
            cfg(Path(tempfile.mkdtemp())),
        )
        self.assertEqual(decision.phase, sup.PHASE_API_READY)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertEqual(decision.persist.login_state, sup.LOGIN_LOGGED_IN)
        self.assertIn("login-persisted-across-relay-spam", decision.notes)
        self.assertIn("recovery-reset", decision.notes)
        self.assertNotEqual(decision.phase, sup.PHASE_UNKNOWN)

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

        with mock.patch.object(
            sup, "observe_login_logs", return_value=sup.LogCollectResult(kind="ok", text="")
        ):
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

    def test_observe_login_log_overflow_unknown_does_not_restart(self) -> None:
        init = fake_proc1_stat(424242) + "btime 1700000000\n"

        def fake_docker(_cfg: sup.Config, args: list[str], timeout: int = 15) -> sup.DockerResult:
            del timeout
            joined = " ".join(args)
            if args[:1] == ["ps"]:
                return sup.DockerResult(kind="ok", stdout="deadbeef0123\tUp 3 hours\n")
            if "/proc/1/stat" in joined:
                return sup.DockerResult(kind="ok", stdout=init)
            if "/proc/net/tcp" in joined:
                return sup.DockerResult(kind="ok", stdout=PROC_RELAY_ONLY)
            return sup.DockerResult(kind="ok", stdout="")

        for kind in ("overflow", "timeout", "nonzero"):
            with self.subTest(kind=kind):
                with mock.patch.object(sup, "docker_command", side_effect=fake_docker):
                    with mock.patch.object(
                        sup,
                        "observe_login_logs",
                        return_value=sup.LogCollectResult(kind=kind),
                    ):
                        observation = sup.observe_runtime(self.cfg, now=NOW)
                self.assertTrue(observation.probe_unknown)
                self.assertEqual(observation.login_state, sup.LOGIN_UNKNOWN)
                self.assertIs(observation.api_listening, False)
                self.assertIn(kind, observation.probe_reason or "")
                prior = sup.SupervisorState(restarts_this_outage=0)
                decision = sup.decide(observation, prior, self.cfg)
                self.assertEqual(decision.action, sup.ACTION_NONE)
                self.assertEqual(decision.phase, sup.PHASE_UNKNOWN)
                self.assertEqual(decision.persist.restarts_this_outage, 0)

    def test_partial_login_then_read_failure_is_unknown_not_restart(self) -> None:
        r_fd, w_fd = os.pipe()
        seen: list[str] = []
        try:
            os.write(w_fd, b"1970-01-01T02:46:40.000000Z Authenticating\n")
            calls = {"n": 0}
            real_select = sup.select.select

            def fake_select(rlist, wlist, xlist, timeout=None):
                calls["n"] += 1
                if calls["n"] == 1:
                    return real_select(rlist, wlist, xlist, timeout)
                raise OSError("selector failed")

            with mock.patch.object(sup.select, "select", fake_select):
                with self.assertRaises(sup.CollectReadFailed):
                    for line in sup._iter_multiplexed_log_lines(
                        r_fd, None, time.monotonic() + 1
                    ):
                        seen.append(line)
            self.assertTrue(any("Authenticating" in line for line in seen))
        finally:
            os.close(r_fd)
            os.close(w_fd)

        def failing_iter(*_args, **_kwargs):
            yield "1970-01-01T02:46:40.000000Z Authenticating\n"
            raise sup.CollectReadFailed("select failed")

        class DummyStream:
            def fileno(self) -> int:
                return 0

            def close(self) -> None:
                return None

        class DummyProc:
            stdout = DummyStream()
            stderr = DummyStream()
            returncode = 0

            def poll(self) -> int:
                return 0

            def wait(self, timeout: float | None = None) -> int:
                del timeout
                return 0

            def kill(self) -> None:
                return None

        init = fake_proc1_stat(424242) + "btime 1700000000\n"

        def fake_docker(_cfg: sup.Config, args: list[str], timeout: int = 15) -> sup.DockerResult:
            del timeout
            joined = " ".join(args)
            if args[:1] == ["ps"]:
                return sup.DockerResult(kind="ok", stdout="deadbeef0123\tUp 3 hours\n")
            if "/proc/1/stat" in joined:
                return sup.DockerResult(kind="ok", stdout=init)
            if "/proc/net/tcp" in joined:
                return sup.DockerResult(kind="ok", stdout=PROC_RELAY_ONLY)
            return sup.DockerResult(kind="ok", stdout="")

        with mock.patch.object(sup.subprocess, "Popen", return_value=DummyProc()):
            with mock.patch.object(sup, "_iter_multiplexed_log_lines", side_effect=failing_iter):
                with mock.patch.object(sup, "docker_command", side_effect=fake_docker):
                    observation = sup.observe_runtime(self.cfg, now=NOW)
        self.assertTrue(observation.probe_unknown)
        self.assertEqual(observation.login_state, sup.LOGIN_UNKNOWN)
        self.assertNotEqual(observation.login_state, sup.LOGIN_AUTHENTICATING)
        prior = sup.SupervisorState(restarts_this_outage=1)
        decision = sup.decide(observation, prior, self.cfg)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertEqual(decision.phase, sup.PHASE_UNKNOWN)
        self.assertEqual(decision.persist.restarts_this_outage, 1)

    def test_observe_flood_login_is_authenticating_not_unknown(self) -> None:
        init = fake_proc1_stat(424242) + "btime 1700000000\n"
        collected = sup.LogCollectResult(
            kind="ok",
            text="1970-01-01T02:46:40.000000Z Authenticating",
            kept_lines=1,
        )

        def fake_docker(_cfg: sup.Config, args: list[str], timeout: int = 15) -> sup.DockerResult:
            del timeout
            joined = " ".join(args)
            if args[:1] == ["ps"]:
                return sup.DockerResult(kind="ok", stdout="deadbeef0123\tUp 10 minutes\n")
            if "/proc/1/stat" in joined:
                return sup.DockerResult(kind="ok", stdout=init)
            if "/proc/net/tcp" in joined:
                return sup.DockerResult(kind="ok", stdout=PROC_RELAY_ONLY)
            return sup.DockerResult(kind="ok", stdout="")

        with mock.patch.object(sup, "docker_command", side_effect=fake_docker):
            with mock.patch.object(sup, "observe_login_logs", return_value=collected):
                observation = sup.observe_runtime(self.cfg, now=NOW)
        self.assertFalse(observation.probe_unknown)
        self.assertEqual(observation.login_state, sup.LOGIN_AUTHENTICATING)
        decision = sup.decide(observation, sup.SupervisorState(), self.cfg)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertEqual(decision.phase, sup.PHASE_AUTHENTICATING)
        self.assertNotEqual(decision.action, sup.ACTION_RESTART)


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
