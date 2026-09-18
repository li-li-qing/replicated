# ArcheRage RU API Reference Changelog

## 2026-09-18 synchronization

Verification scope: official ArcheRage RU update announcements through **2026-09-16**.
Latest announcement that changes addon API permissions: **2026-09-09**.

### Newly enabled on 2026-09-09

Moved from `Available/not allowed functions` to `Allowed functions` in `api_functions.lua`:

```text
X2Faction:GetExpeditionMemberCount()
X2Quest:GetQuestJournalObjectiveCount(idx)
X2Quest:GetQuestJournalObjectiveText(idx, objIdx)
```

These entries were already present in the bundled client export manifest, but the server did not officially permit them until the 2026-09-09 update.

### No addon API permission changes

The official **2026-09-02** and **2026-09-16** update announcements contain no addon API enable/disable changes. They are still part of the verification window so the repository can state exactly how far it has been checked.

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
