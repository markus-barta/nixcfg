"""Ping readiness does not imply the Docker provider has published its route."""

import copy
import unittest

from traefik_provider_ready import providers_ready


class ProviderReadinessTests(unittest.TestCase):
    def setUp(self):
        self.redirect = {"name": "https-redirect@file", "status": "enabled",
                         "entryPoints": ["web"], "middlewares": ["https-redirect@file"]}
        self.backend = {"name": "nix448backend@docker", "status": "enabled",
                        "rule": "Host(`backend.example.test`)", "entryPoints": ["web"],
                        "middlewares": ["cloudflarewarp@file"], "service": "nix448backend"}

    def test_ping_and_file_provider_without_docker_route_are_not_ready(self):
        self.assertFalse(providers_ready([self.redirect, {"name": "ping@internal", "status": "enabled"}]))

    def test_both_enabled_providers_are_ready(self):
        self.assertTrue(providers_ready([self.redirect, self.backend]))

    def test_pending_or_incorrect_backend_is_not_ready(self):
        for field, value in (("status", "disabled"), ("rule", "Host(`other.example.test`)"),
                             ("middlewares", []), ("entryPoints", ["web-secure"]),
                             ("service", "other")):
            with self.subTest(field=field):
                backend = copy.deepcopy(self.backend)
                backend[field] = value
                self.assertFalse(providers_ready([self.redirect, backend]))

    def test_pending_redirect_is_not_ready(self):
        self.redirect["status"] = "disabled"
        self.assertFalse(providers_ready([self.redirect, self.backend]))

    def test_invalid_api_response_is_not_ready(self):
        for response in (None, {}, "unavailable", [None], []):
            with self.subTest(response=response):
                self.assertFalse(providers_ready(response))


if __name__ == "__main__":
    unittest.main()
