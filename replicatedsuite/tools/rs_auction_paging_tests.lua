-- Replicated Suite · 拍卖分页测试
-- 作者：Replicated
-- QQ群：1104129461
-- 真实 Auction Feature/Store/分页页面/RSUI pooled rows；仅查询快照和 Native 绘制使用宿主事实。
local Boot=dofile('tools/rs_gear_page_test_host.lua')
local passed,failed=0,0
local function T(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS auction-paging '..name)else failed=failed+1;print('FAIL auction-paging '..name..': '..tostring(err))end
end
local function Build(kind)
 local h=Boot({width=900,height=1100});local S=h.S;assert(h.page:OnDeactivated())
 dofile('core/rs_demand.lua');dofile('features/shared/rs_feature_slice_factory.lua');dofile('features/shared/rs_shared_bounds.lua')
 h.query={status='idle',rows={},count=0};h.searches=0
 S.Services.AuctionQueryV3={GetSnapshot=function()return h.Copy(h.query)end,Search=function()h.searches=h.searches+1;return true end}
 dofile('features/tools/auction/rs_auction_read_model.lua');dofile('features/tools/market_analysis/rs_market_analysis_feature.lua');dofile('features/tools/auction/rs_auction_feature.lua')
 local id=kind=='market' and 'tools_market_analysis' or 'tools_auction';local route=kind=='market' and 'tools.market_analysis' or 'tools.auction_favorites'
 local F=S.Features[id];assert(F:Initialize());assert(F:Enable())
 if kind~='market' then for i=1,20 do assert(F.Commands:AddFavorite(('收藏%02d'):format(i)))end
 else for i=1,25 do h.query.rows[i]={key='result:'..i,name=('挂单%02d'):format(i),text='当前挂单',statusText='可询价',itemType=1000+i,itemGrade=1,kind='result'}end;h.query.count=25;h.query.status='ready' end
 assert(F.Commands:Refresh('test_seed'))
 dofile('ui/framework/rs_ui_forms.lua');dofile('ui/framework/rs_ui_settings_foundation.lua')
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/shell/rs_v3_page_host.lua');dofile('presentation/v3/pages/rs_v3_business_pages.lua')
 local parent=h.Native(nil,'auction-paging-parent',0,0,900,1100);local page=assert(S.UIV3.PageHost.factories[route](parent,route))
 assert(page:OnActivated());assert(page:Refresh())
 local widgets={};local function Index(n)widgets[n.id]=n;for _,child in ipairs(n.children or {})do Index(child)end end;Index(page)
 local function Layout()
  parent:SetExtent(900,1100);page:SetBounds(0,0,900,1100);page:InvalidateMeasure('test_paging');S.RSUI:FlushLayoutQueue(64)
  assert(S.RSUI:GetLayoutQueueSnapshot().pending==0,'page layout did not converge')
 end
 local function Click(suffix)local c=assert(widgets['v3_business_'..id..suffix],suffix);return c.root.events.OnClick(c.root,'LeftButton')end
 Layout();return h,S,F,page,widgets,Layout,Click,id
end
local function FirstBound(page)
 local list=page.tableView.list;local first=list:GetVisibleRange();local slot=assert(list.poolByIndex[first],'first visible row missing')
 return slot.row.item,list
end
T('favorite page changes repaint native pooled rows with unchanged domain revision',function()
 local h,S,F,p,w,Layout,Click,id=Build();local before=F:GetProjection().revision
 local row=FirstBound(p);assert(row.name=='收藏01');local writes=h.writes
 assert(Click('_auction_next'));Layout();row=FirstBound(p)
 assert(row.name=='收藏11','page number changed but native row still displays previous page')
 assert(w['v3_business_'..id..'_auction_page_text'].text:find('2/2',1,true))
 assert(Click('_auction_prev'));Layout();row=FirstBound(p);assert(row.name=='收藏01')
 assert(F:GetProjection().revision==before and h.writes==writes and h.searches==0,'paging mutated domain or queried server')
end)
T('market analysis shares correct last partial page and previous-page rebinding',function()
 local h,S,F,p,w,Layout,Click,id=Build('market');assert(Click('_auction_next'));Layout();local row=FirstBound(p)
 assert(row.name=='挂单11','market reused old rows');assert(Click('_auction_next'));Layout();row=FirstBound(p)
 assert(row.name=='挂单21' and p.tableView:GetItemCount()==5)
 assert(not w['v3_business_'..id..'_auction_next'].enabled and w['v3_business_'..id..'_auction_prev'].enabled)
 assert(Click('_auction_prev'));Layout();row=FirstBound(p);assert(row.name=='挂单11')
end)
T('page changes clear selection and disarm removal of a previous-page favorite',function()
 local h,S,F,p,w,Layout,Click,id=Build();assert(p.tableView:SetSelectedIndex(1));assert(Click('_remove'))
 assert(w['v3_business_'..id..'_remove'].text=='确认删除?')
 assert(Click('_auction_next'));Layout();assert(p.tableView:GetSelectedKey()==nil,'previous-page selection survived')
 assert(Click('_remove')==false,'page change left a previous favorite armed');assert(#F:GetFavorites()==20)
end)
T('deleting an earlier favorite preserves selected keyword instead of retargeting its index',function()
 local h,S,F,p,w,Layout,Click,id=Build();assert(p.tableView:SetSelectedIndex(2));assert(Click('_remove'))
 assert(F.Commands:RemoveFavorite(1));assert(F.Commands:Refresh('test_external_delete'));assert(p:Refresh());Layout()
 assert(Click('_remove'));local favorites=F:GetFavorites()
 assert(favorites[1]=='收藏03','deletion targeted shifted index rather than selected keyword')
end)
T('page changes reset row scroll and selecting the new first row deletes only that favorite',function()
 local h,S,F,p,w,Layout,Click,id=Build();p.tableView:Layout(0,0,600,105);p.tableView:ScrollToBottom();assert(p.tableView.list.scrollOffset>0)
 assert(Click('_auction_next'));assert(p.tableView.list.scrollOffset==0,'new page retained previous row scroll');Layout()
 assert(p.tableView:SetSelectedIndex(1));assert(Click('_remove'));assert(Click('_remove'))
 local favorites=F:GetFavorites();assert(#favorites==19 and favorites[1]=='收藏01' and favorites[11]=='收藏12','second-page deletion used old page index')
 local row=FirstBound(p);assert(row.name=='收藏12','deleting first row left stale native text')
end)
T('paging clears a selected result quote and prevents the old item from being queried',function()
 local h,S,F,p,w,Layout,Click,id=Build()
 h.query={status='ready',count=1,rows={{key='result:quote',name='询价物品',itemType=9001,itemGrade=1,text='挂单',statusText='可查询'}}};assert(F.Commands:Refresh('test_results'));assert(p:Refresh())
 assert(Click('_auction_next'));assert(Click('_auction_next'));Layout();assert(p.tableView:SetSelectedIndex(1))
 local calls=0;F.Commands.Quote=function()calls=calls+1;return true end
 assert(w['v3_business_'..id..'_quote'].enabled);assert(Click('_auction_prev'));Layout()
 assert(not w['v3_business_'..id..'_quote'].enabled,'previous-page quote remains enabled')
 assert(Click('_quote')==false and calls==0,'old selected item was quoted after page change')
end)
T('shrinking results clamps page and empty lists disable both navigation actions',function()
 local h,S,F,p,w,Layout,Click,id=Build('market');assert(Click('_auction_next'));assert(Click('_auction_next'))
 h.query.rows={h.query.rows[1]};h.query.count=1;assert(F.Commands:Refresh('test_shrink'));assert(p:Refresh());Layout()
 assert(w['v3_business_'..id..'_auction_page_text'].text:find('1/1',1,true));local row=FirstBound(p);assert(row.name=='挂单01')
 h.query.rows={};h.query.count=0;h.query.status='empty';assert(F.Commands:Refresh('test_empty'));assert(p:Refresh());Layout()
 assert(p.tableView:GetItemCount()==1 and p.tableView:GetItem(1).key=='market:hint','empty results lost the existing informational row')
 assert(not w['v3_business_'..id..'_auction_prev'].enabled and not w['v3_business_'..id..'_auction_next'].enabled)
 h.query.status='waiting';assert(F.Commands:Refresh('test_waiting_empty'));assert(p:Refresh());Layout()
 assert(p.tableView:GetItemCount()==0 and not w['v3_business_'..id..'_auction_prev'].enabled and not w['v3_business_'..id..'_auction_next'].enabled)
end)
T('removing the selected row elsewhere clears its action instead of falling back to the next index',function()
 local h,S,F,p,w,Layout,Click,id=Build();assert(p.tableView:SetSelectedIndex(1))
 assert(F.Commands:RemoveFavoriteByKeyword('收藏01'));assert(F.Commands:Refresh('test_selected_removed'));assert(p:Refresh());Layout()
 assert(p.tableView:GetSelectedKey()==nil,'missing primary key fell back to an unrelated index')
 assert(Click('_remove')==false and F:GetFavorites()[1]=='收藏02','stale selection deleted the following favorite')
end)
print(('AUCTION_PAGING_RESULT passed=%d failed=%d'):format(passed,failed));if failed>0 then error('auction paging tests failed')end
