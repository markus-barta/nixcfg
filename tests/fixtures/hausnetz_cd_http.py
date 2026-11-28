"""In-process urllib fake: synthetic bodies never reach a socket or event log."""

import io
import json
from pathlib import Path
import urllib.error


PRIVATE_NAME = "PRIVATE_SITE_SENTINEL"


class Response(io.BytesIO):
    def __init__(self, body, status=200):
        super().__init__(body)
        self.status = status


def opener(root):
    root = Path(root)

    class Opener:
        def open(self, request, timeout):
            assert request.get_method() == "GET"
            assert timeout == 10
            side = request.full_url.rsplit("/", 1)[1]
            assert side in {"site", "layout"}
            config = json.loads((root / "fixture.json").read_text())
            scenario = json.loads((root / "scenario.json").read_text())
            switched = str((root / "current-system").resolve()) == config["new_system"]
            phase = "after" if switched else "before"
            with (root / "events").open("a") as output:
                output.write(json.dumps({"kind": "data-read", "side": side, "phase": phase}) + "\n")
            if scenario.get("data_read_fail") == phase + "-" + side:
                raise urllib.error.URLError(PRIVATE_NAME)
            site = {"rev": 8, "nodes": {"n": {"name": PRIVATE_NAME}},
                    "building": {"levels": {"f": {}}, "zones": {"r": {}}}, "name": PRIVATE_NAME}
            layout = {"rev": 3}  # Omitted maps are legitimate zero counts.
            value = site if side == "site" else layout
            value.update(scenario.get("data_" + phase + "_" + side, {}))
            return Response(json.dumps({side: value}).encode())

    return Opener()


def install(module, root):
    module.urllib.request.build_opener = lambda *_: opener(root)
