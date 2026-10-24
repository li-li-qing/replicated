-- 中文维护：此文件位于共享UI源码之后；只装配LCot自己的设置表面，不运行Suite bootstrap/Feature/Runtime或第二份游戏扫描。
local P = LCotPotionSignal
if P.externalSuiteUI then
    ReplicatedSuite = P.externalSuiteUI; P.externalSuiteUI = nil
    function P:GetThresholdUI() return ReplicatedSuite end
    return
end
local S = P.uiLibrary
if not S or S.BootError or not S.RSUI or not S.UIV3 or not S.UIV3.ModalHost then
    P.uiLibraryError = S and S.BootError or "Suite共享UI源码未完整载入，请检查lcotpotion/toc.g及replicatedsuite目录。"
    return
end
local R, UI, host = S.RSUI, S.UI, S.UIV3.ModalHost
local shell = {}; S.UIV3.Shell = shell
function shell:Open()
    if S.Scheduler and not S.Scheduler.running then local ready = S.Scheduler:Start(); if not ready then return false, P.uiLibraryError or "Suite UI调度器无法启动" end end -- 中文维护：使用生产Scheduler处理布局/焦点/hover的一次性任务，不复制时序器或启动任何游戏扫描。
    if not self.window then
        local owner = "v3:lcot_ui_host"
        local window, err = UI:CreatePanel("UIParent", "lcot_ui_host", 64, 64, 700, 430, "card", { owner = owner, transientWindow = true, pickable = true, visible = false })
        if not window then return false, err or P.uiLibraryError or "Suite共享窗口创建失败" end
        self.window, self.owner = window, owner
        local built, _, detail = R:WithBuildScope("lcot_ui_host", function()
            self.content = assert(R:Overlay({ id = "lcot_ui_host_content", parent = window, width = 700, height = 430 }))
            local attached, why = host:Attach(self.content)
            if not attached then return false, why end
            self.content:Layout(0, 0, 700, 430)
            return true
        end)
        if not built then UI:EnsureVisible(window, false, owner); return false, detail end
    end
    return UI:EnsureVisible(self.window, true, self.owner)
end
function host:Layout() if shell.content then shell.content:Layout(0, 0, 700, 430) end end
local pop = host.Pop
function host:Pop(...)
    local closed, err = pop(self, ...)
    if closed and not self:HasModal() and shell.window then UI:EnsureVisible(shell.window, false, shell.owner) end -- 中文维护：真实ModalHost拥有遮罩/栈，最外层Native窗口仅随最后一个本机模态关闭，不遗留透明命中区。
    return closed, err
end
function P:ReleaseThresholdUI()
    if S.Scheduler then S.Scheduler:Stop() end
    if S.UI then S.UI:QuiesceKeyboardInput("lcot_ui_shutdown", true); S.UI:HideAll() end -- 中文维护：仅清理本Addon库实例；不触碰用户正在使用的Suite界面。
end
