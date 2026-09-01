------------------------------------------------------------------------
-- Replicated Suite V3 - Native Foundation Capabilities
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite

S.NativeCapabilities = { version = 3, owner = "Replicated Suite" }
local N = S.NativeCapabilities

function N:Validate()
    local contract = S.NativeContract
    local imports = S.NativeImports
    local factory = S.NativeObjectFactory
    local identity = S.NativeIdentity
    if type(contract) ~= "table" or tostring(contract.owner or "") ~= "Replicated Suite" then return false, "contract ownership invalid" end
    if type(imports) ~= "table" or tostring(imports.source or "") ~= "replicated_native"
            or (tonumber(imports.version) or 0) < 3 or (tonumber(imports.optionalNegativeCacheContractVersion) or 0) < 1
            or (tonumber(imports.methodDependencyResolutionContractVersion) or 0) < 1 then
        return false, "native imports invalid"
    end
    if type(factory) ~= "table" or tostring(factory.owner or "") ~= "Replicated Suite" or (tonumber(factory.version) or 0) < 3
            or (tonumber(factory.objectImportFenceContractVersion) or 0) < 1
            or type(factory.ValidateParent) ~= "function" or type(factory.ReservePhysicalId) ~= "function" then return false, "native factory invalid" end
    if type(identity) ~= "table" or (tonumber(identity.version) or 0) < 2 or type(identity.Build) ~= "function" then return false, "native identity invalid" end
    if (tonumber(identity.maxPhysicalLength) or 99) > 23 then return false, "native identity length budget invalid" end
    local factoryOk, factoryErr = factory:Validate()
    if factoryOk ~= true then return false, factoryErr end
    local d = imports:Describe()
    if (tonumber(d.foundationFailures) or 0) > 0 then
        return false, "native foundation import failures=" .. tostring(d.foundationFailures)
    end
    return true
end

function N:Describe()
    local contract = S.NativeContract and S.NativeContract:Describe() or nil
    local imports = S.NativeImports and S.NativeImports:Describe() or nil
    local factory = S.NativeObjectFactory and S.NativeObjectFactory:Describe() or nil
    local esc = S.NativeEscBridge and S.NativeEscBridge:Describe() or nil
    return {
        version = self.version,
        owner = self.owner,
        contract = contract,
        imports = imports,
        factory = factory,
        identity = type(S.DescribeNativeIdentity) == "function" and S.DescribeNativeIdentity() or nil,
        esc = esc,
        externalGlobalsConsumed = 0,
        legacyUiHelpersConsumed = 0,
    }
end
