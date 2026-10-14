------------------------------------------------------------------------
-- Replicated Suite · 翡翠谷售价名称匹配回归
-- 作者：Replicated
-- QQ群：1104129461
--
-- 回放用户导出的原生货物名，加载真实售价表和收益服务；仅作离线契约验证，不调用游戏 API。
------------------------------------------------------------------------
ReplicatedSuite = { Data = {}, Services = {} }
dofile("data/rs_trade_prices.lua")
dofile("services/rs_trade_payout_v3.lua")
local S, P = ReplicatedSuite, ReplicatedSuite.Services.TradePayoutV3
local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1 else print("FAIL " .. name .. ": " .. tostring(err)) end
end

-- 四种名称和货率来自 RS-20261014-111847 的原生路线回包，不能把完整产地名改写进服务器身份。
local OBSERVED = {
    { name = "[翡翠谷]保存特制特产", canonical = "[翡翠]保存特制特产", ratio = 123 },
    { name = "[翡翠谷]保存特产", canonical = "[翡翠]保存特产", ratio = 118 },
    { name = "[翡翠谷]保存传统特产", canonical = "[翡翠]保存传统特产", ratio = 130 },
    { name = "[翡翠谷]保存肥料特产", canonical = "[翡翠]保存肥料特产", ratio = 130 },
}
for _, destination in ipairs({ 4, 12, 17 }) do
    for _, row in ipairs(OBSERVED) do
        Test("alias " .. destination .. " " .. row.name, function()
            local key, mode = P:ResolvePriceKey(destination, row.name, "翡翠谷")
            assert(key == row.canonical and mode == "alias", "原生完整产地名未找到同品类售价")
            local canonicalPrice = P:Estimate({ destination = destination, itemName = row.canonical, ratio = row.ratio })
            local price, detail = P:Estimate({ destination = destination, itemName = row.name, ratio = row.ratio })
            assert(price == canonicalPrice and type(price) == "number" and price > 0, "别名与原售价计算不一致")
            assert(detail.status == "ready" and detail.complete and detail.packMultiplier == 1.03)
            assert(row.name:find("[翡翠谷]", 1, true) == 1, "原始货物身份被修改")
        end)
        Test("canonical " .. destination .. " " .. row.canonical, function()
            local key, mode = P:ResolvePriceKey(destination, row.canonical, "翡翠谷")
            assert(key == row.canonical and mode == "exact", "现有精确售价名不应走别名")
        end)
    end
end

-- 已存在的五种翡翠谷货物保持精确匹配；它们与缺价的四种保存特产来自同一诊断回包。
for _, name in ipairs({ "翡翠谷持国天特产", "翡翠谷偃月刀", "翡翠谷加工发酵蜂蜜", "翡翠谷加工发酵奶酪", "翡翠谷加工发酵药材" }) do
    Test("unchanged " .. name, function()
        local key, mode = P:ResolvePriceKey(4, name, "翡翠谷")
        local price, detail = P:Estimate({ destination = 4, itemName = name, ratio = 130 })
        assert(key == name and mode == "exact" and type(price) == "number" and detail.status == "ready")
    end)
end

Test("reported traditional payout", function()
    -- 诊断选中项：目的地 4、货率 130%；这里只核对不含经商加成的基准，不能冒充实售金额。
    local price, detail = P:Estimate({ destination = 4, itemName = OBSERVED[3].name, ratio = 130 })
    assert(price == 233511 and detail.priceKey == OBSERVED[3].canonical, "已知静态基准与保存品类加成错误")
end)
Test("unknown names remain unknown", function()
    for _, name in ipairs({ "[未知]保存传统特产", "[翡翠谷]保存传统特产货物", "翡翠谷保存传统特产" }) do
        local price, detail = P:Estimate({ destination = 4, itemName = name, originZoneName = "翡翠谷", ratio = 130 })
        assert(price == nil and detail.status == "price_key_missing", "未知货物不能借产地名猜测售价")
    end
end)
Test("missing destination stays unavailable", function()
    local price, detail = P:Estimate({ destination = 5, itemName = OBSERVED[3].name, ratio = 130 })
    assert(price == nil and detail.status == "price_key_missing", "不能跨目的地借用基价")
end)
Test("exact native price wins", function()
    -- 单独构造测试目的地；原生完整名已有精确售价时，必须优先于兼容别名。
    S.Data.TradePrices[999] = { [OBSERVED[3].name] = { 1 }, [OBSERVED[3].canonical] = { 2 } }
    local key, mode = P:ResolvePriceKey(999, OBSERVED[3].name, "翡翠谷")
    assert(key == OBSERVED[3].name and mode == "exact")
end)
print(string.format("Trade price-key aliases: %d/%d passed", passed, total))
assert(passed == total, "翡翠谷售价名称回归未通过")
