"""Offline regression for Docker's delayed auto-removal/name lifecycle."""

import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("mount_ci", Path(__file__).with_name("janus_flow_mount_ci.py"))
MOUNTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOUNTS)


class DockerLifecycle:
    """stop acknowledges exit before --rm has released the container name."""

    def __init__(self):
        self.containers = {}
        self.next_exit = 0
        self.fail_remove = False

    def command(self, *argv, ok=True):
        code = 0
        if argv[1] == "run":
            name = argv[argv.index("--name") + 1]
            if name in self.containers:
                code = 125
            else:
                self.containers[name] = {"auto_remove": "--rm" in argv, "removing": False}
                code, self.next_exit = self.next_exit, 0
        elif argv[1] == "stop":
            state = self.containers[argv[-1]]
            state["removing"] = state["auto_remove"]
        elif argv[1:3] == ("container", "rm"):
            name = argv[-1]
            if self.fail_remove or self.containers[name]["removing"]:
                code = 1
            else:
                del self.containers[name]
        else:
            raise AssertionError("unexpected synthetic Docker operation")
        if ok and code:
            raise RuntimeError("synthetic Docker lifecycle failure")
        return subprocess.CompletedProcess(argv, code, "", "")


class MountLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.docker = DockerLifecycle()
        docker_command = patch.object(MOUNTS, "command", side_effect=self.docker.command)
        self.addCleanup(docker_command.stop)
        docker_command.start()

    def start(self, *args, detached=False):
        return MOUNTS.run_probe("synthetic", "synthetic:fixture", Path("/fixture/config"),
                                Path("/fixture/stable/api-key"), *args, detached=detached)

    def test_rotation_recreates_even_when_auto_removal_would_be_delayed(self):
        self.assertEqual(self.start("wait", detached=True).returncode, 0)
        MOUNTS.stop_probe("synthetic")
        self.assertEqual(self.start("B").returncode, 0)

    def test_missing_mount_refusal_can_be_removed_before_placeholder_activation(self):
        self.docker.next_exit = 125
        self.assertEqual(self.start("A").returncode, 125)
        MOUNTS.command("docker", "container", "rm", "synthetic")
        self.assertEqual(self.start("wait", detached=True).returncode, 0)

    def test_probe_failure_is_preserved(self):
        self.docker.next_exit = 6
        self.assertEqual(self.start("B").returncode, 6)

    def test_failed_removal_keeps_the_lifecycle_gate_closed(self):
        self.start("wait", detached=True)
        self.docker.fail_remove = True
        with self.assertRaises(RuntimeError):
            MOUNTS.stop_probe("synthetic")
        self.assertEqual(self.start("B").returncode, 125)


if __name__ == "__main__":
    unittest.main()
