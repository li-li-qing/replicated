#!/usr/bin/env python3
"""Self-test for Presentation -> Feature API package gate."""
from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
AUDIT_PATH = ROOT / "tools/rs_presentation_feature_api_audit.py"

spec = importlib.util.spec_from_file_location("rs_presentation_feature_api_audit", AUDIT_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("audit module load failed")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def write(root: pathlib.Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_case(feature_text: str, presentation_text: str):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        write(root, "features/demo.lua", feature_text)
        write(root, "presentation/v3/demo.lua", presentation_text)
        return module.audit(root)


def main() -> int:
    passed = 0

    failures, _ = run_case(
        """
S = S or {}; S.Features = S.Features or {}; S.Features.Demo = S.Features.Demo or {}
local F = S.Features.Demo
function F:GetProjection() return {} end
F.Commands = F.Commands or {}
function F.Commands:Refresh() return true end
""",
        """
local Feature = S.Features and S.Features.Demo or nil
Feature:GetProjection()
Feature.Commands:Refresh()
""",
    )
    assert not failures, failures
    passed += 1

    failures, _ = run_case(
        """
S = S or {}; S.Features = S.Features or {}; S.Features.Demo = S.Features.Demo or {}
local F = S.Features.Demo
function F:GetProjection() return {} end
F.Commands = F.Commands or {}
""",
        """
local Feature = S.Features and S.Features.Demo or nil
Feature.Commands:MissingCommand()
""",
    )
    assert any("MissingCommand" in item for item in failures), failures
    passed += 1

    failures, _ = run_case(
        """
S = S or {}; S.Features = S.Features or {}; S.Features.Demo = S.Features.Demo or {}
local F = S.Features.Demo
function F:GetProjection() return {} end
F.Commands = F.Commands or {}
""",
        """
local Feature = S.Features and S.Features.Demo or nil
if type(Feature.Commands.MissingCommand) == "function" then
    Feature.Commands:MissingCommand()
end
""",
    )
    assert not failures, failures
    passed += 1

    failures, _ = run_case(
        """
local function NewFeature(id, spec) return {} end
local Demo = NewFeature("demo_business", {
    commands = {
        DoThing = function(feature, value) return value end,
    },
})
""",
        """
local Feature = S.Features and S.Features["demo_business"] or nil
Feature:GetProjection()
Feature.Commands:Refresh()
Feature.Commands:DoThing(1)
""",
    )
    assert not failures, failures
    passed += 1

    failures, _ = run_case(
        """
local Treasure = {}
function Treasure:GetProjection() return {} end
Treasure.Commands = { Select = function(_, key) return key end }
S.Features.Treasure = Treasure
""",
        """
local Feature = S.Features and S.Features.Treasure or nil
Feature:GetProjection()
Feature.Commands:Select("x")
""",
    )
    assert not failures, failures
    passed += 1

    print(f"PRESENTATION_FEATURE_API_AUDIT_HARNESS PASS {passed}/5")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
