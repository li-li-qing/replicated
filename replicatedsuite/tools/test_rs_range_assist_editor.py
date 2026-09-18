from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "presentation/v3/pages/rs_v3_business_pages.lua"
text = PAGE.read_text(encoding="utf-8")

checks = {
    "range table rows are selectable": 'id == "combat_range_assist"' in text and 'selectable = id == "combat_boss_alerts" or id == "combat_range_assist"' in text,
    "range table uses stable circle identity": 'getKey = id == "combat_range_assist" and function(row) return row and row.circleId end' in text,
    "selected-circle editor state exists": 'rangeSelectedCircleId' in text and 'SyncRangeCircleEditor' in text,
    "delete targets selected circle": 'RemoveCircle(rangeSelectedCircleId)' in text,
    "radius edit targets selected circle": 'SetCircleRadius(rangeSelectedCircleId, v)' in text,
    "refresh lists every configured circle": 'BuildRangeCircleRows(projection)' in text,
    "newly added circle becomes selected without page rebuild": 'rangeSelectedCircleId = tonumber(lastCircle.id)' in text,
    "layout uses standalone title row": 'v3_business_combat_range_assist_editor_title", parent = editorSection.content' in text,
    "layout uses dedicated editor rows instead of uniform grid": 'v3_business_combat_range_assist_editor_rows' in text and 'v3_business_combat_range_assist_editor_grid' not in text,
    "per-circle cards remain removed": 'v3_business_combat_range_assist_card_' not in text,
    "range page uses non-snapping root so editor and table share viewport": 'if id == "tools_bag" or id == "combat_range_assist" then' in text and 'root, err = D:PageRoot(parent, rootSpec)' in text,
    "range list and editor reserve explicit non-overlapping heights": 'slot = { size = "auto", minHeight = 92, hAlign = "fill" }' in text and 'slot = { size = "auto", minHeight = 224, hAlign = "fill" }' in text,
}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), "range-editor", name)
if failed:
    raise SystemExit(f"{len(failed)} range-assist editor regression checks failed: " + "; ".join(failed))
print(f"RANGE ASSIST EDITOR RESULTS: {len(checks)} passed / 0 failed")
