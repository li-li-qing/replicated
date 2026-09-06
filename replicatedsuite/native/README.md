# Replicated Suite Native Foundation

`native/` is the only active boundary between V3 and the ArcheRage RU client object/API ABI.

## Ownership

- `rs_native_contract.lua` — curated API/Object/Event identity contract. Add entries only when a migrated Feature actually needs them and the client contract is verified.
- `rs_native_imports.lua` — sole Authority for `ADDON:ImportAPI` / `ADDON:ImportObject`; Foundation imports the minimum set, Features acquire business APIs lazily.
- `rs_native_object_factory.lua` — sole active raw widget construction boundary (`UIParent:CreateWidget`, child widget constructors).
- `rs_native_esc_bridge.lua` — generation-local idempotent Proxy for documented ADDON ESC/content registration; it owns transport/retry state only, never feature/window visibility state.
- `rs_native_capabilities.lua` — readiness/diagnostic surface consumed by Foundation Gate.
- `rs_native_recovery.lua` — installs two independent bootstrap recovery surfaces immediately after the Native Foundation: the compact `R` launcher and the `RS>` Recovery Command Bar. The command bar uses only verified EditBox `OnEnterPressed`; it does not register/invent chat Slash APIs. Both installers surface thrown errors and logical `false` results without poisoning the full Runtime boot.

## Hard rules

1. Active V3 code must not depend on root-level `globals/` files.
2. Active V3 code must not read `API_TYPE`, `OBJECT_TYPE`, `UIEVENT_TYPE`, `CreateEmptyWindow`, `CreateWindow`, `CreateSimpleButton`, or `ReplicatedEscMenuPolicy`.
3. New raw native widget construction goes through `NativeObjectFactory`.
4. Features declare API dependencies; they do not call `ADDON:ImportAPI` themselves.
5. Imported APIs are process-global and cannot be unloaded. Runtime disable must still release events, scheduler work, caches and widgets.
6. Legacy source is migration evidence, never Runtime Authority.
