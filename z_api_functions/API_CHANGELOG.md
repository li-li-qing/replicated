# ArcheRage RU API Reference Changelog

## 2026-09-18 second-pass official audit
- Cleaned the last two `Drawable` semantic duplicates/malformed exports in `ui_functions.lua`: kept `SetCoords(x, y, width, height)` and `SetSnap(snap)`, removed `SetCoords(x, y, w, h)` and malformed `SetSnap( used)`. UI callable count is now 956 after removing the two duplicate/malformed lines.
- Corrected native Not-allowed inventory count to 2330 after parser-based recount.

This pass revalidated the current manifest against the official ArcheRage RU forum and repaired the historical capability chronology.

### Current-state result

- The latest addon API change directly verified from an official RU update body remains **2026-09-09**.
- The 2026-09-09 body enables exactly:
  - `X2Faction:GetExpeditionMemberCount()`
  - `X2Quest:GetQuestJournalObjectiveCount(idx)`
  - `X2Quest:GetQuestJournalObjectiveText(idx, objIdx)`
- The official index shows a newer **2026-09-16** update. Its thread body was not retrievable through the current audit tooling, and no indexed `X2` / addon change snippet was found. `api_capabilities_ru.lua` now records this distinction explicitly instead of treating index visibility as body verification.

### Historical capability chronology repaired

The previous capability file was accurate for its recorded entries but incomplete. Official RU/ArcheRage update records from 2025 and the 10.0 custom update were added for:

- 2025-04: quest tracking, unit lookup, ability/auction/combat-resource/craft/quest APIs.
- 2025-05: auction searched-item getters.
- 2025-06: 9.5 addon integration APIs.
- 2025-07: ADDON persistence APIs, their follow-up fixes, and the world-position signature change.
- 2025-08: auction price APIs, hotkey APIs, `X2Skill:Info`, `X2Skill:GetCooldown`.
- 2025-09: `X2Hotkey:SaveHotKey`, `X2Skill:GetMateCooldown`.
- 2025-10: hotkey binding conversion helpers.
- 2025-11: `X2Map:ShowWorldmapLocation` addition and its `zoneId -> zoneGroupId` signature change.
- 2025-12: mate equipment APIs.
- 2026-02: 10.0 custom `X2Resident:RefreshResidentMembers` and `X2Resident:GetResidentMembers`.

All of these functions were already present in the bundled current `api_functions.lua` Allowed sections. This pass therefore changes capability provenance/history, not the current native allow-list.

### Date semantics documented

ArcheRage publishes parallel EN and RU maintenance posts around midnight Moscow time, so the EN post/update label can be one calendar day earlier than the RU effective restart date. Historical keys remain chronology labels for compatibility; a metadata warning now prevents consumers from treating them as timezone-normalized timestamps.

## 2026-09-18 synchronization

Verification scope for the original synchronization: official ArcheRage RU update index through **2026-09-16**.
Latest addon API change whose body is directly verified in the 2026-09-18 second pass: **2026-09-09**.

### Newly enabled on 2026-09-09

Moved from `Available/not allowed functions` to `Allowed functions` in `api_functions.lua`:

```text
X2Faction:GetExpeditionMemberCount()
X2Quest:GetQuestJournalObjectiveCount(idx)
X2Quest:GetQuestJournalObjectiveText(idx, objIdx)
```

These entries were already present in the bundled client export manifest, but the server did not officially permit them until the 2026-09-09 update.

### Later update visibility

The **2026-09-02** update was part of the previous verification window. The official index also confirms a **2026-09-16** update exists, but its body was not retrievable in the second-pass audit. No indexed addon/X2 change snippet was found, so the repository keeps **2026-09-09** as the latest positively verified API change rather than asserting a new status from incomplete evidence.

### Existing safety override retained

`X2Unit:GetUnitsInSight(unitOwner)` remains present in `api_functions.lua` because the client exports it, but ArcheRage RU officially disabled it on **2026-08-19**. Runtime code must therefore treat it as disabled via `api_capabilities_ru.lua`.

`UNIT_ENTERED_SIGHT` and `UNIT_LEAVED_SIGHT` remain classified as removed.

### Cleanup

- Removed the obsolete `Archive/` snapshots (`2026-08-15` / `2026-08-23`) from the distributable reference folder.
- Replaced date-suffixed root filenames with stable maintenance names:
  - `api_capabilities_ru.lua`
  - `API_CHANGELOG.md`
- Removed stale documentation references to the non-existent `api_functions2.lua`.
- Removed exact Allowed/Not-allowed duplicate entries from `Console` and `X2House`.
- Removed exact duplicate signatures inside the same UI API class/list.
- Added explicit "reference-only / not runtime Lua" warnings to the UI and console dumps.

## Official ArcheRage RU sources

- 2026-08-19: https://ru.archerage.to/forums/threads/obnovlenie-19-08-2026.17526/
- 2026-08-26: https://ru.archerage.to/forums/threads/obnovlenie-26-08-2026.17543/
- 2026-09-02: https://ru.archerage.to/forums/threads/obnovlenija-02-09-2026.17555/
- 2026-09-09: https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/
- 2026-09-16: https://ru.archerage.to/forums/threads/obnovlenie-16-09-2026.17572/

Historical API status chronology is preserved in `api_capabilities_ru.lua` under `changes`; old duplicated snapshot files are no longer needed.
