------------------------------------------------------------------------
-- Replicated Suite - Trade material recipe reference
-- Adapted from the user-provided 货率2.5 addon material table.
-- This file is data-only: no API calls, no timers, no global mutable state.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

S.Data.TradeMaterialResources = {
    ["Chopped Produce"] = {1},
    ["Ground Grain"] = {2},
    ["Trimmed Meat"] = {3},
    ["Dried Flowers"] = {4},
    ["Orchard Puree"] = {5},
    ["Ground Spices"] = {6},
    ["Gilda Star"] = {7},
    ["Egg"] = {8},
    ["Grape"] = {9},
    ["Goose Down"] = {10},
    ["Apple"] = {11},
    ["Milk"] = {12},
    ["Olive"] = {13},
    ["Wool"] = {14},
    ["Narcissus"] = {15},
    ["Medicinal Powder"] = {16},
    ["Duck Down"] = {17},
    ["Cherry"] = {18},
    ["Pomegranate"] = {19},
    ["Bay Leaf"] = {20},
    ["Yam"] = {21},
    ["Banana"] = {22},
    ["Mushroom"] = {23},
    ["Avocado"] = {24},
    ["Rosemary"] = {25},
    ["Barley"] = {26},
    ["Rice"] = {27},
    ["Corn"] = {28},
    ["Cornflower"] = {29},
    ["Rye"] = {30},
    ["Sunflower"] = {31},
    ["Turmeric"] = {32},
    ["Carrot"] = {33},
    ["Azalea"] = {34},
    ["Lily"] = {35},
    ["Ginkgo Leaf"] = {36},
    ["Cucumber"] = {37},
    ["Fig"] = {38},
    ["Peanut"] = {39},
    ["Onion"] = {40},
    ["Potato"] = {41},
    ["Oats"] = {42},
    ["Millet"] = {43},
    ["Garlic"] = {44},
    ["Yata Fur"] = {45},
    ["Saffron"] = {46},
    ["Jujube"] = {47},
    ["Lemon"] = {48},
    ["Mint"] = {49},
    ["Lavender"] = {50},
    ["Tomato"] = {51},
    ["Moringa Fruit"] = {52},
    ["Iris"] = {53},
    ["Aloe"] = {54},
    ["Orange"] = {55},
    ["Rose"] = {56},
    ["Strawberry"] = {57},
    ["Flaming Log"] = {58},
    ["Archeum Log"] = {59},
    ["Silver Lily"] = {60},
    ["Crimson Petunia"] = {61},
    ["Lumber"] = {62},
    ["Honey"] = {63},
    ["Hay Bale"] = {64},
    ["Royal Seed"] = {65},
    ["Cultivated Ginseng"] = {66},
    ["Quality Certificate"] = {67},
    ["Cedar Hardwood"] = {68},
    ["Time-Space Rift Shard"] = {69},
    ["Iron Ingot"] = {70},
    ["Blue Salt Bond"] = {71},
    ["Small Root Pigment"] = {72},
    ["Small Seed Oil"] = {73},
    ["Opaque Polish"] = {74}
}


-- ArcheRage/legacy specialty packs that are returned by the live specialty
-- ratio API but are not part of the compact standard/fertilizer/larder tables.
-- Keep the server-provided English name as the canonical key; localization is
-- presentation-only in TradeService/TradeMaterials.
S.Data.TradeMaterialCustom = {
    -- Craft 5400: 特产：[古代森林]糖醋泡蒜
    -- 特产品质认证书 x1、杉树粗木 x1、大蒜 x150.
    ["Silent Forest Aged Garlic"] = { {1, 1, 150}, {67, 68, 44} },
}

S.Data.TradeMaterialNuia = {
    ["Ahnimar Preserved Gilda Specialty"] = { {300, 5, 2},{3, 9, 7} },
    ["Ahnimar Preserved Local Specialty"] = { {160, 5},{16, 29} },
    ["Ahnimar Preserved Specialty"] = { {200, 15},{1, 23} },
    ["Airain Commercial Gilda Specialty"] = { {300, 10, 2},{4, 17, 7} },
    ["Airain Commercial Local Specialty"] = { {150, 5},{1, 30} },
    ["Airain Commercial Specialty"] = { {180, 15},{3, 26} },
    ["Aubre Commercial Gilda Specialty"] = { {300, 15, 2},{3, 27, 7} },
    ["Aubre Commercial Local Specialty"] = { {150, 10}, {10, 8} },
    ["Aubre Commercial Specialty"] = { {180, 15}, {16, 28} },
    ["Cinderstone Luxury Gilda Specialty"] = { {300, 5, 2},{4, 11, 7} },
    ["Cinderstone Luxury Local Specialty"] = { {150, 15}, {16, 34} },
    ["Cinderstone Luxury Specialty"] = { {180, 3}, {6, 20} },
    ["Dewstone Fine Gilda Specialty"] = { {300, 10, 2},{2, 14, 7} },
    ["Dewstone Fine Local Specialty"] = { {150, 10}, {5, 36} },
    ["Dewstone Fine Specialty"] = { {180, 15}, {16, 15} },
    ["Gweonid Commercial Gilda Specialty"] = { {300, 10, 2},{5, 10, 7} },
    ["Gweonid Commercial Local Specialty"] = { {150, 15}, {16, 40} },
    ["Gweonid Commercial Specialty"] = { {180, 5}, {1, 11} },
    ["Halcyona Preserved Gilda Specialty"] = { {300, 10, 2},{2, 8, 7} },
    ["Halcyona Preserved Local Specialty"] = { {160, 5}, {1, 42} },
    ["Halcyona Preserved Specialty"] = { {200, 5}, {4, 21} },
    ["Hellswamp Preserved Gilda Specialty"] = { {300, 5, 2},{3, 22, 7} },
    ["Hellswamp Preserved Local Specialty"] = { {160, 5}, {6, 39} },
    ["Hellswamp Preserved Specialty"] = { {200, 15}, {5, 23} },
    ["Karkasse Commercial Gilda Specialty"] = { {300, 10, 2},{4, 17, 7} },
    ["Karkasse Commercial Local Specialty"] = { {150, 5}, {5, 25} },
    ["Karkasse Commercial Specialty"] = { {180, 15}, {3, 28} },
    ["Lilyut Fine Gilda Specialty"] = { {300, 5, 2},{6, 12, 7} },
    ["Lilyut Fine Local Specialty"] = { {150, 15}, {5, 27} },
    ["Lilyut Fine Specialty"] = { {180, 3}, {4, 13} },
    ["Marianople Fine Gilda Specialty"] = { {300, 10, 2},{4, 17, 7} },
    ["Marianople Fine Local Specialty"] = { {150, 15}, {1, 53} },
    ["Marianople Fine Specialty"] = { {180, 2}, {6, 18} },
    ["Sanddeep Preserved Gilda Specialty"] = { {300, 5, 2},{16, 24, 7} },
    ["Sanddeep Preserved Local Specialty"] = { {160, 15}, {2, 37} },
    ["Sanddeep Preserved Specialty"] = { {200, 5}, {3, 25} },
    ["Solzreed Luxury Gilda Specialty"] = { {300, 10, 2},{3, 8, 7} },
    ["Solzreed Luxury Local Specialty"] = { {150, 5}, {6, 57} },
    ["Solzreed Luxury Specialty"] = { {180, 5}, {3, 9} },
    ["Two Crowns Luxury Gilda Specialty"] = { {300, 5, 2},{16, 12, 7} },
    ["Two Crowns Luxury Local Specialty"] = { {150, 15}, {4, 53} },
    ["Two Crowns Luxury Specialty"] = { {180, 3}, {2, 19} },
    ["White Arden Commercial Gilda Specialty"] = { {300, 5, 2},{1, 12, 7} },
    ["White Arden Commercial Local Specialty"] = { {150, 5}, {3, 21} },
    ["White Arden Commercial Specialty"] = { {180, 5}, {2, 9} }
}

S.Data.TradeMaterialHaranya = {
    ["Arcum Iris Commercial Gilda Specialty"] = { {300, 10, 2},{6, 8, 7} },
    ["Arcum Iris Commercial Local Specialty"] = { {150, 5},{2, 31} },
    ["Arcum Iris Commercial Specialty"] = { {180, 3},{4, 32}  },
    ["Falcorth Fine Gilda Specialty"] = { {300, 10, 2},{16, 10, 7} },
    ["Falcorth Fine Local Specialty"] = { {150, 15},{4, 33} },
    ["Falcorth Fine Specialty"] = { {180, 5},{2, 11}  },
    ["Hasla Preserved Gilda Specialty"] = { {10, 300, 2},{17, 16, 7}  },
    ["Hasla Preserved Local Specialty"] = { {150, 5},{16, 29}  },
    ["Hasla Preserved Specialty"] = { {180, 5},{6, 35} },
    ["Mahadevi Fine Gilda Specialty"] = { {300, 5, 2},{1, 22, 7}  },
    ["Mahadevi Fine Local Specialty"] = { {150, 15},{6, 37}  },
    ["Mahadevi Fine Specialty"] = { {180, 5},{5, 38} },
    ["Perinoor Preserved Gilda Specialty"] = { {300, 5, 2},{6, 24, 7}  },
    ["Perinoor Preserved Local Specialty"] = { {160, 5},{3, 39}  },
    ["Perinoor Preserved Specialty"] = { {200, 15},{5, 41}   },
    ["Rokhala Preserved Gilda Specialty"] = { {300, 5, 2},{6, 11, 7}  },
    ["Rokhala Preserved Local Specialty"] = { {160, 5},{4, 21}  },
    ["Rokhala Preserved Specialty"] = { {200, 15},{16, 34}  },
    ["Rookborne Preserved Gilda Specialty"] = { {300, 5, 2},{5, 12, 7}  },
    ["Rookborne Preserved Local Specialty"] = { {160, 5},{4, 43}  },
    ["Rookborne Preserved Specialty"] = { {200, 5},{1, 11}   },
    ["Silent Forest Commercial Gilda Specialty"] = { {300, 5, 2},{5, 12, 7}  },
    ["Silent Forest Commercial Local Specialty"] = { {150, 15},{16, 44}  },
    ["Silent Forest Commercial Specialty"] = { {180, 3},{6, 19}  },
    ["Solis Luxury Gilda Specialty"] = { {300, 10, 2},{16, 45, 7}  },
    ["Solis Luxury Local Specialty"] = { {150, 5},{2, 46}   },
    ["Solis Luxury Specialty"] = { {180, 2},{16, 47}  },
    ["Sunbite Commercial Gilda Specialty"] = { {300, 5, 2},{16, 48, 7}  },
    ["Sunbite Commercial Local Specialty"] = { {150, 5},{2, 49}  },
    ["Sunbite Commercial Specialty"] = { {180, 15},{5, 50}  },
    ["Tigerspine Fine Gilda Specialty"] = { {300, 5, 2},{2, 12, 7}  },
    ["Tigerspine Fine Local Specialty"] = { {150, 15},{3, 51}  },
    ["Tigerspine Fine Specialty"] = { {180, 5},{1, 9}  },
    ["Villanelle Luxury Gilda Specialty"] = { {300, 10, 2},{4, 14, 7} },
    ["Villanelle Luxury Local Specialty"] = { {150, 15},{1, 27} },
    ["Villanelle Luxury Specialty"] = { {180, 2},{4, 18} },
    ["Windscour Preserved Gilda Specialty"] = { {300, 3, 2},{3, 52, 7} },
    ["Windscour Preserved Local Specialty"] = { {160, 5},{1, 54} },
    ["Windscour Preserved Specialty"] = { {200, 6},{16, 49} },
    ["Ynystere Commercial Gilda Specialty"] = { {300, 5, 2},{1, 55, 7} },
    ["Ynystere Commercial Local Specialty"] = { {150, 15},{2, 56} },
    ["Ynystere Commercial Specialty"] = { {180, 3},{6, 13} }
}

S.Data.TradeMaterialAuroria = {
    ["Aegis Coastal Gilda Specialty"] = { {1, 5, 300},{58, 7, 1} },
    ["Aegis Coastal Local Specialty"] = { {15, 150},{37, 1} },
    ["Exeloch Coastal Gilda Specialty"] = { {1, 5, 300},{59, 7, 6} },
    ["Exeloch Coastal Local Specialty"] = { {15, 150},{51, 6} },
    ["Golden Ruins Coastal Gilda Specialty"] = { {3, 5, 300},{60, 7, 4} },
    ["Golden Ruins Coastal Local Specialty"] = { {15, 150},{53, 16} },
    -- CN 修正：黎明特供特制特产应为 兔坨毛x10、药粉x300、星星x2
    ["Sungold Coastal Gilda Specialty"] = { {10, 300, 2},{45, 16, 7} },
    -- CN 修正：黎明特供传统特产应为 谷物细粉x150、番红花x5
    ["Sungold Coastal Local Specialty"] = { {150, 5},{2, 46} },
    ["Whalesong Coastal Gilda Specialty"] = { {1, 5, 300},{58, 7, 2} },
    ["Whalesong Coastal Local Specialty"] = { {15, 150},{40, 2} }
}

S.Data.TradeMaterialFertilizer = { {50 , 50, 50, 50}, {1, 2, 3, 4} }

-- ArcheRage zone "Space-Time Fragment" packs (十字星平原/伊尼斯泰尔时空碎片).
-- Verified against the official ArcheRage wiki craft DB (e.g. crafts 10319/10314):
-- 2x Time-Space Rift Shard + 100x Iron Ingot; identical in every zone.
S.Data.TradeMaterialFragment = { {2, 100}, {69, 70} }

-- ArcheRage "Blue Salt Brotherhood transport" packs (蓝盐商会运输品<zone>).
-- Verified against the official ArcheRage wiki craft DB (e.g. crafts 11043/11035/
-- 11042/11044): 1x Blue Salt Bond + 1x Small Root Pigment + 1x Small Seed Oil +
-- 1x Opaque Polish; identical in every zone.
S.Data.TradeMaterialTransport = { {1, 1, 1, 1}, {71, 72, 73, 74} }
