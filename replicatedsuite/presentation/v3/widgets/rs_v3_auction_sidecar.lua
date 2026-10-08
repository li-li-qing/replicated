------------------------------------------------------------------------
-- Replicated Suite V3 - Auction Workspace Sidecar
--
-- Presentation-only companion to the native Auction House. Initial placement
-- and visibility come from AuctionSurfaceV3; user placement has its own Store.
-- Persistent favorites remain owned by tools_auction;
-- daily quest facts remain owned by QuestProgressV3/DailyAuctionMaterialsV3;
-- temporary shopping groups remain owned by AuctionSessionListV3.
--
-- No background auction search is introduced here. Every query is caused by
-- an explicit user click and routes through tools_auction -> AuctionSearchBridgeV3
-- -> AuctionQueryV3. Native EditBox synchronization is best-effort only.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.tools_auction or nil
local SurfaceService = S.Services and S.Services.AuctionSurfaceV3 or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table"
    or type(Feature) ~= "table" or type(SurfaceService) ~= "table" then return end

local WIDGET_ID = "tools.auction_sidecar"
local OWNER = "v3:widget:auction_sidecar"
local WIDTH, HEIGHT = 300, 440
local DAILY_TOKEN = "widget:auction_sidecar:daily"

local Controller = {
    version = 6,
    ScaledPlacementContractVersion = 1,
    FreePlacementContractVersion = 1, DurablePlacementContractVersion = 1,
    AuctionWorkspaceContractVersion = 1,
    SidecarControlContractVersion = 2,
    ControlTopic = "v3.auction_sidecar.control_state",
    nativeVisible = false,
    dismissed = false,
    snapshot = nil,
}
S.UIV3 = S.UIV3 or {}
S.UIV3.AuctionSidecar = Controller

-- 独立 Presentation 布局档，不改收藏业务档或 AuxWindow 历史 canonical。
local Persistence=S.Persistence
local POSITION_STORE="v3.presentation.auction_sidecar_position"
local function NormalizePosition(value)
    value=type(value)=="table" and value or {}
    local out={userMoved=value.userMoved==true}
    if out.userMoved then
        out.coordinateSpace="logical-free-v2"
        for _,key in ipairs({"x","y","savedUiScale","savedLogicalWidth","savedLogicalHeight","normalizedCenterX","normalizedCenterY"})do
            local n=tonumber(value[key])
            if n and n==n and n~=math.huge and n~=-math.huge then out[key]=n end
        end
        if out.x==nil or out.y==nil then return {userMoved=false} end
    end
    return out
end
Controller.positionState=NormalizePosition(nil)
Controller.positionStore=POSITION_STORE
if type(Persistence)=="table" and type(Persistence.RegisterV3Store)=="function" then
    local store,err=Persistence:RegisterV3Store({
        id=POSITION_STORE,owner=POSITION_STORE,scope=Persistence.Scope.Account,lifetime=Persistence.Lifetime.Permanent,
        schemaVersion=1,key=Persistence.V3KeyPrefix.."presentation_auction_sidecar_position",
        budget={maxDepth=3,maxNodes=32,maxStringBytes=256,maxEntriesPerTable=16},
        default=function()return NormalizePosition(nil) end,
        get=function()return NormalizePosition(Controller.positionState) end,
        apply=function(value)Controller.positionState=NormalizePosition(value) end,
    })
    if store==nil then Controller.positionError=tostring(err or "拍卖助手位置存档注册失败") end
else Controller.positionError="拍卖助手位置存档不可用" end
function Controller:EnsurePositionLoaded()
    if type(Persistence)~="table" then return false,self.positionError end
    if Persistence:IsStoreLoaded(POSITION_STORE)==true then return true end
    if self.positionLoadAttempted then return false,self.positionError end
    self.positionLoadAttempted=true
    local status,_,err=Persistence:LoadStore(POSITION_STORE)
    if status~=true and status~="empty" then self.positionError=tostring(err or status or "位置读取失败");return false,self.positionError end
    self.positionError=nil;return true
end
function Controller:GetHealth()
    return {version=self.version,movable=true,positionStore=POSITION_STORE,
        positionLoaded=Persistence and Persistence:IsStoreLoaded(POSITION_STORE)==true or false,
        positionError=self.positionError,positionState=NormalizePosition(self.positionState)}
end
if type(S.ModuleDiagnosticsHub)=="table" and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function" then
    S.ModuleDiagnosticsHub:RegisterProvider("tools_auction","auction_free_position",function()return Controller:GetHealth() end,55,{detailOnly=true})
end

local function Trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$")) or ""
end

local function CopyState(target, source)
    if type(target) ~= "table" or type(source) ~= "table" then return false end
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
    return true
end

local function DailyService()
    return S.Services and S.Services.DailyAuctionMaterialsV3 or nil
end

local function SessionService()
    return S.Services and S.Services.AuctionSessionListV3 or nil
end

local function SidecarPreferenceEnabled()
    -- 中文维护注释（2026-09-15，Sidecar 偏好读取边界）：悬浮助手是否启用属于
    -- tools_auction Feature 永久偏好，Controller 只读公开 facade，不直接读取 Feature 的私有 State / Store。
    -- facade 缺失时仅为旧实现兼容而默认 true；当前 Gate 会阻断正式包缺失该契约。
    if type(Feature.IsSidecarEnabled) ~= "function" then return true end
    return Feature:IsSidecarEnabled() == true
end

-- 中文维护注释（2026-09-15，拍卖主页面 Sidecar 入口）：
-- 问题原因：拍卖助手原本只靠 AuctionSurfaceV3 在原生拍卖行打开时自动显示；用户手动关闭后，
-- 当前拍卖行会话内 dismissed=true，主页面既不知道助手状态，也没有受控的重新打开入口。
-- Authority/数据流：原生拍卖行可见性仍只来自 AuctionSurfaceV3 -> OnSurface；Widget 可见性仍只由
-- WidgetHost 管理。这里仅暴露 detached 的只读控制状态和显式用户动作 RequestShow，Presentation
-- 不直接改 Host、dismissed 或 SurfaceService。收藏/今日任务/临时清单数据 Authority 完全不变。
-- 兼容边界：新增的永久 sidecarEnabled 由 tools_auction Feature 持有，旧 payload 缺字段默认 true；
-- Controller 不写 Store。dismissed 仍只是本次原生拍卖行打开期间的一次性 Session 状态，两者不可混用。
-- 实现理由：主页面和 Sidecar 同属 Presentation，使用一个轻量 ControlTopic 只同步 UI 状态，避免为了
-- 一个按钮复制第二套生命周期。风险：后续若增加新的 Sidecar 隐藏来源，也必须经 Controller 发布状态，
-- 否则主页面按钮文案可能暂时落后；严禁绕过 RequestShow 直接 WidgetHost:SetVisible。
function Controller:GetControlState()
    local enabled = SidecarPreferenceEnabled()
    local nativeVisible = self.nativeVisible == true
    local visible = Host:IsVisible(WIDGET_ID) == true
    return {
        enabled = enabled,
        nativeVisible = nativeVisible,
        visible = visible,
        dismissed = self.dismissed == true,
        canShow = enabled and nativeVisible and visible ~= true,
    }
end

function Controller:PublishControlState(reason)
    if S.Events == nil or type(S.Events.Publish) ~= "function" then return true end
    return S.Events:Publish(self.ControlTopic, self:GetControlState(), tostring(reason or "auction_sidecar_control"))
end

function Controller:RequestShow(source)
    if SidecarPreferenceEnabled() ~= true then return false, "请先开启悬浮助手" end
    if self.nativeVisible ~= true then return false, "请先打开游戏拍卖行" end
    self.dismissed = false
    local shown, showErr = Host:SetVisible(WIDGET_ID, true, {
        persist = false, source = tostring(source or "auction_sidecar_explicit_show"), snapshot = self.snapshot,
    })
    if shown ~= true then
        self:PublishControlState("explicit_show_failed")
        return false, showErr or "拍卖助手显示失败"
    end
    local instance = Host:GetInstance(WIDGET_ID)
    if type(instance) == "table" and type(instance.ApplyAnchor) == "function" then
        local anchored, anchorErr = instance:ApplyAnchor(self.snapshot)
        if anchored ~= true then
            self:PublishControlState("explicit_show_anchor_failed")
            return false, anchorErr or "拍卖助手定位失败"
        end
    end
    self:PublishControlState("explicit_show")
    return true
end

local function FavoriteRows()
    local projection = Feature:GetProjection() or {}
    local out = {}
    -- 中文维护注释（2026-09-14，收藏稳定选择）：永久 Store 仍是历史 string[]，这里用 keyword 生成
    -- Presentation key，而不是 favoriteIndex。排序后 index 会变化，但 keyword 唯一，所以删除/移动不会误操作别行。
    -- 中文维护注释（2026-09-30，presentation-private-state-1）：收藏列表改走 Feature 的公开只读
    -- facade，不再直接读 State 私有字段 —— Presentation 只消费投影/公开入口，不碰事实本体。
    -- 返回的已是重新归一后的新表，改它不会写回持久化。
    for _, keyword in ipairs(type(Feature) == "table" and type(Feature.GetFavorites) == "function" and Feature:GetFavorites() or {}) do
        keyword = tostring(keyword or "")
        if keyword ~= "" then
            out[#out + 1] = {
                key = "favorite:" .. keyword,
                kind = "favorite",
                favoriteKeyword = keyword,
                name = keyword,
                status = "点击查询",
                searchable = true,
            }
        end
    end
    return out, projection
end

local function DailyRows()
    local service = DailyService()
    local snapshot = type(service) == "table" and type(service.GetSnapshot) == "function" and service:GetSnapshot() or { status = "unavailable", tasks = {} }
    local rows = {}
    for _, task in ipairs(type(snapshot.tasks) == "table" and snapshot.tasks or {}) do
        local qid = math.floor(tonumber(task.questId) or 0)
        local taskTitle = Trim(task.title)
        if taskTitle == "" then taskTitle = qid > 0 and ("居民做货任务 #" .. tostring(qid)) or "居民做货任务" end
        local recipes = type(task.recipes) == "table" and task.recipes or {}
        -- 中文维护（2026-10-04）：今日任务用于采购，正常任务直接接材料行。
        -- 解析原因留在共享服务诊断；真正缺材料的任务仍提示不可用，不能伪造材料或空成功。
        local taskStatus = ""
        if task.requiresSelection == true then taskStatus = "请选择制作货物"
        elseif #(task.materials or {}) == 0 then taskStatus = "材料暂不可用" end
        rows[#rows + 1] = {
            key = "daily:task:" .. tostring(qid), kind = "daily_task", questId = qid,
            name = taskTitle,
            status = taskStatus,
        }
        -- 只有真正任选其一的任务才需要货物选择；唯一配方不能再多占一行“候选货物”。
        -- 多配方沿用服务本地化名称与选择入口，绝不累计所有配方材料或暴露内部英文键。
        local optionByRecipe = {}
        for _, option in ipairs(type(task.recipeOptions) == "table" and task.recipeOptions or {}) do
            if type(option) == "table" and tostring(option.recipe or "") ~= "" then optionByRecipe[tostring(option.recipe)] = option end
        end
        for index, recipe in ipairs(#recipes > 1 and recipes or {}) do
            recipe = tostring(recipe or "")
            local option = optionByRecipe[recipe]
            local displayName = type(option) == "table" and Trim(option.name) or ""
            if displayName == "" or displayName:find("^候选货物") then displayName = "制作方案 " .. tostring(index) end
            rows[#rows + 1] = {
                key = "daily:recipe:" .. tostring(qid) .. ":" .. tostring(index), kind = "daily_recipe",
                questId = qid, recipe = recipe,
                name = "  " .. displayName,
                status = tostring(task.selectedRecipe or "") == recipe and "当前选择" or "点击选择",
            }
        end
        for _, material in ipairs(type(task.materials) == "table" and task.materials or {}) do
            if material.hidden ~= true then
                rows[#rows + 1] = {
                    key = "daily:material:" .. tostring(qid) .. ":" .. tostring(material.key or ""), kind = "daily_material",
                    questId = qid, recipe = tostring(material.recipe or task.selectedRecipe or ""), materialKey = tostring(material.key or ""),
                    itemType = tonumber(material.itemType), name = "  " .. tostring(material.name or "材料"),
                    searchKeyword = tostring(material.name or ""), searchable = material.searchable ~= false,
                    status = "×" .. tostring(math.max(0, tonumber(material.count) or 0)),
                }
            end
        end
    end
    return rows, snapshot
end

local function TempRows()
    local service = SessionService()
    local snapshot = type(service) == "table" and type(service.GetSnapshot) == "function" and service:GetSnapshot() or { status = "unavailable", groups = {} }
    local rows = {}
    for _, group in ipairs(type(snapshot.groups) == "table" and snapshot.groups or {}) do
        local groupId = tonumber(group.id)
        rows[#rows + 1] = {
            key = "temp:group:" .. tostring(groupId or 0), kind = "temp_group", groupId = groupId,
            name = tostring(group.productName or "临时货物"), status = "货物组 · " .. tostring(#(group.materials or {})) .. "项",
        }
        for _, material in ipairs(type(group.materials) == "table" and group.materials or {}) do
            rows[#rows + 1] = {
                key = "temp:material:" .. tostring(groupId or 0) .. ":" .. tostring(material.key or ""), kind = "temp_material",
                groupId = groupId, materialKey = tostring(material.key or ""), itemType = tonumber(material.itemType),
                name = "  " .. tostring(material.name or "材料"), searchKeyword = tostring(material.name or ""),
                count = tonumber(material.count) or 0, searchable = material.searchable ~= false,
                status = "×" .. tostring(math.max(0, tonumber(material.count) or 0)),
            }
        end
    end
    return rows, snapshot
end

local function SidecarPosition(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local safeLeft = tonumber(context.safeLeft) or 0
    local safeTop = tonumber(context.safeTop) or 0
    local safeRight = tonumber(context.safeRight) or 0
    local safeBottom = tonumber(context.safeBottom) or 0
    local logicalWidth = tonumber(context.logicalWidth) or 1024
    local logicalHeight = tonumber(context.logicalHeight) or 768
    local auctionX = tonumber(snapshot.x) or safeLeft
    local auctionY = tonumber(snapshot.y) or safeTop
    local auctionWidth = math.max(1, tonumber(snapshot.width) or 1)
    local auctionHeight = math.max(1, tonumber(snapshot.height) or 1)
    -- FloatingSurface 会应用插件缩放一次；这里必须用同一实际显示尺寸留出距离。
    local scale=math.max(0.01,tonumber(context.addonScale) or 1)
    local width=math.min(WIDTH*scale,math.max(1,logicalWidth-safeLeft-safeRight))
    local height=math.min(HEIGHT*scale,math.max(1,logicalHeight-safeTop-safeBottom))
    local right,bottom=logicalWidth-safeRight,logicalHeight-safeBottom
    local gap = 8
    local x,y=auctionX-width-gap,auctionY
    if x<safeLeft then
        x=auctionX+auctionWidth+gap
        if x+width>right then
            -- 横向放不下时先尝试下方/上方，避免夹紧到拍卖行里面。
            x=auctionX
            if auctionY+auctionHeight+gap+height<=bottom then y=auctionY+auctionHeight+gap
            elseif auctionY-height-gap>=safeTop then y=auctionY-height-gap
            else
                local leftSpace,rightSpace=auctionX-safeLeft,right-auctionX-auctionWidth
                x=leftSpace>=rightSpace and safeLeft or right-width
            end
        end
    end
    x = math.max(safeLeft, math.min(x, right-width))
    y = math.max(safeTop, math.min(y, bottom-height))
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function CreateSidecar()
    Controller:EnsurePositionLoaded()
    S.Layout:GetContext(true)
    local x, y = SidecarPosition(Controller.snapshot)
    local state = {
        width = WIDTH, height = HEIGHT, minimized = false, locked = false,
        overallOpacity = 0.96, backgroundOpacity = 1.0, textOpacity = 1.0, fontScale = 1.0,
        userMoved = false, x = x, y = y, coordinateSpace = "logical-free-v2",
    }
    for key,value in pairs(Controller.positionState)do state[key]=value end
    local defaultIntent={userMoved=true}
    local context=S.Layout:GetContext()
    local scale=math.max(.01,tonumber(context.addonScale) or 1)
    S.Layout:StorePlacementRect(defaultIntent,x,y,math.min(WIDTH*scale,context.usableWidth),math.min(HEIGHT*scale,context.usableHeight),{mode="free"})
    local instance = {
        visible = false, acquired = false, subscribed = false, dailyAcquired = false,
        selectedIndex = nil, selectedKey = nil, selectedRow = nil, activeTab = "favorites",
        clearArmedTab = nil, state = state,
    }

    local surface, surfaceErr = Floating:Create({
        id = "v3_auction_sidecar", owner = OWNER, title = "拍卖助手", status = "拖动标题调整位置",
        width = WIDTH, height = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
        resizable = false, movable = true, footer = true, closeButton = true, appearanceControls = false,
        defaultPosition=function(_,width,height)
            return S.Layout:ResolvePlacement(defaultIntent,width,height,x,y,{mode="free",topLevel=true,topReachHeight=24})
        end,
        minimizeMode = "compact", boundaryMode = "free",
        statePolicy = { defaultWidth = WIDTH, defaultHeight = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
            defaultLocked = false, defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 },
        getState = function() return instance.state end,
        setState = function(value)
            if type(value) ~= "table" then return false, "sidecar state invalid" end
            CopyState(instance.state, value)
            Controller.positionState=NormalizePosition(instance.state)
            return true
        end,
        persist = function(reason)
            if reason~="geometry" and reason~="layout_reset" then return true end
            local loaded,loadErr=Controller:EnsurePositionLoaded()
            if loaded~=true then return false,loadErr end
            local saved,saveErr=Persistence:SaveStore(POSITION_STORE,{durable=true,consumeDirty=true,reason="auction_sidecar:"..tostring(reason)})
            Controller.positionError=saved~=true and tostring(saveErr or "位置保存失败") or nil
            return saved,saveErr
        end,
        onClosed = function(_, reason)
            Controller.dismissed = true
            local closed, closeErr = Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "auction_sidecar_close") })
            Controller:PublishControlState("manual_close")
            return closed, closeErr
        end,
    })
    if surface == nil then return nil, surfaceErr or "拍卖助手侧窗创建失败" end
    instance.surface, instance.shell, instance.windowController = surface, surface.shell, surface.windowController

    local content = surface:GetContentRoot()
    local root = RSUI:VerticalBox({ id = "v3_auction_sidecar_content", parent = content, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })

    local tabRow = RSUI:HorizontalBox({ id = "v3_auction_sidecar_tabs", parent = root, gap = 4,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    instance.tabButtons = {
        favorites = RSUI:Button({ id = "v3_auction_sidecar_tab_favorites", parent = tabRow, text = "● 收藏", compact = true, slot = { size = "fill", fill = 1 } }),
        daily = RSUI:Button({ id = "v3_auction_sidecar_tab_daily", parent = tabRow, text = "今日任务", compact = true, slot = { size = "fill", fill = 1 } }),
        temp = RSUI:Button({ id = "v3_auction_sidecar_tab_temp", parent = tabRow, text = "临时", compact = true, slot = { size = "fill", fill = 1 } }),
    }

    local searchRow = RSUI:HorizontalBox({ id = "v3_auction_sidecar_search_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    instance.searchRow = searchRow
    -- 中文维护注释（2026-09-14，Auction Sidecar 临时数量可读性）：临时页签的第二个输入框是手工
    -- 添加材料时的数量，不是第二个搜索框。旧布局只有默认值“1”，用户无法从视觉上判断其语义。
    -- 在数量框前增加轻量“×”标记，并只在临时页签显示；收藏/今日任务数据流与搜索行为不变。
    -- 两个 Sidecar 单行 EditBox 显式以 22px 创建，使 RU Native caret 使用更短的现有 shared caret 预算；
    -- HorizontalBox 仍会按 30px 行高 Arrange，因此只改变光标视觉，不缩小实际点击区域，也不改全局 EditBox。
    instance.input = RSUI:TextInput({ id = "v3_auction_sidecar_keyword", parent = searchRow, value = "", maxLength = 64,
        allowEmpty = false, placeholder = "物品名称", height = 22, slot = { size = "fill", fill = 1, minWidth = 78 } })
    instance.qtyLabel = RSUI:Text({ id = "v3_auction_sidecar_qty_label", parent = searchRow, text = "×", fontSize = 10, tone = "muted",
        slot = { size = "fixed", width = 12, hAlign = "center" } })
    instance.qtyInput = RSUI:TextInput({ id = "v3_auction_sidecar_qty", parent = searchRow, value = "1", maxLength = 6,
        allowEmpty = false, placeholder = "数量", height = 22, slot = { size = "fixed", width = 42 } })
    instance.searchButton = RSUI:Button({ id = "v3_auction_sidecar_search", parent = searchRow, text = "搜索", compact = true,
        slot = { size = "fixed", width = 48 } })
    instance.addButton = RSUI:Button({ id = "v3_auction_sidecar_add", parent = searchRow, text = "添加", compact = true,
        slot = { size = "fixed", width = 54 } })

    local actionRow = RSUI:HorizontalBox({ id = "v3_auction_sidecar_action_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    instance.upButton = RSUI:Button({ id = "v3_auction_sidecar_up", parent = actionRow, text = "上移", compact = true, slot = { size = "fill", fill = 1 } })
    instance.downButton = RSUI:Button({ id = "v3_auction_sidecar_down", parent = actionRow, text = "下移", compact = true, slot = { size = "fill", fill = 1 } })
    instance.editButton = RSUI:Button({ id = "v3_auction_sidecar_edit", parent = actionRow, text = "修改", compact = true, slot = { size = "fill", fill = 1 } })
    instance.removeButton = RSUI:Button({ id = "v3_auction_sidecar_remove", parent = actionRow, text = "删除", compact = true, slot = { size = "fill", fill = 1 } })
    instance.clearButton = RSUI:Button({ id = "v3_auction_sidecar_clear", parent = actionRow, text = "清空", compact = true, slot = { size = "fill", fill = 1 } })

    -- 中文维护注释（2026-09-14，Auction Sidecar logical-id Authority）：FloatingSurface 的 id 是
    -- `v3_auction_sidecar`，WindowShellV3 会在 footer 内部自动消费保留 logical id
    -- `v3_auction_sidecar_status`。这里属于业务内容区的操作反馈，不是 WindowShell footer Authority；
    -- 若复用该 id，会在同一 Build Generation 触发 logical_id_already_consumed_this_generation，
    -- 使整个 Sidecar 被 WidgetHost 隔离。改用专属 `..._action_status`，只改变 Presentation 身份，
    -- 不改变收藏/任务/临时清单数据流、AuctionQueryV3 查询 Authority、Store 或用户升级兼容。
    instance.status = RSUI:Text({ id = "v3_auction_sidecar_action_status", parent = root, text = "收藏与主菜单共用同一数据", fontSize = 8,
        tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 22, hAlign = "fill" } })

    local function SelectedRow()
        if type(instance.selectedRow) == "table" then return instance.selectedRow end
        local key = tostring(instance.selectedKey or "")
        if key ~= "" then for _, row in ipairs(instance.currentRows or {}) do if tostring(row.key or "") == key then return row end end end
        local index = tonumber(instance.selectedIndex)
        return index and (instance.currentRows or {})[index] or nil
    end

    local function UpdateActionButtons()
        local row = SelectedRow()
        local kind = row and tostring(row.kind or "") or ""
        local canMove = kind == "favorite" or kind == "daily_material" or kind == "temp_group" or kind == "temp_material"
        local canEdit = kind == "favorite" or kind == "temp_group" or kind == "temp_material"
        local canRemove = kind == "favorite" or kind == "daily_material" or kind == "temp_group" or kind == "temp_material"
        instance.upButton:SetEnabled(canMove)
        instance.downButton:SetEnabled(canMove)
        instance.editButton:SetEnabled(canEdit)
        instance.removeButton:SetEnabled(canRemove)
        instance.clearButton:SetEnabled(instance.activeTab ~= "daily" or #(instance.currentRows or {}) > 0)
    end

    local function SearchKeyword(rawKeyword)
        local keyword = Trim(rawKeyword)
        if keyword == "" then instance.status:SetText("请输入要搜索的物品名称"); return false, "搜索关键词为空" end
        instance.input:SetValue(keyword, false, "auction_sidecar_search")
        local ok, searchErr = Feature:Search(keyword)
        local projection = Feature:GetProjection() or {}
        if ok == true then
            if tostring(projection.nativeSync or "") == "success" then
                instance.status:SetText("已同步搜索栏并查询：" .. keyword)
            else
                instance.status:SetText("已直接查询：" .. keyword .. "（原生搜索栏未同步）")
            end
        else
            instance.status:SetText("查询失败：" .. tostring(searchErr or "未执行"))
        end
        return ok, searchErr
    end
    instance.SearchKeyword = SearchKeyword

    instance.table = RSUI:TableView({
        id = "v3_auction_sidecar_table", parent = root, items = {}, rowHeight = 27, headerHeight = 26,
        desiredRows = 9, overscan = 1, scrollbar = true, selectable = true, selectionMode = "single", columnResize = false, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        onSelectionChanged = function(index, key, view)
            instance.selectedIndex = tonumber(index)
            local row = instance.selectedIndex and ((type(view) == "table" and type(view.GetItem) == "function" and view:GetItem(instance.selectedIndex)) or (instance.currentRows or {})[instance.selectedIndex]) or nil
            instance.selectedRow = row
            instance.selectedKey = row and tostring(row.key or key or "") or nil
            instance.clearArmedTab = nil
            if type(row) == "table" then
                if row.kind == "favorite" then instance.input:SetValue(tostring(row.favoriteKeyword or row.name or ""), false, "auction_sidecar_select") end
                if row.kind == "temp_group" then instance.input:SetValue(tostring(row.name or ""), false, "auction_sidecar_select") end
                if row.kind == "temp_material" then
                    instance.input:SetValue(tostring(row.searchKeyword or row.name or ""):gsub("^%s+", ""), false, "auction_sidecar_select")
                    instance.qtyInput:SetValue(tostring(row.count or 1), false, "auction_sidecar_select")
                end
            end
            UpdateActionButtons()
        end,
        onItemActivated = function(item)
            if type(item) ~= "table" then return false end
            if item.kind == "favorite" then return SearchKeyword(item.favoriteKeyword or item.name) end
            if item.kind == "daily_material" then
                if item.searchable == false then instance.status:SetText("该材料不参与拍卖行查询"); return false, "材料不可拍卖搜索" end
                return SearchKeyword(item.searchKeyword or item.name)
            end
            if item.kind == "daily_recipe" then
                local service = DailyService()
                if type(service) ~= "table" or type(service.SelectRecipe) ~= "function" then return false, "今日任务材料服务不可用" end
                local ok, selectErr = service:SelectRecipe(item.questId, item.recipe)
                instance.status:SetText(ok == true and "已选择该任务货物，只解析这一种货物材料" or ("选择失败：" .. tostring(selectErr or "未执行")))
                if ok == true then instance:Refresh() end
                return ok, selectErr
            end
            if item.kind == "temp_material" then
                if item.searchable == false then instance.status:SetText("该临时材料不参与拍卖行查询"); return false, "材料不可拍卖搜索" end
                instance.qtyInput:SetValue(tostring(item.count or 1), false, "auction_sidecar_activate")
                return SearchKeyword(item.searchKeyword or item.name)
            end
            if item.kind == "temp_group" then
                instance.input:SetValue(tostring(item.name or ""), false, "auction_sidecar_activate")
                return true
            end
            return true
        end,
        columns = {
            { id = "name", title = "内容", field = "name", size = "fill", minWidth = 150, fill = 1.5 },
            { id = "status", title = "数量 / 状态", field = "status", size = "fixed", width = 94, minWidth = 78, tone = "muted" },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    if root == nil or tabRow == nil or searchRow == nil or instance.input == nil or instance.qtyInput == nil
        or instance.searchButton == nil or instance.addButton == nil or instance.upButton == nil or instance.downButton == nil
        or instance.editButton == nil or instance.removeButton == nil or instance.clearButton == nil or instance.status == nil
        or instance.table == nil or instance.tabButtons.favorites == nil or instance.tabButtons.daily == nil or instance.tabButtons.temp == nil then
        return nil, "拍卖助手侧窗控件构建失败"
    end

    local function Keyword()
        return type(instance.input.GetDraftValue) == "function" and Trim(instance.input:GetDraftValue()) or ""
    end
    local function Quantity()
        local value = type(instance.qtyInput.GetDraftValue) == "function" and tonumber(instance.qtyInput:GetDraftValue()) or nil
        if value == nil or value <= 0 then return nil end
        return math.max(1, math.floor(value + 0.5))
    end
    local function SetVisible(component, visible)
        if type(component) == "table" and type(component.SetVisibility) == "function" then component:SetVisibility(visible and "visible" or "collapsed") end
    end

    function instance:ReleaseDailyConsumer(reason)
        if self.dailyAcquired ~= true then return true end
        local service = DailyService()
        local ok, releaseErr = true, nil
        if type(service) == "table" and type(service.ReleaseConsumer) == "function" then ok, releaseErr = service:ReleaseConsumer(DAILY_TOKEN) end
        if ok == true then self.dailyAcquired = false end
        return ok, releaseErr or reason
    end

    function instance:AcquireDailyConsumer()
        if self.dailyAcquired == true then return true end
        local service = DailyService()
        if type(service) ~= "table" or type(service.AcquireConsumer) ~= "function" then return false, "今日任务材料服务不可用" end
        local ok, acquireErr = service:AcquireConsumer(DAILY_TOKEN)
        if ok == true then self.dailyAcquired = true end
        return ok, acquireErr
    end

    function instance:UpdateTabChrome()
        local labels = { favorites = "收藏", daily = "今日任务", temp = "临时" }
        for key, button in pairs(self.tabButtons) do button:SetText((self.activeTab == key and "● " or "") .. labels[key]) end
        SetVisible(self.searchRow, self.activeTab ~= "daily")
        SetVisible(self.qtyLabel, self.activeTab == "temp")
        SetVisible(self.qtyInput, self.activeTab == "temp")
        if self.activeTab == "favorites" then
            self.input.spec.placeholder = "收藏/搜索物品"
            self.addButton:SetText("添加")
            self.editButton:SetText("改名")
            self.removeButton:SetText("删除")
            self.clearButton:SetText("清空")
        elseif self.activeTab == "daily" then
            self.editButton:SetText("修改")
            self.removeButton:SetText("隐藏")
            self.clearButton:SetText("恢复隐藏")
            self.status:SetText("点击材料名称，在拍卖行搜索")
        else
            self.input.spec.placeholder = "临时材料名称"
            self.addButton:SetText("添加")
            self.editButton:SetText("修改")
            self.removeButton:SetText("删除")
            self.clearButton:SetText("清空")
        end
    end

    local function RelayoutAfterTabChromeChange(self)
        -- 中文维护注释（2026-09-14，Auction Sidecar tab layout authority）：Daily 页签会把 searchRow
        -- 从布局树中 Collapsed；切回 Favorites/Temp 时又恢复 Visible。RSUI 的 SetVisibility 只负责标记
        -- Measure/Layout dirty，并不会主动驱动 FloatingSurface 立即重新 Arrange。若这里仅 Refresh 数据，
        -- searchRow 会恢复到折叠前的旧 Native 坐标，而 actionRow 仍停在 Daily 收缩后的坐标，两行会重叠。
        -- 因此页签 Chrome 改变布局参与关系后，只通过 FloatingSurface 的统一 ApplyLayout 重新布局一次。
        -- Authority/数据流边界：不修改收藏、任务、临时清单、AuctionQuery 或 Store；这里只消费 Presentation
        -- 的 dirty layout。风险：禁止改成 Tick/循环 Layout，必须保持“用户页签切换时一次”的事件驱动成本。
        if self.visible ~= true then return true end
        local ok, layoutErr = self.surface:ApplyLayout(false)
        if ok ~= true then return false, layoutErr or "拍卖助手页签布局刷新失败" end
        return true
    end

    function instance:SetTab(tab)
        tab = tostring(tab or "")
        if tab ~= "favorites" and tab ~= "daily" and tab ~= "temp" then return false, "未知拍卖助手选项卡" end
        if tab == self.activeTab then
            if tab == "daily" then
                local ok, err = self:AcquireDailyConsumer(); if ok ~= true then return false, err end
            end
            self:UpdateTabChrome()
            local layoutOk, layoutErr = RelayoutAfterTabChromeChange(self)
            if layoutOk ~= true then return false, layoutErr end
            return self:Refresh()
        end
        if tab == "daily" then
            local ok, acquireErr = self:AcquireDailyConsumer(); if ok ~= true then self.status:SetText("今日任务不可用：" .. tostring(acquireErr or "未执行")); return false, acquireErr end
        elseif self.activeTab == "daily" then
            local released, releaseErr = self:ReleaseDailyConsumer("tab_leave")
            if released ~= true then return false, releaseErr end
        end
        self.activeTab = tab
        self.selectedIndex, self.selectedKey, self.selectedRow, self.clearArmedTab = nil, nil, nil, nil
        if type(self.table.ClearSelection) == "function" then self.table:ClearSelection() end
        self:UpdateTabChrome()
        local layoutOk, layoutErr = RelayoutAfterTabChromeChange(self)
        if layoutOk ~= true then return false, layoutErr end
        return self:Refresh()
    end

    instance.tabButtons.favorites.onClick = function() return instance:SetTab("favorites") end
    instance.tabButtons.daily.onClick = function() return instance:SetTab("daily") end
    instance.tabButtons.temp.onClick = function() return instance:SetTab("temp") end

    instance.searchButton.onClick = function() return SearchKeyword(Keyword()) end
    instance.addButton.onClick = function()
        instance.clearArmedTab = nil
        if instance.activeTab == "favorites" then
            local ok, addErr = Feature:AddFavorite(Keyword())
            instance.status:SetText(ok == true and "已加入收藏" or ("收藏失败：" .. tostring(addErr or "未执行")))
            if ok == true then Feature:Refresh("auction_sidecar_add") end
            instance:Refresh(); return ok, addErr
        end
        if instance.activeTab == "temp" then
            local service = SessionService()
            if type(service) ~= "table" or type(service.GetSnapshot) ~= "function" or type(service.AddTradeGroup) ~= "function" or type(service.AddMaterial) ~= "function" then return false, "临时清单服务不可用" end
            local name, qty = Keyword(), Quantity()
            if name == "" then instance.status:SetText("请输入临时材料名称"); return false, "临时材料名称为空" end
            if qty == nil then instance.status:SetText("数量必须大于 0"); return false, "临时材料数量无效" end
            local groupId
            for _, group in ipairs((service:GetSnapshot() or {}).groups or {}) do
                if tostring(group.source or "") == "manual" and tostring(group.sourceKey or "") == "sidecar_manual" then groupId = tonumber(group.id); break end
            end
            if groupId == nil then
                local created, idOrErr = service:AddTradeGroup({ source = "manual", sourceKey = "sidecar_manual", productName = "手工临时材料", materials = {} })
                if created ~= true then instance.status:SetText("临时组创建失败：" .. tostring(idOrErr or "未执行")); return false, idOrErr end
                groupId = tonumber(idOrErr)
            end
            local ok, addErr = service:AddMaterial(groupId, { name = name, count = qty, searchable = true })
            instance.status:SetText(ok == true and ("已加入临时清单：" .. name .. " ×" .. tostring(qty)) or ("临时添加失败：" .. tostring(addErr or "未执行")))
            instance:Refresh(); return ok, addErr
        end
        return false, "今日任务材料由任务事实自动生成"
    end

    local function MoveSelected(direction)
        local row = SelectedRow(); if type(row) ~= "table" then instance.status:SetText("请先选择一条数据"); return false end
        local ok, moveErr
        if row.kind == "favorite" then ok, moveErr = Feature.Commands:MoveFavorite(row.favoriteKeyword, direction)
        elseif row.kind == "daily_material" then
            local service = DailyService(); if type(service) ~= "table" or type(service.MoveMaterial) ~= "function" then return false, "今日任务材料服务不可用" end
            ok, moveErr = service:MoveMaterial(row.questId, row.recipe, row.materialKey, direction)
        elseif row.kind == "temp_group" then
            local service = SessionService(); if type(service) ~= "table" or type(service.MoveGroup) ~= "function" then return false, "临时清单服务不可用" end
            ok, moveErr = service:MoveGroup(row.groupId, direction)
        elseif row.kind == "temp_material" then
            local service = SessionService(); if type(service) ~= "table" or type(service.MoveMaterial) ~= "function" then return false, "临时清单服务不可用" end
            ok, moveErr = service:MoveMaterial(row.groupId, row.materialKey, direction)
        else return false, "当前行不可移动" end
        instance.status:SetText(ok == true and "顺序已调整" or ("移动失败：" .. tostring(moveErr or "未执行")))
        instance:Refresh(); return ok, moveErr
    end
    instance.upButton.onClick = function() return MoveSelected(-1) end
    instance.downButton.onClick = function() return MoveSelected(1) end

    instance.editButton.onClick = function()
        local row = SelectedRow(); if type(row) ~= "table" then instance.status:SetText("请先选择要修改的数据"); return false end
        local ok, editErr
        if row.kind == "favorite" then
            ok, editErr = Feature.Commands:RenameFavorite(row.favoriteKeyword, Keyword())
        elseif row.kind == "temp_group" then
            local service = SessionService(); if type(service) ~= "table" or type(service.RenameGroup) ~= "function" then return false, "临时清单服务不可用" end
            ok, editErr = service:RenameGroup(row.groupId, Keyword())
        elseif row.kind == "temp_material" then
            local service = SessionService(); if type(service) ~= "table" or type(service.UpdateMaterial) ~= "function" then return false, "临时清单服务不可用" end
            local qty = Quantity(); if qty == nil then return false, "临时材料数量无效" end
            local name = Keyword(); if name == "" then name = tostring(row.searchKeyword or "材料") end
            ok, editErr = service:UpdateMaterial(row.groupId, row.materialKey, { name = name, count = qty })
        else return false, "任务材料自动生成；可隐藏材料或选择制作货物" end
        instance.status:SetText(ok == true and "修改已保存" or ("修改失败：" .. tostring(editErr or "未执行")))
        if ok == true and row.kind == "favorite" then Feature:Refresh("auction_sidecar_rename") end
        instance:Refresh(); return ok, editErr
    end

    instance.removeButton.onClick = function()
        local row = SelectedRow(); if type(row) ~= "table" then instance.status:SetText("请先选择要删除的数据"); return false end
        local ok, removeErr
        if row.kind == "favorite" then ok, removeErr = Feature.Commands:RemoveFavoriteByKeyword(row.favoriteKeyword)
        elseif row.kind == "daily_material" then
            local service = DailyService(); if type(service) ~= "table" or type(service.SetMaterialHidden) ~= "function" then return false, "今日任务材料服务不可用" end
            ok, removeErr = service:SetMaterialHidden(row.questId, row.recipe, row.materialKey, true)
        elseif row.kind == "temp_group" then
            local service = SessionService(); if type(service) ~= "table" or type(service.RemoveGroup) ~= "function" then return false, "临时清单服务不可用" end
            ok, removeErr = service:RemoveGroup(row.groupId)
        elseif row.kind == "temp_material" then
            local service = SessionService(); if type(service) ~= "table" or type(service.RemoveMaterial) ~= "function" then return false, "临时清单服务不可用" end
            ok, removeErr = service:RemoveMaterial(row.groupId, row.materialKey)
        else return false, "当前行不可删除" end
        instance.status:SetText(ok == true and (row.kind == "daily_material" and "该任务材料已隐藏" or "已删除") or ("删除失败：" .. tostring(removeErr or "未执行")))
        if ok == true and row.kind == "favorite" then Feature:Refresh("auction_sidecar_remove") end
        if ok == true then instance.selectedIndex, instance.selectedKey, instance.selectedRow = nil, nil, nil end
        instance:Refresh(); return ok, removeErr
    end

    instance.clearButton.onClick = function()
        if instance.activeTab == "daily" then
            local service = DailyService(); if type(service) ~= "table" or type(service.RestoreHidden) ~= "function" then return false, "今日任务材料服务不可用" end
            local snapshot = service:GetSnapshot() or {}; local ok, err = true, nil
            for _, task in ipairs(snapshot.tasks or {}) do local oneOk, oneErr = service:RestoreHidden(task.questId); if oneOk ~= true then ok, err = false, oneErr; break end end
            instance.status:SetText(ok == true and "已恢复今日任务中隐藏的材料" or ("恢复失败：" .. tostring(err or "未执行")))
            instance:Refresh(); return ok, err
        end
        if instance.clearArmedTab ~= instance.activeTab then
            instance.clearArmedTab = instance.activeTab
            instance.status:SetText("再点一次“清空”确认；此操作只影响当前选项卡")
            return true
        end
        instance.clearArmedTab = nil
        local ok, clearErr
        if instance.activeTab == "favorites" then ok, clearErr = Feature.Commands:ClearFavorites(); if ok == true then Feature:Refresh("auction_sidecar_clear") end
        else
            local service = SessionService(); if type(service) ~= "table" or type(service.Clear) ~= "function" then return false, "临时清单服务不可用" end
            ok, clearErr = service:Clear("auction_sidecar_clear")
        end
        instance.status:SetText(ok == true and "当前选项卡已清空" or ("清空失败：" .. tostring(clearErr or "未执行")))
        instance.selectedIndex, instance.selectedKey, instance.selectedRow = nil, nil, nil
        instance:Refresh(); return ok, clearErr
    end

    function instance:ApplyAnchor(snapshot)
        if type(snapshot) == "table" then Controller.snapshot = snapshot end
        -- 原生观察只控制显示；首次默认位置及用户保存的位置均不被后续窗口移动覆盖。
        if self.windowController and self.windowController:IsInteracting()==true then return true end
        return self.surface:ApplyLayout(false)
    end

    function instance:Refresh()
        local rows, projection
        if self.activeTab == "favorites" then rows, projection = FavoriteRows()
        elseif self.activeTab == "daily" then rows, projection = DailyRows()
        else rows, projection = TempRows() end
        self.currentRows = rows
        local revision = type(projection) == "table" and tonumber(projection.revision) or 0
        self.table:SetItems(rows, "auction_sidecar:" .. self.activeTab .. ":" .. tostring(revision or 0))
        if #rows == 0 then
            local title, detail = "暂无数据", ""
            if self.activeTab == "favorites" then title, detail = "暂无收藏", "输入物品名称后点击“添加”。"
            elseif self.activeTab == "daily" then
                if (tonumber(projection.pendingTitleCount) or 0) > 0 then
                    title, detail = "任务标题尚未就绪", tostring(projection.pendingTitleCount) .. " 个活动任务标题等待游戏数据更新；不会猜测做货材料。"
                elseif projection.status == "unavailable" then
                    title, detail = "任务数据暂不可用", tostring(projection.error or "请查看拍卖助手诊断。")
                else title, detail = "暂无今日制作任务材料", "接取地区制作任务后，这里会列出所需材料；点击材料名称即可搜索。" end
            else title, detail = "临时清单为空", "可从跑商详情加入材料，或在上方手工添加。" end
            self.table:SetViewState("empty", { title = title, detail = detail })
        else self.table:SetViewState("ready") end

        self.selectedRow, self.selectedIndex = nil, nil
        if self.selectedKey ~= nil then
            for index, row in ipairs(rows) do if tostring(row.key or "") == tostring(self.selectedKey) then self.selectedRow, self.selectedIndex = row, index; break end end
            if self.selectedRow == nil then self.selectedKey = nil end
        end
        UpdateActionButtons()
        local label = self.activeTab == "favorites" and "收藏" or (self.activeTab == "daily" and "今日任务" or "临时")
        local footer = label .. " · " .. tostring(#rows) .. " 行"
        if self.activeTab == "daily" then
            footer = label .. " · " .. tostring(#(projection.tasks or {})) .. " 项任务"
            local materialCount = 0
            for _, row in ipairs(rows) do if row.kind == "daily_material" then materialCount = materialCount + 1 end end
            footer = footer .. " · " .. tostring(materialCount) .. " 项材料"
        end
        self.surface:SetStatus(footer, "muted")
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal(Feature.UpdateTopic, self, function() if instance.visible == true and instance.activeTab == "favorites" then instance:Refresh() end end)
            local daily = DailyService(); if type(daily) == "table" and type(daily.Topic) == "string" then S.Events:SubscribeInternal(daily.Topic, self, function() if instance.visible == true and instance.activeTab == "daily" then instance:Refresh() end end) end
            local session = SessionService(); if type(session) == "table" and type(session.Topic) == "string" then S.Events:SubscribeInternal(session.Topic, self, function() if instance.visible == true and instance.activeTab == "temp" then instance:Refresh() end end) end
        end
        self.subscribed = true; return true
    end

    function instance:Unsubscribe()
        if self.subscribed ~= true then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false; return true
    end

    function instance:Show(context)
        context = type(context) == "table" and context or {}
        if type(context.snapshot) == "table" then Controller.snapshot = context.snapshot end
        self:ApplyAnchor(Controller.snapshot)
        if self.visible == true then
            if self.activeTab == "daily" then self:AcquireDailyConsumer() end
            self:Refresh(); return self.surface:Show(true)
        end
        self:Subscribe()
        local acquired, acquireErr = Feature:AcquireConsumer("widget:auction_sidecar")
        if acquired ~= true then self:Unsubscribe(); return false, acquireErr or "拍卖助手 Consumer 获取失败" end
        self.acquired = true
        if self.activeTab == "daily" then
            local dailyOk, dailyErr = self:AcquireDailyConsumer()
            if dailyOk ~= true then Feature:ReleaseConsumer("widget:auction_sidecar"); self.acquired = false; self:Unsubscribe(); return false, dailyErr end
        end
        self:UpdateTabChrome(); self:Refresh()
        local shown, showErr = self.surface:Show(true)
        if shown ~= true then
            self:ReleaseDailyConsumer("show_failed")
            Feature:ReleaseConsumer("widget:auction_sidecar"); self.acquired = false; self:Unsubscribe()
            return false, showErr or "拍卖助手侧窗显示失败"
        end
        self.visible = true; return true
    end

    function instance:Hide()
        local hidden, hideErr = self.surface:Show(false); if hidden ~= true then return false, hideErr end
        self:ReleaseDailyConsumer("hide")
        if self.acquired == true and Feature:HasConsumer("widget:auction_sidecar") then Feature:ReleaseConsumer("widget:auction_sidecar") end
        self.acquired = false; self.visible = false; self:Unsubscribe(); return true
    end

    function instance:OnWindowClosed()
        self:ReleaseDailyConsumer("window_closed")
        if self.acquired == true and Feature:HasConsumer("widget:auction_sidecar") then Feature:ReleaseConsumer("widget:auction_sidecar") end
        self.acquired = false; self.visible = false; self:Unsubscribe(); return true
    end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end

    instance:UpdateTabChrome()
    UpdateActionButtons()
    return instance
end

local registered, registerErr = Host:Register(WIDGET_ID, {
    featureId = "tools_auction",
    create = CreateSidecar,
    ensurePreferences = function() return Feature:Initialize() end,
    lockable = false, minimizable = false, resettable = false,
    opacityAdjustable = false, backgroundOpacityAdjustable = false, textOpacityAdjustable = false,
})
if registered ~= true then error(registerErr) end
-- 中文维护注释（2026-09-25，feature-profile-lifecycle-1）：拍卖 Sidecar 虽注册在 WidgetHost，历史上
-- 没有绑定 Feature 生命周期。功能方案 Disable 会清掉 tools_auction Demand，但可见 Sidecar 仍保存
-- acquired=true；再次 Enable 后就可能不重新 Acquire。这里由 WidgetHost 在生命周期边沿统一 Hide/Show，
-- preference 只组合“原生拍卖行仍可见 + 用户悬浮助手偏好”，不写 Store、不轮询 Native。
local lifecycleBound, lifecycleErr = Host:BindFeatureLifecycle(WIDGET_ID, {
    featureId = "tools_auction",
    enabled = function() return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("tools_auction") == true end,
    preference = function() return Controller.nativeVisible == true and SidecarPreferenceEnabled() == true end,
})
if lifecycleBound ~= true then error(lifecycleErr or "auction sidecar lifecycle bind failed") end

local function OnSurface(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local before = Controller:GetControlState()
    local wasVisible = Controller.nativeVisible == true
    Controller.nativeVisible = snapshot.status == "ready" and snapshot.visible == true
    Controller.snapshot = snapshot
    -- 中文维护注释（2026-09-15，Sidecar enable fence）：AuctionSurface 事件只提供原生窗口事实，
    -- 不能覆盖用户的永久“悬浮助手关闭”偏好。偏好为 false 时，无论收到打开/几何刷新/陈旧事件都
    -- fail-closed：立即隐藏已存在 Widget、清理本次会话 dismissed，并禁止自动重建。真正的观察任务
    -- 由 Feature.SetSidecarEnabled(false) 同步 Stop，因此这里既是竞态保险，也是生命周期最后一道门。
    if SidecarPreferenceEnabled() ~= true then
        Controller.dismissed = false
        if Host:IsVisible(WIDGET_ID) == true then Host:SetVisible(WIDGET_ID, false, { persist = false, source = "auction_sidecar_preference_disabled" }) end
        local disabledAfter = Controller:GetControlState()
        if before.nativeVisible ~= disabledAfter.nativeVisible or before.visible ~= disabledAfter.visible
            or before.dismissed ~= disabledAfter.dismissed or before.enabled ~= disabledAfter.enabled then
            Controller:PublishControlState("preference_disabled")
        end
        return true
    end
    if Controller.nativeVisible ~= true then
        Controller.dismissed = false
        if Host:IsVisible(WIDGET_ID) == true then Host:SetVisible(WIDGET_ID, false, { persist = false, source = "auction_native_close" }) end
        local after = Controller:GetControlState()
        if before.nativeVisible ~= after.nativeVisible or before.visible ~= after.visible or before.dismissed ~= after.dismissed or before.enabled ~= after.enabled then
            Controller:PublishControlState("native_close")
        end
        return true
    end
    if wasVisible ~= true then Controller.dismissed = false end
    if Controller.dismissed == true then return true end
    if Host:IsVisible(WIDGET_ID) ~= true then
        local shown, showErr = Host:SetVisible(WIDGET_ID, true, { persist = false, source = "auction_native_open", snapshot = snapshot })
        if shown ~= true then
            Controller:PublishControlState("native_open_show_failed")
            return false, showErr or "拍卖助手自动显示失败"
        end
    end
    local instance = Host:GetInstance(WIDGET_ID)
    local anchored, anchorErr = true, nil
    if type(instance) == "table" and type(instance.ApplyAnchor) == "function" then anchored, anchorErr = instance:ApplyAnchor(snapshot) end
    local after = Controller:GetControlState()
    if before.nativeVisible ~= after.nativeVisible or before.visible ~= after.visible or before.dismissed ~= after.dismissed or before.enabled ~= after.enabled then
        Controller:PublishControlState(wasVisible ~= true and "native_open" or "visibility_sync")
    end
    if anchored ~= true then return false, anchorErr end
    return true
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(SurfaceService.topic or "v3.auction_surface.updated", Controller, function(_, snapshot)
        return OnSurface(snapshot)
    end)
end
OnSurface(SurfaceService:GetSnapshot())
