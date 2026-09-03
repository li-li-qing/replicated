---
name: replicated-suite-engineering
description: Engineering baseline for the user's ArcheRage RU Replicated Suite project. Use when continuing development, refactoring multiple Replicated addons into one Suite, changing shared UI/HUD behavior, modifying DPS/Healer/Gear/Plates architecture, handling 200-player performance, API capability changes, migrations, diagnostics, or release behavior.
---

# Replicated Suite Engineering

> Baseline revision: v1.1 (2026-08-15) — includes DPS Team/Range scope policies.

## Mandatory startup

When this skill is used for a new page or continuation:

1. Read all reference documents in this skill:
   - `references/PRODUCT_ARCHITECTURE.md`
   - `references/UI_HUD_SPEC.md`
   - `references/RUNTIME_DATA_API.md`
2. Inspect the newest full Addon package supplied by the user.
3. If API work is relevant, inspect the newest supplied `z_api_functions` / official API package.
4. Treat the uploaded current Addon as implementation truth.
5. Treat the reference documents as product/architecture constraints.
6. Never assume that a target architecture described in the documents is already implemented.

## Project context

- Game: ArcheAge / ArcheRage RU private server.
- User runs a Chinese client.
- Public project brand: Replicated Suite.
- User's public author/character identifier: Replicated.
- Public product target: one Addon entry, internally modular.
- Existing major systems include DPS, Healer, Gear, Plates, activities, Buff tracking, bonds, trade/cargo, fishing and resources.
- The project has a real user base; compatibility, migration, diagnostics and quiet defaults matter.
- ArcheRage large-scale runtime must treat ~200 players within observable range as a normal workload, not an exotic benchmark.

## Product decisions are frozen unless user changes them

### One public addon

The end state is one public:

```text
Replicated Suite
```

Do not keep a long-term architecture where players must enable many Replicated addons separately.

Do not build a monolithic mega-core. Keep Modules isolated.

### Authority

Suite owns:

- Module lifecycle
- shared settings navigation
- HUD visibility authority
- common infrastructure

Each Module owns its Domain.

Never move DPS/Healer/Gear/Plates mutable Domain State into a global Suite state bag.

### Module disable

Disabling a Module must stop its business runtime as much as practical.

Disable must not clear accumulated data or delete user configuration.

Clear/reset is a separate explicit action.

### Quiet defaults

Fresh install:

- only minimal Suite entry should normally appear
- base Suite life/activity capabilities may be enabled
- long-lived HUDs default hidden
- professional modules default disabled
- new modules introduced by updates default disabled

### Home page

Preserve the current useful life/dashboard style.

Use left-side categorized navigation plus user-customizable favorites.

Allow a configurable default start page.

## HUD hard rules

Read `UI_HUD_SPEC.md` before changing shared HUD behavior.

Critical rules:

- Long-lived HUDs have no `×` close button.
- Keep unified `- / +` collapse/restore.
- Collapsed state persists across restart.
- Hiding is controlled by Suite/HUD management.
- Module Enabled, HUD Visible and Expanded/Collapsed are separate.
- Title bars may be hidden; editing mode temporarily restores them.
- Title buttons use global defaults plus per-HUD override.
- Only show controls the HUD actually supports.
- Resize is handled through HUD edit mode.
- Locked HUD behavior must be respected.
- Provide temporary unlock-all in edit mode.
- Support per-HUD mouse-through behavior.
- Editing is allowed in combat unless a concrete client/API restriction is proven.
- Do not impose large content-driven minimum sizes.
- Keep only a tiny technical safety minimum.
- Users may intentionally make HUDs extremely small.
- Cropping/crowding/overlap is acceptable for deliberately extreme sizes.
- Do not automatically hide important business fields to make small layouts look clean.
- Prefer keyword-preserving short labels over `...`.
- Normal recommended sizes must not show accidental ellipsis.
- Font size and window size are independent.
- Background alpha must not fade text when only the background is changed.
- Global defaults + per-HUD inheritance apply to font/background/compact preferences.
- Manual size overrides auto-size until the user explicitly re-enables auto-size.
- Support HUD layout profiles.
- HUD layout profiles do not control Module Enabled.

## Text overflow rules

This is a recurring project bug and must be actively checked.

During every UI change:

1. Test Chinese, English and Russian long strings.
2. Inspect labels, buttons, tabs, table columns and HUD titles for unintended `...`.
3. Prefer:
   - shorter meaningful labels
   - module-provided short names
   - compact numbers
   - compact time
   - flexible column allocation
4. In tables, protect important numeric columns before long names.
5. Long names may be cropped only when space is genuinely constrained; hover/detail should preserve the full value where practical.
6. Accidental ellipsis at normal size is a release blocker.

## Healer scope

Remove the independent ranked “players needing healing” HUD and unnecessary rank computation if no other consumer needs it.

Keep useful direct assistance such as:

- party/raid frame highlighting
- health rules
- Buff/Debuff rules
- color states
- distance/urgency conditions

Do not reintroduce a ranked healing list unless the user explicitly asks.

## Settings UX

Use:

- Common
- Appearance
- Advanced
- Diagnostics

Provide global settings search.

Closed modules remain configurable.

Runtime-dependent action buttons may be disabled while the module is off.

## HUD and function profiles

Keep separate:

### HUD Layout Profile

Stores UI state:

- position
- size
- font
- background
- title state
- Visible
- Expanded/Collapsed

Does not store Module Enabled.

### Function Profile

Stores Module Enabled states.

### Combined Shortcut

The user may explicitly bind one function profile and one HUD profile into a one-click scenario shortcut such as:

```text
大型团战
生活
跑商
```

Never auto-link them without explicit user configuration.

## Character/account scope

Use account defaults plus character overrides.

Let each module declare scope.

Examples:

- theme/global font: account
- gear profile: character
- class-specific healer rules: character
- HUD layout: account default with optional character override

## Diagnostics and fault isolation

A failing Module must not crash the whole Suite.

On module startup/runtime failure:

- safely disable that module if needed
- stop repeated error spam
- keep other modules alive
- record module/stage/error context
- allow retry where safe

Release builds should not spam chat.

Default visible logs: only user-actionable errors/warnings.

Diagnostics page may expose:

- Off
- Error
- Warning
- Debug
- Verbose

Provide module-level and full Suite diagnostic summaries while filtering unrelated/private data.

## Dangerous actions

Classify risk.

High-risk operations such as:

- clear all DPS data
- reset whole Suite
- delete all Gear profiles

require explicit confirmation.

Create a temporary recoverable backup first when technically feasible.

## Large-scale runtime

Read `RUNTIME_DATA_API.md` before touching DPS/Plates/Healer shared observation or high-frequency runtime.

### 200 players is normal

Do not design around a hard `MAX_ACTORS = 200`.

There may also be NPCs, summons, pets, vehicles and unknown actors.

### Shared observation, separate domain

Use a shared observation layer to avoid every module rescanning all 200 units.

Observation may cache basic game facts.

DPS/Healer/Plates still own their own business interpretation.

### Subscription-driven data

Do not query expensive Healer/Plates/Buff data when those modules are disabled.

### Priority

Under load:

1. raw combat/key events
2. authoritative Domain accumulation
3. identity/business interpretation
4. ranking/detail projection
5. HUD refresh
6. diagnostics/cosmetic work

Prefer delayed UI over lost/incorrect combat facts.

## DPS data scope modes

DPS has two explicit scope policies:

```text
Team mode
Range mode
```

Do not implement them as two separate DPS systems.

Shared pipeline:

```text
Combat Event
→ Event Fact
→ Identity / Relation Resolution
→ Scope Policy
→ PVP/PVE Classification
→ Stats Domain
```

### Team mode

Formal ranking actors are:

```text
SELF + TEAM
```

Team/raid membership is authoritative.

Non-team units may still exist as `ContextOnly` for:
- PVP/PVE classification
- boss/target identification
- damage-taken source details
- skill/target/source relationships

Do not promote those Context actors into the full ranking by default.

When Team mode is active, stop or greatly reduce full-range world scanning. Focus on:
- roster
- combat-event context actors
- current target / necessary hotspots
- low-frequency roster reconciliation

If no team exists, SELF remains a formal actor.

### Range mode

Range mode tries to formally track every relevant observable actor:
- SELF
- TEAM
- friendly players outside the team
- hostile players
- NPCs/Bosses
- summons/pets/vehicles when identifiable
- resolved Unknown actors

TEAM remains a strong identity anchor inside Range mode.

Range mode may enable:
- shared World Observation
- broader actor cache
- hot-actor queries
- Unknown resolver
- existing relation inference/manual correction logic

Current product default is Range mode to preserve the project's established “all observable units” goal.

### Switching modes

Switching Team ↔ Range:
- must not clear existing statistics
- must not silently reinterpret missing history
- affects subsequent event admission / observation behavior
- should show a short confirmation
- clearing remains a separate explicit user action

Do not fabricate pre-switch Range data that was never observed.

### Diagnostics

Useful diagnostics:
- ScopeMode
- TeamRosterCount
- ObservedActorCount
- ResolvedActorCount
- UnresolvedActorCount
- ObservationBacklog

Do not expose internal confidence formulas to normal users.


## DPS non-regression

Accuracy is more important than immediate UI freshness.

Per-event PVP/PVE classification is mandatory.

Example:

```text
Player1 -> Player2 = PVP
Player1 -> NPC1    = PVE
```

Never classify an entire actor permanently into one panel.

Preserve other verified DPS semantics when touching them, including manual correction, clear behavior and Boss cumulative history.

## Unknown actor handling

Large battles may produce combat facts where the API cannot currently identify source/target.

Do not:

- drop these events
- merge every unknown source into one permanent actor

Direction:

- preserve Event Facts
- assign separate temporary ActorKeys where possible
- allow later identity resolution
- reproject history when identity becomes known
- expose unresolved totals to UI in a readable aggregated form if needed

The exact resolver evidence is NOT a product decision. Verify it technically.

## API governance

Do not trust the current bundled `z_api_functions` as timeless truth.

ArcheRage RU may open, close, re-open, restrict or remove API functions.

Before relying on an API in architecture:

1. inspect the user's latest bundled API
2. compare official RU update information when necessary
3. inspect current addon code usage
4. use runtime evidence where safe
5. record capability state centrally

Move toward a capability registry rather than scattered per-module guesses.

Potential states include:

- OfficialEnabled
- OfficialDisabled
- Removed
- RuntimeVerified
- RuntimeFailed
- CombatRestricted
- CooldownLimited
- CrashRisk
- Unknown

Do not auto-probe side-effectful APIs at startup.

## Technical decisions the user should not be asked to choose blindly

Do not ask the user to choose:

- cache TTL without evidence
- dedup fingerprint thresholds
- identity confidence weights
- event retention windows
- queue budgets
- API capability truth
- summon owner resolution technique

Investigate these from:

- official API
- current source
- other DPS implementations the user supplies
- actual runtime sampling

Only ask the user when a technical limitation changes visible product behavior.

## Release/migration

For the final consolidated Suite release:

- the user plans to tell users to remove obsolete standalone Replicated addons
- do not build a long-term dual-runtime coexistence layer

Old settings migration may be attempted as a separate technical task if safe.

Do not keep old runtime architecture alive solely to preserve migration.

Private-only modules must never enter the public release.

## Default refactor order

1. Freeze behavior and create acceptance checklists.
2. Build Common contracts, Module Manager, HUD Manager and Diagnostics foundations.
3. Migrate Suite-native modules.
4. Migrate Gear.
5. Migrate Plates.
6. Migrate Healer.
7. Migrate DPS peripheral UI/integration/storage.
8. Split DPS runtime/domain gradually.
9. Remove duplicated bridges/frameworks last.

Do not start with a wholesale DPS rewrite.

## New-page workflow

When continuing in a new chat:

1. Read this skill and all references.
2. Inspect the newest full Addon zip.
3. Identify which target architecture pieces are already implemented versus still planned.
4. Inspect the exact files touched by the requested feature.
5. Preserve verified current behavior unless explicitly targeted.
6. Prefer incremental migration and compatibility adapters.
7. Verify load paths, initialization order, handlers, persistence and UI.
8. Check long-text overflow on every changed UI.
9. Check Module Enabled vs HUD Visible semantics.
10. Check that disabled modules stop unnecessary runtime.
11. Run syntax/static checks on modified Lua files where possible.
12. Return the exact file/package format requested by the user.

## Review checklist

Before finishing any shared architectural change, ask internally:

- Did Suite accidentally gain a module's Domain Authority?
- Did a disabled module continue high-frequency work?
- Did Disable clear data?
- Did HUD close buttons reappear?
- Did collapse/restore become confused with hide/disable?
- Did a large minWidth/minHeight reappear?
- Did responsive layout hide business fields?
- Did accidental `...` appear at normal size?
- Did font resizing become coupled to window resizing?
- Did background alpha fade text?
- Did a new module become enabled by default?
- Did a migration re-enable an explicitly disabled setting?
- Did one module error threaten the whole Suite?
- Did shared observation become a global writable business state?
- Did a performance optimization reduce DPS accuracy?
- Did Team mode accidentally keep full-range high-frequency observation enabled?
- Did Team mode promote non-team Context actors into the formal ranking?
- Did Range mode stop treating TEAM as authoritative evidence?
- Did a Team/Range mode switch clear or fabricate historical statistics?
- Did Team and Range modes fork into duplicated DPS business pipelines?
- Did unverified API assumptions enter critical code?
- Did private functionality leak into the public package?

## Documentation maintenance

If the user changes a frozen product rule:

1. update the relevant reference document
2. update this skill if the rule is repeated here
3. record the change date/version
4. do not leave contradictory old guidance in place
