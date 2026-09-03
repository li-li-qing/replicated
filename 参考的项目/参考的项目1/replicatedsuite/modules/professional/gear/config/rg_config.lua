ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Shareable defaults / persistence namespace
-- Author: Replicated
-- Personal loadouts and UI positions are kept by ADDON:SaveData, not here.
------------------------------------------------------------------------

ReplicatedGearConfig = {
    SaveKey = "replicated_gear_v1",
    ContentId = 91732,
    DefaultRoot = {
        revision = 0,
        nextStorageId = 1,
        ui = {
            launcher = { x = 300, y = 100 },
            quick = { x = 12, y = 150, visible = true, page = 1, snapEnabled = true },
            config = { x = 190, y = 105 },
        },
        characters = {},
    },
}
