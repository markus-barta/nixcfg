"""OPS-465: one delayed cold restart for a narrowly proven reset rejection.

Discovered by T77's existing test_ib_gateway*.py runner; no broker calls.
"""

from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
import json
import tempfile
import unittest
from unittest import mock

from test_ib_gateway_session_supervisor import (
    NOW, PROC_API_AND_RELAY, cfg, fake_proc1_stat, obs, pusher, sup,
)


def line(stamp, body):
    return datetime.fromtimestamp(stamp, timezone.utc).isoformat().replace("+00:00", "Z") + " " + body


def signature(rejected_at=NOW - 300, gap=60):
    return [
        line(rejected_at - gap, "IBC: Re-login is required"),
        line(rejected_at, "IBC: Unrecognized Username or Password"),
    ]


def observation(lines, **overrides):
    values = dict(
        now=NOW, container_started_at=NOW - 10800,
        container_generation="fixture:100", container_healthy=True,
        api_listening=True,
    )
    values.update(overrides)
    collected = sup.collect_meaningful_events_from_lines(lines, values["container_started_at"])
    if collected.kind != "ok":
        raise AssertionError(collected.kind)
    login, manual, twofa = sup.classify_login(collected.text, [])
    reset, rejected, recovered = sup.classify_reset_relogin(
        collected.text, values["container_started_at"], values["now"],
    )
    return obs(
        **values, login_state=login, manual_action=manual, twofa_evidence=twofa,
        auth_failure_class=collected.auth_failure_class,
        reset_relogin_rejected_at=reset, login_rejected_at=rejected,
        reset_relogin_recovered=recovered,
    )


class ResetReloginTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.config = cfg(Path(directory.name))
        self.restarts = []

    def restart(self, config):
        # The durable reservation must exist BEFORE any Docker effect.
        reserved = sup.load_supervisor_state(config.state_path)
        self.assertEqual(reserved.restarts_this_outage, 1)
        self.assertTrue(reserved.reset_relogin_restart_pending)
        self.restarts.append(config.container_name)
        return 0

    def cycle(self, current, state=None, config=None, **kwargs):
        with mock.patch("builtins.print"):
            return sup.run_cycle(
                current, config or self.config, state,
                restarter=self.restart, locker=lambda: True,
                unlocker=lambda _held: None, **kwargs,
            )[0]

    def test_exact_signature_waits_then_restarts_once_with_durable_budget(self):
        early = self.cycle(observation(signature(), now=NOW - 1))
        self.assertEqual(early.action, sup.ACTION_NONE)
        self.assertEqual(self.restarts, [])
        first = self.cycle(observation(signature()), sup.load_supervisor_state(self.config.state_path))
        self.assertEqual(first.action, sup.ACTION_RESTART)
        self.assertIn("auth-class:reset_relogin_rejected", first.notes)
        self.assertEqual(self.restarts, ["ib-gateway"])
        self.cycle(observation(signature(), now=NOW + 300), sup.load_supervisor_state(self.config.state_path))
        self.assertEqual(self.restarts, ["ib-gateway"])

    def test_delay_is_default_five_minutes_and_bounded_three_to_fifteen(self):
        self.assertEqual(sup.Config().reset_relogin_restart_delay, 300)
        for seconds in (180, 900):
            config = replace(self.config, reset_relogin_restart_delay=seconds)
            for age, expected in ((seconds - 1, sup.ACTION_NONE), (seconds, sup.ACTION_RESTART)):
                decision = sup.decide(observation(signature(NOW - age)), sup.SupervisorState(), config)
                self.assertEqual(decision.action, expected)
        for seconds in (0, 179, 901):
            with self.assertRaises(ValueError):
                replace(self.config, reset_relogin_restart_delay=seconds)
            with self.assertRaises(ValueError):
                sup.config_from_env({"IBGSS_RESET_RELOGIN_RESTART_DELAY_SEC": str(seconds)})

    def test_plain_rejection_never_restarts_even_with_closed_api_or_stale_health(self):
        for api in (True, False):
            for view in (None, pusher(gateway=False), pusher(gateway=True)):
                decision = self.cycle(observation(
                    [line(NOW - 300, "Unrecognized Username or Password")],
                    api_listening=api, pusher=view,
                ))
                self.assertEqual(decision.action, sup.ACTION_HALT)
        self.assertEqual(self.restarts, [])

    def test_prefix_must_precede_rejection_within_120_seconds(self):
        for gap, expected in ((0, sup.ACTION_RESTART), (120, sup.ACTION_RESTART), (121, sup.ACTION_HALT)):
            decision = sup.decide(observation(signature(gap=gap)), sup.SupervisorState(), self.config)
            self.assertEqual(decision.action, expected)
        wrong_order = [line(NOW - 360, "Unrecognized Username or Password"), line(NOW - 300, "Re-login is required")]
        self.assertEqual(self.cycle(observation(wrong_order)).action, sup.ACTION_HALT)

    def test_rejection_burst_keeps_first_timestamp(self):
        lines = signature() + [
            line(NOW - 300 + offset, "Unrecognized Username or Password")
            for offset in (0, 1, 5)
        ]
        current = observation(lines)
        self.assertEqual(current.reset_relogin_rejected_at, NOW - 300)
        self.assertEqual(sup.decide(current, sup.SupervisorState(), self.config).action, sup.ACTION_RESTART)

    def test_later_prefixless_rejection_halts_without_restart(self):
        for offset in (6, 20, 290):
            with self.subTest(offset=offset):
                lines = signature() + [line(NOW - 300 + offset, "Unrecognized Username or Password")]
                current = observation(lines)
                self.assertIsNone(current.reset_relogin_rejected_at)
                self.assertEqual(current.login_rejected_at, NOW - 300)
                decision = self.cycle(current)
                self.assertEqual(decision.action, sup.ACTION_HALT)
                self.assertTrue(decision.persist.operator_clear_required)
                self.assertIsNotNone(decision.alert_problem)
                self.assertEqual(self.restarts, [])

    def test_second_full_pair_halts_without_restart(self):
        lines = signature() + signature(NOW - 10)
        current = observation(lines)
        self.assertIsNone(current.reset_relogin_rejected_at)
        self.assertEqual(current.login_rejected_at, NOW - 300)
        decision = self.cycle(current)
        self.assertEqual(decision.action, sup.ACTION_HALT)
        self.assertTrue(decision.persist.operator_clear_required)
        self.assertIsNotNone(decision.alert_problem)
        self.assertEqual(self.restarts, [])

    def test_generation_filters_old_prefix_rejection_and_success(self):
        start = NOW - 1000
        for lines in (
            signature(NOW - 1200),
            [line(start - 1, "Re-login is required"), line(start + 1, "Unrecognized Username or Password")],
        ):
            self.assertNotEqual(self.cycle(observation(lines, container_started_at=start)).action, sup.ACTION_RESTART)
        lines = [line(start - 1, "Login has completed")] + signature()
        self.assertEqual(self.cycle(observation(lines, container_started_at=start)).action, sup.ACTION_RESTART)

    def test_untimestamped_and_unknown_generation_cannot_match(self):
        for lines in (["Re-login is required", "Unrecognized Username or Password"], signature()):
            for start in (None, NOW - 100):
                current = observation(lines, container_started_at=start, container_generation=None)
                self.assertIsNone(current.reset_relogin_rejected_at)
                self.assertNotEqual(self.cycle(current).action, sup.ACTION_RESTART)

    def test_unknown_generation_with_current_signature_cannot_restart(self):
        current = observation(
            signature(), container_started_at=NOW - 10800, container_generation=None,
        )
        self.assertEqual(current.reset_relogin_rejected_at, NOW - 300)
        decision = self.cycle(current)
        self.assertEqual(decision.action, sup.ACTION_NONE)
        self.assertIn("container health or generation unconfirmed", decision.reason)
        self.assertEqual(self.restarts, [])

    def test_future_signature_is_ignored(self):
        current = observation(signature(NOW + 60))
        self.assertIsNone(current.reset_relogin_rejected_at)
        self.assertNotEqual(self.cycle(current).action, sup.ACTION_RESTART)

    def test_success_before_delay_cancels_recovery_even_if_pusher_lags(self):
        lines = signature(NOW - 100) + [line(NOW - 30, "Login has completed")]
        for view in (None, pusher(gateway=False), pusher(gateway=True)):
            current = observation(lines, pusher=view)
            self.assertIsNone(current.reset_relogin_rejected_at)
            self.assertEqual(current.login_state, sup.LOGIN_LOGGED_IN)
            self.assertEqual(self.cycle(current).action, sup.ACTION_NONE)
        self.assertEqual(self.restarts, [])

    def test_success_between_prefix_and_rejection_invalidates_prefix(self):
        lines = signature()
        lines.insert(1, line(NOW - 330, "Login has completed"))
        self.assertEqual(self.cycle(observation(lines)).action, sup.ACTION_HALT)

    def test_running_and_docker_healthy_are_required(self):
        for health in (False, None):
            self.assertEqual(self.cycle(observation(signature(), container_healthy=health)).action, sup.ACTION_NONE)
        decision = sup.decide(observation(signature(), container_running=False), sup.SupervisorState(), self.config)
        # The existing confirmed-stopped-container recovery remains separate.
        self.assertFalse(decision.reset_relogin_restart)
        self.assertEqual(self.restarts, [])

    def test_budget_exhausted_even_if_configured_budget_is_larger(self):
        for maximum in (1, 3):
            config = replace(self.config, max_restarts_per_outage=maximum)
            decision = self.cycle(observation(signature()), sup.SupervisorState(restarts_this_outage=1), config)
            self.assertEqual(decision.action, sup.ACTION_HALT)
        self.assertEqual(self.restarts, [])

    def test_rejection_overrides_old_authenticating_phase(self):
        state = sup.SupervisorState(
            login_state=sup.LOGIN_AUTHENTICATING, login_generation="fixture:100",
            authenticating_since=NOW - 3600,
        )
        decision = self.cycle(observation(signature()), state)
        self.assertEqual(decision.action, sup.ACTION_RESTART)
        self.assertIsNone(decision.persist.authenticating_since)

    def test_startup_manual_and_unknown_probe_guards_remain(self):
        current = observation(signature())
        for guarded in (
            replace(current, container_started_at=NOW - 600),
            replace(current, manual_action=sup.MANUAL_FULLAUTH, twofa_evidence=True),
            replace(current, twofa_evidence=True),
            replace(current, probe_unknown=True),
        ):
            self.assertNotEqual(self.cycle(guarded).action, sup.ACTION_RESTART)
        self.assertEqual(self.restarts, [])

    def test_pre_execution_lock_contention_does_not_reserve_reset_state(self):
        with mock.patch("builtins.print"):
            decision, _ = sup.run_cycle(
                observation(signature()), self.config, restarter=self.restart,
                locker=lambda: None,
            )
        self.assertEqual(decision.action, sup.ACTION_NONE)
        saved = sup.load_supervisor_state(self.config.state_path)
        self.assertEqual(saved.restarts_this_outage, 0)
        self.assertFalse(saved.reset_relogin_restart_pending)
        self.assertEqual(self.cycle(observation(signature()), saved).action, sup.ACTION_RESTART)

    def test_cold_rejection_halts_during_grace_persists_and_pages(self):
        config = replace(self.config, alert_enable=True, alert_transport="email-agent-bus")
        sent = []
        senders = {"email": lambda text, event: sent.append(text) or True}
        self.cycle(observation(signature()), config=config, notification_senders=senders)
        rejected = observation(
            [line(NOW + 30, "Unrecognized Username or Password")],
            now=NOW + 60, container_started_at=NOW + 1, container_generation="fixture:200",
            pusher=pusher(gateway=True, observed_at=NOW + 60),
        )
        decision = self.cycle(rejected, sup.load_supervisor_state(config.state_path), config, notification_senders=senders)
        self.assertEqual(decision.action, sup.ACTION_HALT)
        self.assertIn("cold login rejected after reset restart", decision.alert_problem.text)
        # The log may age out and Docker may report a further generation. The
        # halted state still wins over stale pusher health and a larger budget.
        quiet = observation(
            [], now=NOW + 601, container_started_at=NOW + 100,
            container_generation="fixture:300", pusher=pusher(gateway=True, observed_at=NOW + 601),
        )
        again = self.cycle(quiet, sup.load_supervisor_state(config.state_path), config, notification_senders=senders)
        self.assertEqual(again.action, sup.ACTION_HALT)
        self.assertTrue(again.persist.operator_clear_required)
        self.assertEqual(self.restarts, ["ib-gateway"])
        self.assertEqual(len(sent), 1)
        self.assertIn("cold login rejected after reset restart", sent[0])
        self.assertNotIn("Unrecognized Username or Password", sent[0])

    def test_reset_reservation_never_retries_even_after_nonzero_restart(self):
        with mock.patch("builtins.print"):
            first, _ = sup.run_cycle(
                observation(signature()), self.config, restarter=lambda _cfg: 1,
                locker=lambda: True, unlocker=lambda _held: None,
            )
        self.assertTrue(first.persist.reset_relogin_restart_pending)
        config = replace(self.config, max_restarts_per_outage=3)
        for running in (True, False):
            decision = self.cycle(observation(
                [], now=NOW + 1800, container_running=running,
            ), sup.load_supervisor_state(config.state_path), config)
            self.assertNotEqual(decision.action, sup.ACTION_RESTART)
        self.assertEqual(self.restarts, [])

    def test_verification_requires_cold_generation_completed_login_and_api_ready(self):
        self.cycle(observation(signature()))
        reserved = sup.load_supervisor_state(self.config.state_path)
        for api, view, lines, start in (
            (True, pusher(gateway=True, observed_at=NOW + 60), [], NOW + 1),
            (False, pusher(gateway=True, observed_at=NOW + 60), [line(NOW + 30, "Login has completed")], NOW + 1),
            (True, pusher(gateway=False, observed_at=NOW + 60), [line(NOW + 30, "Login has completed")], NOW + 1),
            (True, pusher(gateway=True, observed_at=NOW + 60), [line(NOW + 30, "Login has completed")], NOW - 10800),
        ):
            decision = sup.decide(observation(
                lines, now=NOW + 60, container_started_at=start,
                container_generation="fixture:200", api_listening=api, pusher=view,
            ), reserved, self.config)
            self.assertNotEqual(decision.phase, sup.PHASE_API_READY)
            self.assertEqual(decision.persist.restarts_this_outage, 1)
        recovered = self.cycle(observation(
            [line(NOW + 30, "Login has completed")], now=NOW + 60,
            container_started_at=NOW + 1, container_generation="fixture:200",
            pusher=pusher(gateway=True, observed_at=NOW + 60),
        ), reserved)
        self.assertEqual(recovered.phase, sup.PHASE_API_READY)
        self.assertEqual(recovered.persist.restarts_this_outage, 0)
        self.assertFalse(recovered.persist.reset_relogin_restart_pending)

    def test_unknown_or_corrupt_saved_state_halts(self):
        base = sup.SupervisorState().to_dict()
        for changes in (
            {"restarts_this_outage": -1}, {"restarts_this_outage": "0"},
            {"reset_relogin_restart_pending": "unknown"},
            {"reset_relogin_restart_pending": True}, {"phase": "unexpected"}, {"phase": {}},
            {"reset_relogin_restart_pending": True, "restarts_this_outage": 1, "last_restart_at": float("nan")},
        ):
            state = sup.SupervisorState.from_dict({**base, **changes})
            self.assertTrue(state.corrupt)
            self.assertEqual(self.cycle(observation(signature()), state).action, sup.ACTION_HALT)
        self.assertEqual(self.restarts, [])

    def test_huge_saved_timestamp_halts_as_corrupt_state(self):
        for field in ("last_restart_at", "last_healthy_at", "unhealthy_since", "authenticating_since"):
            with self.subTest(field=field):
                raw = {**sup.SupervisorState().to_dict(), field: 10**400}
                Path(self.config.state_path).write_text(json.dumps(raw), encoding="utf-8")
                state = sup.load_supervisor_state(self.config.state_path)
                self.assertTrue(state.corrupt)
                self.assertTrue(state.operator_clear_required)
                self.assertEqual(self.cycle(observation(signature()), state).action, sup.ACTION_HALT)
                self.assertEqual(self.restarts, [])

    def test_runtime_collects_signature_and_docker_health_without_inspect(self):
        def docker(_cfg, args, timeout=15):
            if args[0] == "ps":
                return sup.DockerResult(kind="ok", stdout="fixture\tUp 3 hours (healthy)\n")
            if "/proc/1/stat" in " ".join(args):
                return sup.DockerResult(kind="ok", stdout=fake_proc1_stat(100) + f"btime {int(NOW - 10801)}\n")
            if "/proc/net/tcp" in " ".join(args):
                return sup.DockerResult(kind="ok", stdout=PROC_API_AND_RELAY)
            return sup.DockerResult(kind="ok", stdout="")

        collected = sup.collect_meaningful_events_from_lines(signature(), NOW - 10800)
        self.assertEqual(collected.kept_lines, 2)
        with mock.patch.object(sup, "docker_command", side_effect=docker), mock.patch.object(sup, "observe_login_logs", return_value=collected):
            current = sup.observe_runtime(self.config, NOW)
        self.assertTrue(current.container_healthy)
        self.assertEqual(current.reset_relogin_rejected_at, NOW - 300)
        self.assertEqual(self.cycle(current).action, sup.ACTION_RESTART)


if __name__ == "__main__":
    unittest.main()
