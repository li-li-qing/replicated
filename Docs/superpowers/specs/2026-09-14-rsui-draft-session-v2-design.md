# RSUI DraftSession V2 Design

## Goal

Separate RSUI input draft lifetime from unreliable RU Native EditBox focus lifetime so user-entered text survives transient/real LostFocus until an explicit commit or cancel boundary.

## Scope

- Shared `TextInput` and `NumericInput` draft lifecycle.
- Explicit-commit numeric settings (`NumericField` with Apply button).
- Existing UnitLines/RangeAssist page-level visual refresh fence consumes draft-session state rather than focus state.
- No Store schema, Feature Authority, Scheduler cadence, or business-data format changes.

## Draft semantics

Each input owns two independent states:

1. `draftActive`: a Lua-owned transaction exists. It survives Native LostFocus.
2. `editing`: the Native EditBox currently owns keyboard/focus interaction.

While `draftActive` is true, ambient `Render()` calls may update the committed Authority cache but must not overwrite draft text. LostFocus captures the current Native text, disarms keyboard/focus visuals, and keeps the draft transaction alive for explicit-commit inputs.

For legacy blur-commit fields, LostFocus retains existing commit behavior.

## Commit modes

- `explicit`: LostFocus suspends the draft. Commit occurs only via Apply/Enter/action APIs. Cancel/page release discards the draft and restores Authority when relevant.
- `blur`: LostFocus commits as before for backward compatibility.

`NumericField` automatically passes `explicit` to its inner `NumericInput` when it exposes an Apply button; otherwise it uses `blur`.

`TextInput` maps existing `submitOnLostFocus=false` to `explicit`; default remains `blur` unless the caller explicitly requests `draftCommitMode="explicit"`.

## Switching between inputs

Starting a new input does not commit another input's explicit draft. The coordinator only suspends keyboard ownership of other focused inputs while keeping their Lua drafts alive. Multiple explicit drafts may coexist within one page and therefore continue to fence ambient page refreshes until committed/cancelled or the page is released.

## Slider and programmatic Authority changes

If a NumericField slider/step control changes the same Authority, that action explicitly supersedes the text draft for that field. The draft is cleared before rendering the newly committed Authority value.

Programmatic `TextInput:SetValue` is also an explicit Authority write and supersedes any pending draft.

## Diagnostics

Expose a read-only DraftSession snapshot containing active count, focused count, begin/suspend/commit/cancel counters, and render suppression count. Diagnostics never owns or mutates business values.

## Performance

No polling and no Tick. All transitions are event-driven. The existing visual-page refresh fence performs only the same weak-table draft lookup, now keyed by `draftActive` instead of Native focus.

## Compatibility

- No Persistence changes.
- Blur-commit inputs retain legacy behavior.
- Explicit-commit inputs become robust against RU LostFocus ordering.
- Existing public methods remain available; `SuspendEditing()` and `HasDraftSession()` are additive.
