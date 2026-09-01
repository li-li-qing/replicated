------------------------------------------------------------------------
-- Replicated Suite V3 - Native Object Factory
--
-- Only Suite-owned widget construction boundary for active V3 code. Visual
-- styling/layout remain RSUI responsibilities; this layer owns raw client
-- object creation and constructor compatibility only.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite
local Contract = S.NativeContract
local Imports = S.NativeImports

S.NativeObjectFactory = {
    version = 3,
    objectImportFenceContractVersion = 1,
    owner = "Replicated Suite",
    created = 0,
    failures = 0,
    duplicateRejects = 0,
    invalidIdentityRejects = 0,
    staleParentRejects = 0,
    liveByPhysical = {},
}
local F = S.NativeObjectFactory

local KIND_TO_OBJECT = {
    window = "WINDOW",
    label = "LABEL",
    button = "BUTTON",
    emptywidget = "EMPTY_WIDGET",
    statusbar = "STATUS_BAR",
    slider = "SLIDER",
    editbox = "EDITBOX",
}

local function ParentOrRoot(parent)
    -- ArcheRage RU accepts the literal root token reliably, while some builds
    -- reject the UIParent userdata/object when it is passed back as the parent
    -- argument to UIParent:CreateWidget(). Normalize both root representations
    -- here so every top-level primitive gets the same constructor contract.
    if parent == nil or parent == UIParent or parent == "UIParent" then return "UIParent" end
    return parent
end

local function RecordFactoryFailure(code, physicalId, detail)
    local text = tostring(code or "native_factory_error") .. ":" .. tostring(physicalId or "?")
    if detail ~= nil and tostring(detail) ~= "" then text = text .. ":" .. tostring(detail) end
    if type(S.RecordLog) == "function" then S.RecordLog("error", "native_factory", text) end
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit("error", "native_factory", tostring(code or "NATIVE_FACTORY_ERROR"), "原生控件创建已被安全拒绝", {
            physicalId = tostring(physicalId or ""), detail = tostring(detail or ""),
        })
    end
end

function F:ValidatePhysicalId(physicalId)
    physicalId = tostring(physicalId or "")
    if physicalId == "" then return false, "empty_physical_id" end
    local identity = S.NativeIdentity
    local maxLength = type(identity) == "table" and tonumber(identity.maxPhysicalLength) or 23
    if maxLength ~= nil and #physicalId > maxLength then
        return false, "physical_id_too_long:" .. tostring(#physicalId) .. ">" .. tostring(maxLength)
    end
    return true
end


function F:ValidateParent(parent)
    if parent == nil or parent == "UIParent" then return true end
    -- Never cross into a C++ constructor with an object we already know belongs
    -- to a rejected component or a previous hot-reload generation.  A Lua pcall
    -- around CreateChildWidget cannot be relied on to recover from a native
    -- access violation, so the fence must run before the native call.
    local okRejected, rejected = pcall(function() return parent.rsUiRegistrationRejected end)
    if okRejected == true and rejected == true then return false, "parent_registration_rejected" end
    local okGeneration, generation = pcall(function() return parent.rsNativeGeneration end)
    generation = okGeneration == true and tonumber(generation) or nil
    if generation ~= nil and generation ~= tonumber(S.Generation) then
        return false, "stale_parent_generation:" .. tostring(generation) .. "!=" .. tostring(S.Generation)
    end
    return true
end

function F:RejectInvalidParent(parent, physicalId, kind)
    local valid, err = self:ValidateParent(parent)
    if valid == true then return false end
    self.staleParentRejects = (tonumber(self.staleParentRejects) or 0) + 1
    self.failures = (tonumber(self.failures) or 0) + 1
    RecordFactoryFailure("NATIVE_PARENT_REJECTED", physicalId, tostring(kind or "?") .. ":" .. tostring(err or "invalid_parent"))
    return true, err
end
function F:ReservePhysicalId(physicalId, kind)
    local valid, err = self:ValidatePhysicalId(physicalId)
    if valid == true and type(S.NativeIdentity) == "table" and type(S.NativeIdentity.physicalToLogical) == "table"
            and S.NativeIdentity.physicalToLogical[tostring(physicalId or "")] == nil then
        valid, err = false, "unregistered_physical_id"
    end
    if valid ~= true then
        self.invalidIdentityRejects = (tonumber(self.invalidIdentityRejects) or 0) + 1
        self.failures = (tonumber(self.failures) or 0) + 1
        RecordFactoryFailure("NATIVE_ID_INVALID", physicalId, err)
        return false, err
    end
    local previous = self.liveByPhysical[physicalId]
    if previous ~= nil then
        self.duplicateRejects = (tonumber(self.duplicateRejects) or 0) + 1
        self.failures = (tonumber(self.failures) or 0) + 1
        local detail = "requested=" .. tostring(kind or "?") .. "/existing=" .. tostring(previous.kind or "?")
        RecordFactoryFailure("NATIVE_ID_DUPLICATE", physicalId, detail)
        return false, "duplicate native widget identity: " .. tostring(physicalId)
    end
    -- Reserve before touching the C++ UI registry. If the constructor re-enters
    -- Suite code, a second attempt still fails closed instead of asking the
    -- client to resolve duplicate ownership.
    self.liveByPhysical[physicalId] = { kind = tostring(kind or ""), pending = true }
    return true
end

function F:CommitPhysicalId(physicalId, kind, widget)
    self.liveByPhysical[physicalId] = { kind = tostring(kind or ""), widget = widget, pending = false }
    if widget ~= nil then
        widget.rsNativePhysicalId = physicalId
        widget.rsNativeLogicalId = type(S.NativeIdentity) == "table" and S.NativeIdentity.physicalToLogical[physicalId] or nil
        widget.rsNativeGeneration = S.Generation
        widget.rsNativeKind = tostring(kind or "")
    end
end

function F:RollbackPhysicalId(physicalId)
    self.liveByPhysical[tostring(physicalId or "")] = nil
end

function F:EnsureKind(kind)
    kind = tostring(kind or ""):lower()
    local objectName = KIND_TO_OBJECT[kind]
    if objectName == nil then return true end
    if Imports == nil or type(Imports.AcquireObject) ~= "function" then return false, "native imports unavailable" end
    local def = Contract and Contract:GetObject(objectName) or nil
    local required = type(def) == "table" and def.optional ~= true
    local ok, err = Imports:AcquireObject("native_factory", objectName, required)
    if ok ~= true and required ~= true then return false, err end
    return ok, err
end

function F:Create(kind, physicalId, parent, category)
    kind = tostring(kind or ""):lower()
    physicalId = tostring(physicalId or "")
    if kind == "" or physicalId == "" then return nil, "invalid native widget identity" end
    local parentRejected, parentErr = self:RejectInvalidParent(parent, physicalId, kind)
    if parentRejected == true then return nil, parentErr end
    if UIParent == nil or type(UIParent.CreateWidget) ~= "function" then return nil, "UIParent:CreateWidget unavailable" end
    local kindOk, kindErr = self:EnsureKind(kind)
    if kindOk ~= true then return nil, kindErr end
    local reserved, reserveErr = self:ReservePhysicalId(physicalId, kind)
    if reserved ~= true then return nil, reserveErr end
    local ok, widget = pcall(function()
        if category ~= nil or kind == "window" or kind == "button" then
            return UIParent:CreateWidget(kind, physicalId, ParentOrRoot(parent), tostring(category or ""))
        end
        return UIParent:CreateWidget(kind, physicalId, ParentOrRoot(parent))
    end)
    if ok ~= true or widget == nil then
        self:RollbackPhysicalId(physicalId)
        self.failures = (tonumber(self.failures) or 0) + 1
        local detail = tostring(ok and "CreateWidget returned nil" or widget)
        RecordFactoryFailure("NATIVE_CREATE_FAILED", physicalId, detail)
        return nil, detail
    end
    self:CommitPhysicalId(physicalId, kind, widget)
    self.created = (tonumber(self.created) or 0) + 1
    return widget
end

function F:CreateWindow(physicalId, parent, category)
    local widget, err = self:Create("window", physicalId, parent or "UIParent", category or "")
    if widget ~= nil and type(widget.Show) == "function" then pcall(function() widget:Show(false) end) end
    return widget, err
end

function F:CreateEmptyWidget(physicalId, parent)
    return self:Create("emptywidget", physicalId, parent or "UIParent")
end

function F:CreateButton(physicalId, parent, category)
    return self:Create("button", physicalId, parent or "UIParent", category or "")
end

function F:CreateChild(parent, kind, physicalId, index, visible)
    kind = tostring(kind or ""):lower()
    physicalId = tostring(physicalId or "")
    local parentRejected, parentErr = self:RejectInvalidParent(parent, physicalId, kind)
    if parentRejected == true then return nil, parentErr end
    if parent == nil or type(parent.CreateChildWidget) ~= "function" then return nil, "CreateChildWidget unavailable" end
    local kindOk, kindErr = self:EnsureKind(kind)
    if kindOk ~= true then return nil, kindErr end
    local reserved, reserveErr = self:ReservePhysicalId(physicalId, kind)
    if reserved ~= true then return nil, reserveErr end
    local ok, widget = pcall(function()
        return parent:CreateChildWidget(kind, physicalId, tonumber(index) or 0, visible ~= false)
    end)
    if ok ~= true or widget == nil then
        self:RollbackPhysicalId(physicalId)
        self.failures = (tonumber(self.failures) or 0) + 1
        local detail = tostring(ok and "CreateChildWidget returned nil" or widget)
        RecordFactoryFailure("NATIVE_CHILD_CREATE_FAILED", physicalId, detail)
        return nil, detail
    end
    self:CommitPhysicalId(physicalId, kind, widget)
    self.created = (tonumber(self.created) or 0) + 1
    return widget
end

function F:CreateChildByObject(parent, objectName, physicalId, index, visible)
    objectName = tostring(objectName or ""):upper()
    physicalId = tostring(physicalId or "")
    local parentRejected, parentErr = self:RejectInvalidParent(parent, physicalId, objectName)
    if parentRejected == true then return nil, parentErr end
    if parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil, "CreateChildWidgetByType unavailable" end
    local def = Contract and Contract:GetObject(objectName) or nil
    if type(def) ~= "table" or def.id == nil then return nil, "unknown native object: " .. objectName end
    if Imports == nil or type(Imports.AcquireObject) ~= "function" then return nil, "native imports unavailable" end
    local importOk, importErr = Imports:AcquireObject("native_factory", objectName, def.optional ~= true)
    if importOk ~= true then
        self.failures = (tonumber(self.failures) or 0) + 1
        RecordFactoryFailure("NATIVE_OBJECT_IMPORT_FENCE", physicalId, tostring(objectName) .. ":" .. tostring(importErr or "import_failed"))
        return nil, importErr or ("native object import failed: " .. tostring(objectName))
    end
    local reserved, reserveErr = self:ReservePhysicalId(physicalId, objectName)
    if reserved ~= true then return nil, reserveErr end
    local ok, widget = pcall(function()
        return parent:CreateChildWidgetByType(def.id, physicalId, tonumber(index) or 0, visible ~= false)
    end)
    if ok ~= true or widget == nil then
        self:RollbackPhysicalId(physicalId)
        self.failures = (tonumber(self.failures) or 0) + 1
        local detail = tostring(ok and "CreateChildWidgetByType returned nil" or widget)
        RecordFactoryFailure("NATIVE_TYPED_CHILD_CREATE_FAILED", physicalId, detail)
        return nil, detail
    end
    self:CommitPhysicalId(physicalId, objectName, widget)
    self.created = (tonumber(self.created) or 0) + 1
    return widget
end

function F:Validate()
    if Contract == nil then return false, "native contract unavailable" end
    if Imports == nil then return false, "native imports unavailable" end
    if UIParent == nil or type(UIParent.CreateWidget) ~= "function" then return false, "UIParent:CreateWidget unavailable" end
    return true
end

function F:Describe()
    local live = 0
    for _ in pairs(self.liveByPhysical or {}) do live = live + 1 end
    return {
        version = self.version, owner = self.owner, created = tonumber(self.created) or 0, failures = tonumber(self.failures) or 0,
        duplicateRejects = tonumber(self.duplicateRejects) or 0, invalidIdentityRejects = tonumber(self.invalidIdentityRejects) or 0,
        staleParentRejects = tonumber(self.staleParentRejects) or 0, live = live,
        objectImportFenceContractVersion = tonumber(self.objectImportFenceContractVersion) or 0,
    }
end
