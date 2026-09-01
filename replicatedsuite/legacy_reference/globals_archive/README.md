# Legacy `globals/` archive

This directory is **reference-only** and is intentionally absent from `toc.g`.

The former root-level `globals/` mixed several unrelated concerns:

- community/client ABI tables such as `apitypes.lua`;
- historical ArcheAge UI helpers such as `window*.lua` and `button*.lua`;
- the externally sourced baseline in `classmappings.lua` (the file itself records its Strawberry-devs/ArcheRage-addons baseline);
- Replicated-authored historical launcher/ESC compatibility code in `replicatedlauncherpolicy.lua`.

V3 does not execute any of these files. Verified client ABI facts needed by migrated V3 features are curated in `replicatedsuite/native/rs_native_contract.lua`; raw widget creation is owned by `rs_native_object_factory.lua`; ESC integration is owned by `rs_native_esc_bridge.lua`.

Do not add this directory back to the active TOC. When a legacy behavior is needed, migrate the behavior or verified data into the appropriate V3 Native/Data/Feature layer with explicit ownership and tests.
