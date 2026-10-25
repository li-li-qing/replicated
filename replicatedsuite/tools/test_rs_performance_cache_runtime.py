# Replicated Suite · 性能缓存运行时测试
# 作者：Replicated
# QQ群：1104129461
"""Lua5.1真实函数的操作预算/失效回归；Native替身不代表RU帧率。"""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


def section(path, start, end):
    text = source(path)
    offset = text.index(start)
    return text[offset:text.index(end, offset)]


COPY = """
function Copy(v)
 if type(v)~='table' then return v end
 local r={};for k,x in pairs(v) do r[k]=Copy(x) end;return r
end
"""

OVERLAY_HOST = """
UI={};S={UI=UI};P={running=true,panels={},activePanels={},displayRows={},rosterCount=100,locateUntil=0,owner='test'}
settings={calibration=false,testColors=false,effectMode=1,showRanks=true,rankCount=10}
function Settings() return settings end
function N(v,f) return tonumber(v) or tonumber(f) or 0 end
function AnimatedAlpha(c) return c.a end
SLOTS_PER_PANEL=50;cost={writes=0}
function WidgetUsable() return true end
function GetState(w) w.diff=w.diff or {};return w.diff end
function TryNativeVisible(w) return w.visible,true end
function RecordAttempt() end
function RepairCachedField() end
function RecordCacheRepair() end
function RecordNativeSafetyFailure() error('unexpected native failure') end
function NativeBooleanSetterAccepted(ok,result) return ok and result~=false end
function UI:ReleaseFocusWithin() end
function UI:DisarmInputWithin() end
function UI:SetColor(w,r,g,b,a) w.color={r,g,b,a} end
function UI:SetText(w,t) w.text=t end
function UI:EnsurePickable() return true end
function UI:TryInteractionCall() return true end
function UI:TrySetUILayer() return true end
function node() return {Show=function(self,v) cost.writes=cost.writes+1;self.visible=v end} end
function P:GetOverlaySlot(row) return self.panels[row.panel],row.memberIndex end
for _,id in ipairs({'A','B'}) do
 local p={window=node(),calibrationBg=node(),title=node(),borders={node(),node(),node(),node()},ranks={},calibrationLabels={},slots={}}
 P.panels[id]=p;P.activePanels[id]=true
 for i=1,50 do
  p.ranks[i]=node();p.calibrationLabels[i]=node();p.slots[i]=node()
  P.displayRows[#P.displayRows+1]={panel=id,memberIndex=i,isCandidate=i<=10,rank=i,color={r=1,g=0,b=0,a=0.42}}
 end
end
"""


class PerformanceCacheTests(unittest.TestCase):
    def overlay(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(OVERLAY_HOST)
        lua.execute(section("ui/rs_ui_framework.lua", "function UI:SetVisible(", "-- Transactional visibility facade."))
        lua.execute(section("presentation/v3/widgets/rs_v3_healer_raid_overlay.lua", "function P:RefreshHighlights(", "function P:AnimateTick("))
        return lua

    def test_overlay_unchanged_slots_and_ranks_have_zero_visibility_writes(self):
        lua = self.overlay()
        lua.execute("assert(P:RefreshHighlights());cost.writes=0;for i=1,60 do assert(P:RefreshHighlights()) end;assert(cost.writes==0,'unchanged Show writes: '..cost.writes)")

    def test_overlay_removed_members_calibration_and_locate_keep_final_visibility(self):
        lua = self.overlay()
        lua.execute("""
        assert(P:RefreshHighlights());table.remove(P.displayRows,1);assert(P:RefreshHighlights())
        assert(not P.panels.A.slots[1].visible and not P.panels.A.ranks[1].visible)
        settings.calibration=true;assert(P:RefreshHighlights());assert(P.panels.A.slots[1].visible and not P.panels.A.ranks[2].visible)
        settings.calibration=false;P.selfSlot={id='A',index=1};P.locateUntil=20
        assert(P:RefreshHighlights(10));assert(P.panels.A.slots[1].visible)
        assert(P:RefreshHighlights(30));assert(not P.panels.A.slots[1].visible)
        """)

    def test_input_free_hud_does_not_scan_other_inputs_but_roots_still_disarm(self):
        lua = LuaRuntime()
        lua.execute("""
        UI={};UIParent={};lifecycle={armedInputs={}};checks=0;disarmed=0
        input={rsUiKeyboardInput=true};lifecycle.armedInputs[input]=true
        function IsInputTarget(w) return w.rsUiKeyboardInput==true end
        function PhysicalIdOf() return 'input' end
        function OwnerOf() return 'test' end
        function FocusedInputDescendsFrom(i,w) checks=checks+1;return w.contains==true end
        function UI:DisarmInputWidget() disarmed=disarmed+1;return true,true end
        """)
        lua.execute(section("ui/rs_ui_framework.lua", "function UI:DisarmInputWithin(", "-- 维护：OnLostFocus"))
        lua.execute("""
        for i=1,100 do assert(UI:DisarmInputWithin({rsUiKeyboardInputSubtreeCount=0})) end
        assert(checks==0,'HUD traversed active inputs: '..checks)
        assert(UI:DisarmInputWithin({contains=true,rsUiKeyboardInputSubtreeCount=1}));assert(disarmed==1)
        assert(UI:DisarmInputWithin(UIParent));assert(disarmed==2)
        assert(UI:DisarmInputWithin(input));assert(disarmed==3)
        """)

    def test_healer_presentation_is_detached_with_one_copy(self):
        lua = LuaRuntime()
        lua.execute(COPY + "copies=0;function DeepCopy(v) copies=copies+1;return Copy(v) end;S={Utils={DeepCopy=DeepCopy}};F={State={presentation={raid={panels={A={team=1}}}}}}")
        lua.execute(section("features/combat/healer/rs_healer_store.lua", "function F:GetPresentationSettings(", "local HEAD_PRESENTATION_KEYS"))
        lua.execute(section("features/combat/healer/rs_healer_feature.lua", "function F:GetPresentationProjection(", "function F:GetMemberDetail("))
        lua.execute("local v=F:GetPresentationProjection('raid');assert(copies==1,'copies='..copies);v.panels.A.team=2;assert(F.State.presentation.raid.panels.A.team==1)")

    def test_trade_projection_does_not_copy_discarded_cargo_payloads(self):
        lua = LuaRuntime()
        lua.execute(COPY + """
        copied=0;local copy=Copy
        Copy=function(v) if type(v)=='table' and v.forbidden then error('copied discarded cargo payload') end;copied=copied+1;return copy(v) end
        S={NowMs=function() return 1000 end};Trade={State={},Preferences={}}
        function Number(v) return tonumber(v) end
        for _,n in ipairs({'GetViewMode','GetFavorites','GetFavoriteItems','FavoriteKey','IsFavorite'}) do Trade[n]=function() return nil end end
        function PendingTradeQuoteCount() return 0 end
        function InFlightTradeQuoteCount() return 0 end
        function UnresolvedTradeIdentityCount() return 0 end
        TA={cargo={status='ready',results={forbidden=true},queue={forbidden=true},details={value=4}},rows={}}
        function TA:GetNativeCooldownRemaining() return 0 end
        function TA:GetAutoRefreshState() return {} end
        """)
        lua.execute(section("features/life/trade/rs_trade_feature.lua", "function TA:GetProjection(", "local function NormalizeTradeState("))
        lua.execute("local p=TA:GetProjection();assert(p.cargo.results==nil and p.cargo.queue==nil);p.cargo.details.value=8;assert(TA.cargo.details.value==4)")

    def test_opted_in_lists_skip_same_revision_measure_but_native_retry_and_explicit_refresh_still_work(self):
        text = source("ui/framework/rs_ui_data_views.lua")
        for offset, layout_field in ((text.index("    function c:SetItems("), "scrollOffset"), (text.index("    function c:SetItems(", text.index("    function c:SetItems(")+1), "scrollRowOffset")):
            code = text[offset:text.index("    function c:SetDataSource(", offset)]
            lua = LuaRuntime()
            lua.execute("""
            RSUI={metrics={}};c={internalRevision=0,width=200,height=100,scrollOffset=0,scrollRowOffset=0}
            layouts=0;measures=0;reject=true;nativeWidth=100;function c:GetMaxOffset() return 0 end;function c:GetMaxScrollRow() return 0 end
            function c:_SyncViewState() end
            function c:InvalidateMeasure() measures=measures+1;self.measureDirty=true end
            function c:Layout() layouts=layouts+1;self.measureDirty=false;self.layoutDirty=false;if not reject then nativeWidth=self.width end end
            """)
            lua.execute(code)
            lua.execute("""
            c:SetItems({{name='a'}},1,true);reject=false;for i=1,10 do c:SetItems({{name='a'}},1,true) end
            assert(measures==1,'same revision measures='..measures)
            assert(nativeWidth==200 and layouts==11,'same revision swallowed Native geometry retry')
            c:SetItems({{name='changed'}},1);assert(measures==2,'explicit SetItems skipped')
            c.layoutDirty=true;c:SetItems({{name='a'}},1,true);assert(measures==3,'dirty geometry skipped')
            c:SetItems({},1,true);assert(measures==4,'changed item count skipped')
            c:SetItems({},2,true);assert(measures==5,'new revision skipped')
            """)

    def test_activity_compiles_static_text_once_and_reset_rebuilds(self):
        lua = LuaRuntime()
        lua.execute("ReplicatedSuite={Generation=1,Data={RuEvents={{name='event',days={1,2,3,4,5,6,7},hour=2,minute=0,duration=10}}}}")
        lua.execute(source("features/life/activities/rs_activity_authority.lua"))
        lua.execute("""
        A=ReplicatedSuite.Features.Activities.Authority;now=3000
        function A:GetWeekSeconds() return now end;function A:GetDateSerial() return 739900 end
        local f=string.format;formats=0;string.format=function(...) formats=formats+1;return f(...) end
        local first=A:BuildStaticRows()[1];assert(first.seconds==4200)
        formats=0;for i=1,60 do now=3000+i;local r=A:BuildStaticRows()[1];assert(r.seconds==4200-i) end
        assert(formats==0,'static formats repeated='..formats)
        ReplicatedSuite.Data.RuEvents[1].hour=3;A:ResetTransient();assert(A:BuildStaticRows()[1].seconds==7800-60)
        ReplicatedSuite.Data.RuEvents={{name='new',days={1},hour=4,minute=0,duration=10}}
        assert(A:BuildStaticRows()[1].name=='new')
        """)

    def test_view_state_does_not_invalidate_unchanged_layout_and_can_force_repair(self):
        lua = LuaRuntime()
        lua.execute("""
        DEFAULTS={ready={title='',detail='',tone='default'}};function NormalizeState(s) return s end
        V={metrics={}};controller={view={InvalidateLayout=function() layouts=layouts+1 end},revision=0};layouts=0
        """)
        lua.execute(section("ui/framework/rs_ui_view_state.lua", "    function controller:Set(state, options)", "    function controller:SetReady()"))
        lua.execute("""
        controller:Set('ready');for i=1,10 do controller:Set('ready') end
        assert(layouts==1,'unchanged view-state invalidations: '..layouts)
        controller:Set('ready',{detail='changed'});assert(layouts==2)
        controller:Set('ready',{detail='changed',force=true});assert(layouts==3)
        """)

    def test_trade_settings_getters_share_current_refresh_projection(self):
        lua = LuaRuntime()
        lua.execute("""
        reads=0;mode='all';Feature={Commands={}}
        function Feature:GetProjection() reads=reads+1;return {viewMode=mode,rows={},ratioMode='current'} end
        panel={controls={},choices={},prefix='test_'};instance={};RSUI={}
        function SettingsRow() return {} end
        function control(get) return {get=get,Render=function(self) self.value=self.get and self.get() end,SetEnabled=function() end,SetText=function() end} end
        function SettingsChoice(p,k,title,items,get,set) return control(get) end
        function RSUI:SegmentedSelector(s) return control(s.get) end
        function RSUI:HorizontalBox() return {} end
        function RSUI:Button() return control() end
        Contents={specs={Trade={refreshControls=function(c) for _,n in ipairs({'fromDropdown','toDropdown','favoriteDropdown','viewSelector'}) do c[n]:Render() end end}}}
        """)
        lua.execute(section("presentation/v3/widgets/rs_v3_life_economy_widgets.lua", "local function BuildTradeSettings(", "local function BuildBondSettings(") + "BuildTradeSettings(instance,panel,Feature)")
        lua.execute("""
        panel.refresh(Feature:GetProjection());assert(reads==1,'each getter rebuilt projection: '..reads)
        mode='cargo';panel.refresh(Feature:GetProjection());assert(reads==2 and panel.controls.viewSelector.value=='cargo','stale settings snapshot')
        """)

    def test_view_state_retries_rejected_native_visibility_without_force(self):
        lua = LuaRuntime()
        lua.execute("""
        DEFAULTS={ready={title='',detail='',tone='default'}};function NormalizeState(s) return s end
        V={metrics={}};calls=0;reject=true;layouts=0
        controller={revision=0,view={InvalidateLayout=function() layouts=layouts+1 end},message={
         SetText=function() end,SetTone=function() end,SetVisibility=function(self,value)
          calls=calls+1;if reject then return false,false,'rejected' end;self.visibility=value;return true,true end}}
        """)
        lua.execute(section("ui/framework/rs_ui_view_state.lua", "    function controller:Set(state, options)", "    function controller:SetReady()"))
        lua.execute("""
        controller:Set('ready');reject=false;controller:Set('ready')
        assert(calls==2 and controller.message.visibility=='collapsed','same state swallowed visibility retry')
        local n=layouts;controller:Set('ready');assert(layouts==n,'recovered state kept invalidating')
        """)

    def test_craft_quote_reuses_recipe_but_inventory_context_and_manual_refresh_stay_live(self):
        lua = LuaRuntime()
        lua.execute(COPY + """
        native={recipe=0,bag=0};heldCount=2;price=nil;failMaterial=false
        X2Bag={Capacity=function() return 1 end,GetBagItemInfo=function() native.bag=native.bag+1;return {itemType=20,count=heldCount} end}
        X2Craft={GetCraftBaseInfo=function() native.recipe=native.recipe+1;return {name='recipe'} end,
         GetCraftProductInfo=function() native.recipe=native.recipe+1;return {{itemType=10,count=1}} end,
         GetCraftMaterialInfo=function(_,id,doodad) native.recipe=native.recipe+1;if failMaterial then error('unavailable') end;return {{itemType=20,count=5+doodad}} end}
        ReplicatedSuite={Generation=1,Persistence={},SharedBounds={BagScanLimit=32},Features={},Services={PriceQuoteQueueV3={GetPriceByItemType=function() return price end}}}
        local S=ReplicatedSuite
        S.FeatureSliceFactory={Copy=Copy,Number=function(v) return tonumber(v) end,Text=function(v,f) return v==nil and (f or '') or tostring(v) end,
         Scalar=function(v,k) if type(v)=='table' then return v[k] end;return v end,
         Call=function(cap,obj,method,...) local ok,a=pcall(obj[method],obj,...);return ok,ok and a or nil,not ok and a or nil end,
         NewFeature=function(id,spec) local f={State=Copy(spec.state),Id=id};S.Features.CraftAssistant=f;f.spec=spec;return f end}
        """)
        lua.execute(source("features/tools/craft/rs_craft_feature.lua"))
        lua.execute("""
        F=ReplicatedSuite.Features.CraftAssistant;F.State.craftType=1
        F.spec.read(F,'manual');assert(native.recipe==3)
        price=100;heldCount=4;F.spec.read(F,'craft_quote_completed')
        assert(native.recipe==3,'quote re-read recipe: '..native.recipe)
        assert(native.bag==2,'dynamic bag was frozen')
        local m=F.CraftProjection.recipes[1].materials.items[1]
        assert(m.held==4 and m.shortage==1 and m.unitCost==100 and m.lineCost==500)
        m.count=99;F.spec.read(F,'craft_quote_completed');assert(F.CraftProjection.recipes[1].materials.items[1].count==5,'cache shared enriched item')
        F.State.doodadId=1;F.spec.read(F,'craft_quote_completed');assert(native.recipe==6,'wrong doodad cache reused')
        F.spec.read(F,'manual');assert(native.recipe==9,'manual refresh did not invalidate')
        failMaterial=true;F.spec.read(F,'manual');failMaterial=false;local n=native.recipe
        F.spec.read(F,'craft_quote_completed');assert(native.recipe==n+3,'failed recipe poisoned cache')
        ReplicatedSuite.Generation=2;n=native.recipe;F.spec.read(F,'craft_quote_batch_completed');assert(native.recipe==n+3,'old generation reused')
        F.spec.reconcileDemand(F,{count=1},{count=0});assert(F.CraftRecipeCache==nil,'last consumer retained cache')
        """)


class AdditionalPerformanceTests(unittest.TestCase):
    def test_scheduler_interval_changes_same_task_and_preserves_breaker(self):
        lua = LuaRuntime()
        lua.execute("""
        Scheduler={tasks={visual={intervalMs=50,lane='background',elapsedMs=20,failureCount=2}}}
        BACKGROUND_MIN_INTERVAL_MS=50;INTERACTIVE_MIN_INTERVAL_MS=16;HIGHFREQUENCY_MIN_INTERVAL_MS=1
        function Finite(v,f)return tonumber(v) or f end
        original=Scheduler.tasks.visual
        """)
        lua.execute(section("core/rs_scheduler.lua", "local function TaskInterval(task)", "-- Bounded one-shot"))
        lua.execute("""
        assert(Scheduler:SetTaskInterval('visual',1,true));assert(original==Scheduler.tasks.visual)
        assert(original.intervalMs==1 and original.lane=='highfrequency' and original.failureCount==2)
        assert(original.elapsedMs==1);assert(not Scheduler:SetTaskInterval('visual',0,true))
        assert(not Scheduler:SetTaskInterval('missing',10,true));assert(not Scheduler:SetTaskInterval('visual',0/0,true))
        assert(Scheduler:SetTaskInterval('visual',100,true) and original.intervalMs==100)
        """)

    def test_death_record_has_one_copy_and_stays_detached(self):
        lua = LuaRuntime()
        lua.execute("""
        S={};F={};A={revision=1};copies=0;stored={serial=1,time=1000,events={{time=900,amount=1}},debuffs={}}
        function DeepCopy(v)if type(v)~='table'then return v end
         if v.serial and v.events then copies=copies+1 end
         local r={};for k,x in pairs(v)do r[k]=DeepCopy(x)end;return r end
        S.Utils={DeepCopy=DeepCopy};P={IsStoreLoaded=function()return true end};F.Records={[1]=stored}
        function ClampInt(v)return v end;function F:EnsureRecordStore()return 'record' end
        function F:FindHistoryMeta()return {serial=1,storageId=1}end
        function F:GetSettings()return {}end;function F:GetHealth()return {}end
        function A:GetHistoryRows()return {}end;F.Authority=A
        """)
        lua.execute(section("features/combat/death_review/rs_death_review_store.lua", "function F:LoadRecord(storageId)", "function F:SaveRecord("))
        lua.execute(section("features/combat/death_review/rs_death_review_authority.lua", "function A:GetRecord(serial)", "function A:DeleteRecord("))
        lua.execute(section("features/combat/death_review/rs_death_review_feature.lua", "function F:GetProjection(request)", "function F:GetSettingsProjection()"))
        lua.execute("""
        p=F:GetProjection({serial=1});assert(copies==1);p.record.events[1].amount=99
        assert(stored.events[1].amount==1);p=F:GetProjection({serial=1});assert(p.timelineRows[1].amount==1)
        """)

    def test_auction_status_does_not_copy_listings(self):
        lua = LuaRuntime()
        lua.execute(COPY + """
        S={Services={}};ReplicatedSuite=S;S.FeatureSliceFactory={Copy=Copy,Text=tostring}
        Q={snapshots={audit={status='ready',count=30,rows={}}}};S.Services.AuctionQueryV3=Q
        for i=1,30 do Q.snapshots.audit.rows[i]={name='listing',key=i}end
        function Q:GetSnapshot()error('scalar projection copied listings')end
        """)
        lua.execute(section("services/rs_auction_query_v3.lua", "function Q:GetStatusSnapshot(requester)", "-- 一次性严格消费者"))
        lua.execute(source("features/tools/auction/rs_auction_read_model.lua"))
        lua.execute("""
        local p=S.AuctionReadModel.Projection({Id='audit',State={favorites={}}})
        assert(p.resultCount==30 and p.resultStatus=='ready')
        Q.snapshots.audit.status='waiting';assert(S.AuctionReadModel.Projection({Id='audit',State={favorites={}}}).resultStatus=='waiting')
        """)

class FeatureRegressionTests(unittest.TestCase):
    def test_activity_quest_tail_does_not_override_next_occurrence(self):
        lua = LuaRuntime()
        lua.execute("ReplicatedSuite={Generation=1,Data={RuEvents={{name='event',days={1},hour=2,minute=0,duration=10,taskTailMinutes=90,questKey='tail'}}}}")
        lua.execute(source("features/life/activities/rs_activity_authority.lua"))
        lua.execute("""
        A=ReplicatedSuite.Features.Activities.Authority
        function A:GetWeekSeconds() return 8400 end;function A:GetDateSerial() return 739900 end
        A.questProgressProvider=function()return {tailInFlightCount=1}end
        local r=A:BuildStaticRows()[1]
        assert(not r.active and r.seconds==603600 and r.secondsUntilStart==603600)
        assert(r.status:find('后开始',1,true),'quest retention must not replace the next start countdown')
        """)

    def test_dps_warm_overview_skips_metric_ranking_and_invalidates(self):
        lua = LuaRuntime()
        lua.execute("""
        F={};S={Generation=1,Features={CombatAnalytics={IsMetricPreferenceEnabled=function()return true end}}}
        calls=0;metric={state={revision=1}};d={revision=1}
        function Domain()return d end;function Analytics()return a end;function Relation()return nil end
        a={GetMetric=function()return metric end,GetCollectionScope=function()return 'all' end,IsSelfActor=function()return false end}
        function a:GetMetricProjection()calls=calls+1;return {dataRevision=metric.state.revision,statsAvailable=true,rows={{key='x',name='x',kills=2}}}end
        function d:GetProjection()return {sides={friendly={rows={}},enemy={rows={}},unknown={rows={}}}}end
        """)
        lua.execute(section("features/combat/dps/rs_dps_feature.lua", "function F:GetCombatOverview()", "function F:GetHealth()"))
        lua.execute("""
        local first=F:GetCombatOverview();for i=1,60 do assert(F:GetCombatOverview()==first)end;assert(calls==1)
        metric.state.revision=2;F:GetCombatOverview();assert(calls==2)
        d.revision=2;F:GetCombatOverview();assert(calls==3)
        """)

    def test_trade_selected_mode_calculates_only_one_price_and_keeps_unknown_cost(self):
        lua = LuaRuntime()
        lua.execute("""
        Trade={State={ratioMode='current',commerceMode='off'}};TA={};TRADE_FULL_RATIO=130
        function Number(v)return tonumber(v)end;function Money(v)return tostring(v)end
        function TradeZoneName()return 'zone'end
        priceCalls=0;function TradePrice(_,_,ratio)priceCalls=priceCalls+1;return ratio*100,{complete=true,status='ready'}end
        function ApplyTradeMaterialProjectionToRow(row)row.materialCostComplete=true;row.materialCostCopper=5000;row.profitCopper=row.priceCopper-5000 end
        function ApplyTradeFastMaterialCarryForward(row,previous)
          if not previous then return false end
          row.materialCostCopper=previous.materialCostCopper;row.materialCostComplete=previous.materialCostComplete;row.profitCopper=row.priceCopper-row.materialCostCopper;return true
        end
        """)
        lua.execute(section("features/life/trade/rs_trade_feature.lua", "local function ApplyTradeDisplayModeToRow(row, options)", "local function CopyTradeRouteRow(raw)") +
                    "Apply=ApplyTradeDisplayModeToRow")
        lua.execute("""
        local r={currentRatio=110};assert(Apply(r));assert(r.priceCopper==11000 and r.profitCopper==6000 and priceCalls==1)
        Trade.State.ratioMode='full';assert(Apply(r));assert(r.priceCopper==13000 and r.currentRatio==110 and r.rate=='130%' and r.tone=='green' and priceCalls==2)
        r.currentRatio=120;assert(Apply(r,{includeMaterials=false,previousRow={materialCostComplete=true,materialCostCopper=7000}}))
        assert(r.profitCopper==6000 and priceCalls==3)
        assert(Apply(r,{includeMaterials=false}));assert(r.profitCopper==nil and r.profit=='--' and priceCalls==4)
        """)

if __name__ == "__main__":
    unittest.main(verbosity=2)
