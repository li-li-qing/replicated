------------------------------------------------------------------------
-- Replicated Suite · 交易比例选择界面测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 真实页面/嵌入内容/RSUI；Feature Native货率边界用模式感知替身，真实计算由 rs_trade_tests 覆盖。
------------------------------------------------------------------------
local Boot=dofile('tools/rs_workspace_home_test_host.lua')
local S,_,_,_,_,h=Boot({enabled={life_trade=true},skipLayout=true})
local F=S.Features.Trade;local mode,revision,calls='current',1,0
function F:GetProjection()
    return {revision=revision,ratioMode=mode,viewMode='all',status='ready',rows={{key='pack',name='货物',rate=mode=='full'and '130%'or '110%',price=mode=='full'and '13金'or '11金',profit=mode=='full'and '8金'or '6金'}},
        zones={{id=1,name='甲'}},sellableZones={{id=2,name='乙'}},fromZone=1,toZone=2,favoriteItems={},quoteBatch={active=false,total=0,completed=0},pendingQuoteCount=0}
end
function F.Commands:SetRatioMode(value)assert(value=='current'or value=='full');calls=calls+1;mode=value;revision=revision+1;return true end
dofile('presentation/v3/shell/rs_v3_page_host.lua')
dofile('presentation/v3/pages/rs_v3_life_m16_pages.lua')
local parent=h.Native(nil,'trade_ratio_parent',0,0,850,700)
local page=assert(S.UIV3.PageHost.factories['life.trade'](parent,'life.trade'));assert(page:OnActivated());page:Layout(0,0,850,700)
local selector=assert(page.tradeRatioModeButton);assert(#selector.items==2)
local function Click(control,index)local b=control.buttons[index];return b.root.events.OnClick(b.root,'LeftButton')end
assert(Click(selector,2));assert(mode=='full'and page.tableView:GetItem(1).price=='13金'and selector.value=='full')
assert(Click(selector,1));assert(mode=='current'and page.tableView:GetItem(1).profit=='6金'and calls==2)
local content=assert(S.UIV3.LifeEconomyContent:Create(parent,'Trade','trade_ratio_float_'))
assert(content:Refresh());content.content:Layout(0,0,308,350)
local floatSelector=assert(content.ratioSelector);assert(#floatSelector.items==2)
for _,button in ipairs(floatSelector.buttons)do local shown,why=h:VisibleRect(button);assert(shown,why)end
assert(Click(floatSelector,2));assert(mode=='full'and content.table:GetItem(1).rate=='130%'and calls==3)
assert(page:Refresh());assert(selector.value=='full')
assert(Click(floatSelector,1));assert(mode=='current'and content.table:GetItem(1).price=='11金'and calls==4)
local function Columns(view)
    for _,column in ipairs(view.columns)do
        assert(column.field~='comparisonPrice'and column.field~='comparisonProfit'and column.field~='currentRate','comparison column survived')
    end
end
Columns(page.tableView);Columns(content.table)
assert(page:OnDeactivated())
print('TRADE_RATIO_SELECTOR_UI: page/floating two explicit options, one set of values, shared mode and compact columns passed (Native modeled)')
