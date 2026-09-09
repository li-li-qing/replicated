#!/usr/bin/env python3
"""`.18.191` detached Popup 坐标 Authority 回归 Harness：验证 Native-relative Trigger Anchor、屏幕修正与可复制诊断证据。

The RU client has exposed effective widget geometry in both already-logical and
UI-scaled units. Detached UIParent popups must therefore normalize their anchor
through one shared Authority; a second uiScale/host-origin transform produces a
drift that grows with trigger X/Y and only appears on some resolutions/UI sizes.

This harness fences both architecture and pure placement math. It intentionally
does not exercise feature-domain code or add a runtime poller.
"""
from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile

from rs_lua_runner import RUNNER

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = ROOT / "core/rs_layout.lua"
POSITIONING = ROOT / "ui/framework/rs_ui_popup_positioning.lua"
CONTROLS = ROOT / "ui/framework/rs_ui_controls.lua"
INTERACTIONS = ROOT / "ui/framework/rs_ui_interactions.lua"
BAG = ROOT / "presentation/v3/widgets/rs_v3_bag_quick_overlay.lua"
TOC = ROOT / "toc.g"
DIAGNOSTICS = ROOT / "core/rs_diagnostics.lua"  # 中文维护注释：专项报告属于 .18.191 发布契约，Harness 必须直接检查 Diagnostics Authority。
DIAGNOSTIC_PAGE = ROOT / "presentation/v3/pages/rs_v3_foundation_pages.lua"  # 中文维护注释：用户曾因没有可见按钮无法复制 Popup 证据，因此 Harness 同时锁定诊断页入口。


def source_checks() -> int:
    layout = LAYOUT.read_text(encoding="utf-8-sig", errors="replace")
    positioning = POSITIONING.read_text(encoding="utf-8-sig", errors="replace")
    controls = CONTROLS.read_text(encoding="utf-8-sig", errors="replace")
    interactions = INTERACTIONS.read_text(encoding="utf-8-sig", errors="replace")
    bag = BAG.read_text(encoding="utf-8-sig", errors="replace")
    toc = TOC.read_text(encoding="utf-8-sig", errors="replace")
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8-sig", errors="replace")  # 中文维护注释：读取专项报告源用于静态 fence，不执行任何运行时 Native 扫描。
    diagnostic_page = DIAGNOSTIC_PAGE.read_text(encoding="utf-8-sig", errors="replace")  # 中文维护注释：读取诊断页面源，确保“RSUI Popup定位”按钮不会在后续 UI 重排中被误删。
    passed: list[str] = []

    def check(name: str, ok: bool) -> None:
        if not ok:
            raise AssertionError(name)
        passed.append(name)

    check("layout_viewport_rect_contract", "ViewportLogicalRectContractVersion = 1" in layout)
    check("layout_effective_calibration_contract", "EffectiveGeometryCalibrationContractVersion = 1" in layout)  # 中文维护注释：外部原生 Trigger 仍需要 Effective Geometry 校准契约。
    check("layout_suite_anchor_contract", "SuiteOwnedViewportAnchorContractVersion = 1" in layout)  # 中文维护注释：Suite-owned Trigger 必须具备完整 Diff cache 父链契约。
    check("layout_resolver", "function L:ResolveViewportLogicalRect(widget)" in layout)  # 中文维护注释：保留外部原生控件的 viewport logical 解析入口。
    check("layout_suite_anchor_resolver", "function L:ResolveSuiteOwnedViewportLogicalRect(widget)" in layout)  # 中文维护注释：验证 .18.190 cache-first Suite anchor 入口存在。
    check("layout_calibrator", "function L:ResolveEffectiveGeometryScale(widget, rawWidth, rawHeight, context)" in layout)
    check("positioning_authority", "PopupPositioningContractVersion = 3" in positioning)  # 中文维护注释：PopupPositioning v3 才代表 Suite-owned 最终 position 已从绝对坐标重建切到 Native-relative Trigger Anchor。
    check("positioning_suite_anchor_authority", "PopupSuiteAnchorAuthorityContractVersion = 1" in positioning)  # 中文维护注释：保留 .18.190 cache 父链契约供外部/诊断用途，避免历史能力被误删。
    check("positioning_native_relative_authority", "PopupNativeRelativeAnchorContractVersion = 1" in positioning and "function P:ApplyNativeRelativePopup" in positioning)  # 中文维护注释：锁定 .18.191 真正的最终 Anchor Authority，而不是只提升版本号。
    check("positioning_native_screen_correction", "function P:CorrectNativePopupToScreen" in positioning and "CorrectOffsetByScreen" in positioning)  # 中文维护注释：低分辨率边缘修正必须复用 RU 已验证 UIBounds 方法，禁止重新散落 magic offset。
    check("suite_owned_cache_first", "ResolveSuiteOwnedViewportLogicalRect(native)" in positioning and "popup_suite_anchor_chain_unavailable" in positioning)  # 中文维护注释：防止未来回归成 cache 断链后继续用 Effective API 猜位置。
    check("positioning_coordinate_space", 'coordinateSpace = "viewport-logical-v1"' in positioning)
    check("dropdown_resolver", "function P:ResolveDropdown(target, options)" in positioning)
    check("anchored_resolver", "function P:ResolveAnchored(anchor, popupWidth, popupHeight, options)" in positioning)
    check("point_resolver", "function P:ResolvePoint(x, y, popupWidth, popupHeight, options)" in positioning)
    check("no_component_local_screen_guess", "GetAbsoluteRect(" not in positioning)
    check("dropdown_consumer", "PopupCoordinateConsumerContractVersion = 2" in controls and "positioning:ApplyNativeRelativePopup(self.popup, self" in controls and "CorrectNativePopupToScreen(self.popup" in controls)  # 中文维护注释：Dropdown 必须相对 Trigger 直接锚定并在 Show 后做 Native 边缘修正。
    check("colorfield_consumer", "positioning:ApplyNativeRelativePopup(self.popup, self" in controls and "colorfield_native_relative_anchor_failed" in controls)  # 中文维护注释：ColorField 与 Dropdown 必须共享同一 Native-relative 底层，禁止再次形成第二套绝对算法。
    check("interaction_consumers", "InteractionPopupCoordinateConsumerContractVersion = 2" in interactions and interactions.count("ApplyNativeRelativePopup") >= 2 and "popup-point-v1" in interactions)  # 中文维护注释：目标型 Tooltip/ContextMenu 使用 relative lane，同时保留显式 point lane 的独立 Authority。
    check("legacy_absolute_lane_not_consumed", 'rsUiCoordinateLane = "popup-anchor-v1"' not in controls and 'rsUiCoordinateLane = "popup-anchor-v1"' not in interactions)  # 中文维护注释：Consumer 源码不得重新提交 .18.189/.18.190 的旧 absolute popup lane。
    check("popup_diagnostics_report", "function D:BuildPopupPositioningReport()" in diagnostics and "PopupBefore" in diagnostics and "PopupAfter" in diagnostics)  # 中文维护注释：专项报告必须能输出修正前后 Native 原始几何，下一轮不再只靠截图。
    check("popup_diagnostics_button", 'id = "v3_diag_popup_output"' in diagnostic_page and 'text = "RSUI Popup定位"' in diagnostic_page and "BuildPopupPositioningReport" in diagnostic_page)  # 中文维护注释：锁定用户可见复制入口，防止再次出现“内部有日志但页面没有按钮”。
    check("detached_controls_no_legacy_rect", "GetLogicalRect(" not in controls and "GetEffectiveOffset(" not in controls)
    check("detached_interactions_no_legacy_rect", "GetLogicalRect(" not in interactions and "GetEffectiveOffset(" not in interactions)
    check("bag_separate_external_lane", "ExternalNativeWindowGeometryContractVersion=1" in bag and 'rsUiCoordinateLane="external-native-window-v1"' in bag)
    load_order = [line.strip() for line in toc.splitlines() if line.strip() and not line.strip().startswith("#")]
    check("positioning_loaded_before_controls", load_order.index("ui/framework/rs_ui_popup_positioning.lua") < load_order.index("ui/framework/rs_ui_controls.lua"))
    check("positioning_loaded_before_interactions", load_order.index("ui/framework/rs_ui_popup_positioning.lua") < load_order.index("ui/framework/rs_ui_interactions.lua"))
    check("viewport_height_cap", "maxViewportHeightRatio" in positioning and "0.60" in positioning)
    check("dropdown_flip_diagnostic", "meta.flipped = useAbove == true" in positioning)
    print(f"POPUP_COORDINATE_SOURCE PASS {len(passed)}/{len(passed)}")
    return len(passed)


LUA = r'''
local metricScreenW, metricScreenH = 1280, 768
local metricLogicalW, metricLogicalH = 1280, 768
local metricUiScale = 1
local effectiveUnitScale = 1
local rootLogicalX, rootLogicalY = 0, 0

ReplicatedSuite = {
  BootError = nil,
  Constants = {
    Breakpoint = { COMPACT=1150, STANDARD=1700, WIDE=2300, NARROW_ONE_COLUMN=760 },
    SafeArea=12, SnapDistance=16,
    ResolutionSafety={ edge=12, spawnX=300, spawnY=100, spawnGapX=8, spawnGapY=8, maxColumns=4 },
    MinAddonScale=0.80, MaxAddonScale=1.20,
    Layout={ margin=10, titleHeight=40, tabHeight=28, cardGap=8, rowHeight=30, compactRowHeight=24 },
    MainWindow={ threeColumnWidth=1180, threeColumnHeight=900, twoColumnWidth=900, twoColumnHeight=760, oneColumnWidth=620, oneColumnHeight=700, minWidth=560, minHeight=600 },
  },
  AppState={ settings={ addonScale=1 } },
  Api={}, UI={ NativeStateCache=setmetatable({}, {__mode='k'}) }, RSUI={},
}
UIParent = {}
function UIParent:GetEffectiveOffset() return rootLogicalX * effectiveUnitScale, rootLogicalY * effectiveUnitScale end
function UIParent:GetEffectiveExtent() return metricLogicalW * effectiveUnitScale, metricLogicalH * effectiveUnitScale end
function ReplicatedSuite.Api:GetUiMetrics()
  return metricScreenW, metricScreenH, metricUiScale, metricLogicalW, metricLogicalH
end
function ReplicatedSuite.RSUI:IsComponent(value) return type(value)=='table' and value.__isComponent == true end
function ReplicatedSuite.RSUI:GetAbsoluteRect(component) return component.__fallbackRect end
function ReplicatedSuite.UI:EnsureExtent(widget,w,h,owner) widget.__w,widget.__h=w,h; return true,true,nil end -- 中文维护注释：模拟 Diff Geometry 事务成功，并把 Popup 尺寸写入 mock Native 供诊断采样验证。
function ReplicatedSuite.UI:InvalidateNativeState(widget,field) return widget~=nil end -- 中文维护注释：模拟每次 Open 前失效旧 Anchor cache；Harness 只关心调用不会阻断相对重锚。
function ReplicatedSuite.UI:EnsureAnchor(widget,parent,x,y,owner) widget.__anchorParent,widget.__anchorX,widget.__anchorY=parent,x,y; widget.__x,widget.__y=x,y; return true,true,nil end -- 中文维护注释：模拟 Native AddAnchor 相对 reference 的提交结果，显式记录 parent identity 与 Trigger-local offset。

assert(loadfile([[__LAYOUT__]]))()
assert(loadfile([[__POSITIONING__]]))()
local L = ReplicatedSuite.Layout
local P = ReplicatedSuite.RSUI.PopupPositioning

local pass, fail = 0, 0
local function Check(name, ok, detail)
  if ok then pass=pass+1 else fail=fail+1; print('FAIL | '..name..' | '..tostring(detail or '')) end
end
local function Near(a,b) return math.abs((tonumber(a) or 0)-(tonumber(b) or 0)) < 0.02 end
local function SetMetrics(w,h,uiScale,unitScale,screenMode)
  metricLogicalW,metricLogicalH=w,h
  metricUiScale=uiScale or 1
  effectiveUnitScale=unitScale or 1
  if screenMode=='scaled' then metricScreenW,metricScreenH=w*metricUiScale,h*metricUiScale
  else metricScreenW,metricScreenH=w,h end
  L:Invalidate()
end
local function NativeWidget(x,y,w,h)
  local widget = { __x=x, __y=y, __w=w, __h=h }
  function widget:GetOffset() return self.__x, self.__y end -- 中文维护注释：提供 RU UIBounds:GetOffset 原始值，使专项报告测试可同时观察 local offset 与 effective offset。
  function widget:GetExtent() return self.__w, self.__h end -- 中文维护注释：提供 RU UIBounds:GetExtent 原始尺寸，验证 PopupBefore/After 报告字段完整。
  function widget:GetEffectiveOffset()
    return (rootLogicalX + self.__x) * effectiveUnitScale, (rootLogicalY + self.__y) * effectiveUnitScale
  end
  function widget:GetEffectiveExtent() return self.__w * effectiveUnitScale, self.__h * effectiveUnitScale end
  function widget:GetWidth() return self.__w end
  function widget:GetHeight() return self.__h end
  ReplicatedSuite.UI.NativeStateCache[widget] = { width=w, height=h, anchorParent=UIParent, anchorX=x, anchorY=y } -- 中文维护注释：模拟真实 UI:SetAnchor 写入的完整 Suite-owned 父链，Popup v2 必须直接使用该逻辑坐标。
  return widget -- 中文维护注释：返回构造完成的 Native Widget，供直接 Geometry 与 RSUI Component 两类测试复用。
end
local function Component(widget)
  local c={__isComponent=true, root=widget}
  function c:GetRoot() return self.root end
  return c
end

-- Exact same logical anchor must resolve identically whether RU returns native
-- effective geometry already logical or multiplied by UI scale.
local cases = {
  {1024,768,0.80},{1280,720,0.80},{1280,768,0.85},{1366,768,0.90},
  {1600,900,1.00},{1920,1080,1.00},{2560,1440,1.25},
}
for i,row in ipairs(cases) do
  local w,h,scale=row[1],row[2],row[3]
  rootLogicalX,rootLogicalY=7,13
  local x,y=math.floor(w*0.43),math.floor(h*0.31)
  local target=NativeWidget(x,y,260,26)
  SetMetrics(w,h,scale,1,'logical')
  local lx,ly,lw,lh,lmeta=L:ResolveViewportLogicalRect(target)
  Check('logical_effective_'..i, Near(lx,x) and Near(ly,y) and Near(lw,260) and Near(lh,26) and Near(lmeta.effectiveScale,1), tostring(lx)..','..tostring(ly)..' scale='..tostring(lmeta.effectiveScale))
  SetMetrics(w,h,scale,scale,'scaled')
  local sx,sy,sw,sh,smeta=L:ResolveViewportLogicalRect(target)
  Check('scaled_effective_'..i, Near(sx,x) and Near(sy,y) and Near(sw,260) and Near(sh,26) and Near(smeta.effectiveScale,scale), tostring(sx)..','..tostring(sy)..' scale='..tostring(smeta.effectiveScale)..' source='..tostring(smeta.scaleSource))
end
rootLogicalX,rootLogicalY=0,0

-- Normal dropdown: bottom-start and same X as trigger when space is available.
SetMetrics(1280,768,0.85,0.85,'scaled')
local center=Component(NativeWidget(220,120,620,26))
local result,err,meta=P:ResolveDropdown(center,{id='center',rowHeight=26,itemCount=12,maxVisible=8,popupWidth=620})
Check('dropdown_bottom_anchor', result~=nil and Near(result.x,220) and Near(result.y,148) and meta.placement=='bottom' and meta.flipped==false, err or (tostring(result and result.x)..','..tostring(result and result.y)))
Check('dropdown_integer_rows', result~=nil and meta.visibleRows>=1 and Near(result.height,meta.visibleRows*26), tostring(meta.visibleRows)..'/'..tostring(result and result.height))

-- 中文维护注释：真实 RU .18.189 已证明 GetEffectiveOffset 可能给出“单位看似可校准但绝对位置语义仍错误”的值；Suite-owned Popup 必须完全忽略这个错误 Effective 位置。 
local lyingNative=NativeWidget(260,160,420,26) -- 中文维护注释：Diff cache 中的真实逻辑锚点是 260,160。
function lyingNative:GetEffectiveOffset() return 610,390 end -- 中文维护注释：故意模拟 RU 返回错误/父级语义不一致的 Effective 绝对位置；旧 .18.189 会被带偏。
function lyingNative:GetEffectiveExtent() return 420,26 end -- 中文维护注释：尺寸保持合理，确保测试能抓到“只有位置错、校准仍可能通过”的危险情况。
local lyingComponent=Component(lyingNative) -- 中文维护注释：标记为 Suite-owned Component，强制进入 cache-first Authority。
local lyingResult,lyingErr=P:ResolveDropdown(lyingComponent,{id='lying',rowHeight=26,itemCount=5,maxVisible=5,popupWidth=420}) -- 中文维护注释：执行真实 Dropdown Placement 路径。
Check('suite_cache_ignores_lying_effective', lyingResult~=nil and Near(lyingResult.x,260) and Near(lyingResult.y,188), lyingErr or (tostring(lyingResult and lyingResult.x)..','..tostring(lyingResult and lyingResult.y))) -- 中文维护注释：Popup 必须紧贴真实 Trigger 底部 2px，而不能跟随错误 Effective 坐标漂移。

-- 中文维护注释：Native Primitive Factory 初次创建控件时可能只缓存 legacy `anchorTopLeft`；即使后续布局值未变化也可能不会自动迁移成标量 anchorParent/anchorX/anchorY。
local legacyParent={} -- 中文维护注释：构造一个模拟页面容器的 Native 父节点，用于验证 legacy Prime 状态也能组成完整 UIParent 父链。
ReplicatedSuite.UI.NativeStateCache[legacyParent]={width=700,height=400,anchorTopLeft={parent=UIParent,x=180,y=90}} -- 中文维护注释：父容器仅提供 legacy anchorTopLeft，模拟真实 Primitive Factory 初始 Prime。
local legacyChild={} -- 中文维护注释：构造一个模拟 Dropdown Trigger 的子控件，不提供 Effective Geometry，迫使测试只验证 cache Authority。
ReplicatedSuite.UI.NativeStateCache[legacyChild]={width=300,height=26,anchorTopLeft={parent=legacyParent,x=40,y=30}} -- 中文维护注释：子控件同样仅使用 legacy anchorTopLeft，真实绝对逻辑位置应为 220,120。
local legacyComponent=Component(legacyChild) -- 中文维护注释：标记为 Suite-owned Component，使 Popup v2 必须走完整缓存父链。
local legacyRect,legacyErr=P:ResolveAnchorRect(legacyComponent) -- 中文维护注释：调用统一 Popup Anchor Authority，验证首次打开时无需先发生一次重新布局。
Check('suite_legacy_anchor_chain', legacyRect~=nil and Near(legacyRect.x,220) and Near(legacyRect.y,120) and Near(legacyRect.width,300), legacyErr or tostring(legacyRect and legacyRect.source)) -- 中文维护注释：legacy Prime 父链必须得到正确 UIParent-local 逻辑坐标，防止首次点击 Dropdown 因缓存格式不同而失效。

-- Bottom-edge trigger must flip above instead of drifting off screen.
local bottom=Component(NativeWidget(220,720,620,26))
local up,upErr,upMeta=P:ResolveDropdown(bottom,{id='bottom',rowHeight=26,itemCount=30,maxVisible=16,popupWidth=620})
Check('dropdown_bottom_flip', up~=nil and upMeta.placement=='top' and upMeta.flipped==true and up.bottom<=720-1.9, upErr or (tostring(up and up.y)..'/'..tostring(upMeta and upMeta.placement)))

-- Right-edge popup is clamped inside the safe viewport and never exceeds it.
local right=Component(NativeWidget(1120,180,180,26))
local rr,rrErr,rrMeta=P:ResolveDropdown(right,{id='right',rowHeight=26,itemCount=8,maxVisible=8,popupWidth=420})
local viewport=P:GetViewport()
Check('dropdown_right_clamp', rr~=nil and rr.x>=viewport.x and rr.right<=viewport.right+0.02 and rrMeta.clampedX==true, rrErr or tostring(rr and rr.right)..'/'..tostring(viewport.right))

-- Long lists are bounded to <=60% safe viewport and stay row-aligned.
local long=Component(NativeWidget(300,90,500,26))
local lr,lrErr,lmeta=P:ResolveDropdown(long,{id='long',rowHeight=26,itemCount=200,maxVisible=16,popupWidth=500,maxViewportHeightRatio=0.60})
Check('dropdown_60pct_cap', lr~=nil and lr.height<=P:GetViewport().height*0.60+0.02 and Near(lr.height,lmeta.visibleRows*26), lrErr or tostring(lr and lr.height))

-- Generic anchored popups also flip and clamp, covering ColorField/ContextMenu.
local ar={x=1180,y=730,width=80,height=26,right=1260,bottom=756,coordinateSpace='viewport-logical-v1'}
local generic,gerr,gmeta=P:ResolveAnchored(ar,300,180,{id='generic',preferred='bottom-start',gap=4})
Check('generic_flip_and_clamp', generic~=nil and generic.right<=viewport.right+0.02 and generic.bottom<=viewport.bottom+0.02 and gmeta.placement=='top', gerr or tostring(generic and generic.x)..','..tostring(generic and generic.y))

-- Point popups (cursor tooltip / explicit context-menu point) flip on both axes.
local point,perr,pmeta=P:ResolvePoint(1260,740,240,120,{id='point',gap=8})
Check('point_flip', point~=nil and point.right<=viewport.right+0.02 and point.bottom<=viewport.bottom+0.02 and pmeta.flipped==true, perr or tostring(point and point.x)..','..tostring(point and point.y))

-- If effective geometry is unavailable, only a COMPLETE cached anchor chain to
-- UIParent is accepted. Component-tree local arithmetic alone is not a screen
-- coordinate Authority and must never produce a plausible-but-offset popup.
local deadNative={}
ReplicatedSuite.UI.NativeStateCache[deadNative]={width=333,height=24,anchorParent=UIParent,anchorX=111,anchorY=222}
local fallback=Component(deadNative)
local fr,ferr=P:ResolveAnchorRect(fallback)
Check('complete_native_state_fallback', fr~=nil and fr.source=='suite_native_state_anchor_chain' and fr.x==111 and fr.y==222 and fr.width==333, ferr or tostring(fr and fr.source)) -- 中文维护注释：完整标量缓存父链必须被识别为 suite-native-state Authority。
local orphanNative={}
ReplicatedSuite.UI.NativeStateCache[orphanNative]={width=333,height=24,anchorX=111,anchorY=222}
local orphan=Component(orphanNative)
local orr,oerr=P:ResolveAnchorRect(orphan)
Check('incomplete_fallback_fails_closed', orr==nil and oerr=='popup_suite_anchor_chain_unavailable', tostring(oerr)) -- 中文维护注释：Suite-owned 父链不完整时必须拒绝显示，禁止回退错误 EffectiveOffset。

local triggerRelative=NativeWidget(880,510,300,26) -- 中文维护注释：构造位于屏幕右下区域的 Trigger；其绝对位置故意很大，用于证明最终 Anchor 参数不包含 880/510。
local triggerRelativeComponent=Component(triggerRelative) -- 中文维护注释：按真实 Dropdown 形态包装为 Suite-owned Component，ApplyNativeRelativePopup 应解析到同一 Native 根。
local popupRelative=NativeWidget(0,0,1,1) -- 中文维护注释：构造顶层 transient Popup mock；最终只检查它相对 Trigger 的 AddAnchor reference 与 local offset。
function popupRelative:CorrectOffsetByScreen() self.__corrected=true end -- 中文维护注释：模拟 RU 已允许的屏幕边缘修正 API；返回 nil 也必须被 pcall 视为调用成功。
local relativeOk,relativeErr,relativeMeta=P:ApplyNativeRelativePopup(popupRelative,triggerRelativeComponent,'harness',{id='relative_runtime',width=300,height=156,triggerWidth=300,triggerHeight=26,gap=2,placement='bottom-start'}) -- 中文维护注释：执行 .18.191 真实核心入口，最终参数只能是 Trigger reference + (0,28)，绝不能携带 Trigger 的 880/510 绝对坐标。
Check('native_relative_anchor_reference', relativeOk==true and popupRelative.__anchorParent==triggerRelative and Near(popupRelative.__anchorX,0) and Near(popupRelative.__anchorY,28), relativeErr or tostring(popupRelative.__anchorX)..','..tostring(popupRelative.__anchorY)) -- 中文维护注释：直接锁定 Native AddAnchor reference 语义，防止未来回归 UIParent + absolute X/Y。
Check('native_relative_lane', popupRelative.rsUiCoordinateLane=='popup-native-relative-v1' and popupRelative.rsUiCoordinateSpace=='native-trigger-relative-v1' and relativeMeta.placement=='bottom-start', tostring(popupRelative.rsUiCoordinateLane)) -- 中文维护注释：运行时 lane 必须与诊断/架构声明一致，避免消费者与 Foundation 契约分叉。
local correctionOk,correctionErr=P:CorrectNativePopupToScreen(popupRelative,'relative_runtime') -- 中文维护注释：模拟 Show 后 Native 屏幕修正，验证 nil 返回 ABI 不会被错误当成失败。
Check('native_screen_correction', correctionOk==true and popupRelative.__corrected==true, correctionErr) -- 中文维护注释：CorrectOffsetByScreen 必须真实执行，且只有异常才允许判失败。
local snap=P:GetSnapshot() -- 中文维护注释：读取有界诊断快照，验证用户专项按钮所依赖的 Trigger/Popup 原始证据已记录。
local relativeRow=snap.recent[#snap.recent] -- 中文维护注释：本用例最后写入 relative_runtime，因此最近一条应直接对应刚才的 Native-relative 事务。
Check('native_relative_diagnostic_row', type(relativeRow)=='table' and relativeRow.mode=='native_relative' and relativeRow.relative.y==28 and relativeRow.nativeCorrectionOk==true and type(relativeRow.targetNative)=='table' and type(relativeRow.popupNativeBeforeCorrection)=='table' and type(relativeRow.popupNativeAfterCorrection)=='table', tostring(relativeRow and relativeRow.mode)) -- 中文维护注释：专项报告依赖的三组 Raw Native Geometry 与修正状态必须全部存在。
Check('diagnostic_coordinate_space', snap.coordinateSpace=='viewport-logical-v1' and snap.contractVersion>=3 and #snap.recent<=12 and (snap.metrics.nativeRelativeApplies or 0)>=1, tostring(snap.coordinateSpace)..'/'..tostring(#snap.recent)) -- 中文维护注释：诊断快照升级到 v3，并继续保持 recent 最多 12 条的内存上限。

print('POPUP_COORDINATE_RUNTIME PASS '..pass..'/'..(pass+fail))
os.exit(fail==0 and 0 or 1)
'''.replace("__LAYOUT__", LAYOUT.as_posix()).replace("__POSITIONING__", POSITIONING.as_posix())


def runtime_check() -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        path = Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(path)], capture_output=True, text=True)
    finally:
        path.unlink(missing_ok=True)
    print(proc.stdout, end="")
    if proc.returncode != 0:
        print(proc.stderr, end="")
        raise SystemExit(proc.returncode)


def main() -> None:
    source_checks()
    runtime_check()


if __name__ == "__main__":
    main()
