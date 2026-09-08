#!/usr/bin/env python3
"""Real-Lua regression for TradePayoutV3 restored payout semantics."""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from rs_lua_runner import RUNNER

lua = f'''\nReplicatedSuite = {{ Data = {{}}, Services = {{}} }}\ndofile([[{(ROOT / "data/rs_trade_prices.lua").as_posix()}]])\ndofile([[{(ROOT / "services/rs_trade_payout_v3.lua").as_posix()}]])\nlocal P = ReplicatedSuite.Services.TradePayoutV3\nassert(type(P) == "table")\nlocal function eq(actual, expected, label)\n  if actual ~= expected then error(label .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual)) end\nend\nlocal function near(actual, expected, epsilon, label)\n  if math.abs((actual or 0) - expected) > epsilon then error(label .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual)) end\nend\n\n-- Exact key + live ratio + Commerce + fresh-category multiplier.\nlocal price, d = P:Estimate({{ destination=5, itemName="[玛瑞诺普]新鲜特制特产", ratio=114, commerceSkill=100000, includeCommerce=true }})\neq(price, math.floor(256643 * 1.5 * 1.15 + 0.5), "fresh+commerce price")\neq(d.priceKey, "[玛瑞诺普]新鲜特制特产", "exact key")\nnear(d.commerceMultiplier, 1.5, 0.000001, "commerce multiplier")\nnear(d.packMultiplier, 1.15, 0.000001, "fresh multiplier")\n\n-- Explicit ignore mode keeps pack multiplier but removes Commerce only.\nlocal offPrice, off = P:Estimate({{ destination=5, itemName="[玛瑞诺普]新鲜特制特产", ratio=114, commerceSkill=nil, includeCommerce=false }})\neq(offPrice, math.floor(256643 * 1.15 + 0.5), "commerce ignore price")\nnear(off.commerceMultiplier, 1, 0.000001, "commerce ignored")\nnear(off.packMultiplier, 1.15, 0.000001, "pack retained while commerce ignored")\n\n-- Enabled Commerce is fail-closed when the live skill fact is unavailable.\nlocal missingPrice, missing = P:Estimate({{ destination=5, itemName="[玛瑞诺普]新鲜特制特产", ratio=114, includeCommerce=true }})\neq(missingPrice, nil, "missing commerce must not emit incomplete price")\neq(missing.status, "commerce_skill_unavailable", "missing commerce status")\n\n-- Larder name-shape recovery uses selected origin as Authority and the resolved\n-- canonical price key as category fallback when the live alias lacks the token.\nlocal larderPrice, larder = P:Estimate({{ destination=5, itemName="[珊瑚]保存发酵蜂蜜", originZoneName="珊瑚海岸", ratio=130, commerceSkill=0, includeCommerce=true }})\neq(larder.priceKey, "珊瑚海岸加工发酵蜂蜜", "larder canonical key")\neq(larder.keyMode, "larder_origin", "larder resolver mode")\nnear(larder.packMultiplier, 1.03, 0.000001, "larder category fallback")\neq(larderPrice, math.floor(305039 * 1.03 + 0.5), "larder price")\n\n-- Known raw-name alias resolves without mutating source identity.\nlocal aliasPrice, alias = P:Estimate({{ destination=5, itemName="埋骨之地狩猎战利品", ratio=130, commerceSkill=0, includeCommerce=true }})\neq(alias.priceKey, "埋骨之地角笛", "alias price key")\neq(alias.keyMode, "alias", "alias resolver mode")\nassert(aliasPrice ~= nil and aliasPrice > 0)\n\nprint("TRADE_PAYOUT_HARNESS_PASS 5/5")\n'''
with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as f:
    f.write(lua)
    script = f.name
try:
    proc = subprocess.run([RUNNER, script], capture_output=True, text=True, encoding="utf-8")
finally:
    Path(script).unlink(missing_ok=True)
if proc.returncode != 0:
    print("TRADE_PAYOUT_HARNESS FAIL")
    print(proc.stdout)
    print(proc.stderr)
    sys.exit(proc.returncode or 1)
print(proc.stdout.strip())
