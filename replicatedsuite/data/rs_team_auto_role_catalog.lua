------------------------------------------------------------------------
-- Replicated Suite V3 - Team Auto Role Catalog
--
-- Migrated from the project's preserved ArcheRage classmappings baseline and
-- the already-proven TeamUtility Vitalism+Dancer correction. Exact class-key
-- lookup only; no fuzzy class-name inference in the runtime hot path.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.Data=S.Data or {}
local C={ version=2, byClassKey={} }
C.byClassKey["name_3_4_5"]={role="tank", classType="Tank"}
C.byClassKey["name_2_3_4"]={role="tank", classType="Tank"}
C.byClassKey["name_3_5_8"]={role="tank", classType="Tank"}
C.byClassKey["name_2_4_5"]={role="tank", classType="Tank"}
C.byClassKey["name_4_5_9"]={role="tank", classType="Tank"}
C.byClassKey["name_1_5_8"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_5_9"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_3_5"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_4_5"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_3_8"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_8_9"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_3_4"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_4_8"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_4_9"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_2_8"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_2_9"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_10_14"]={role="dealer", classType="Melee"}
C.byClassKey["name_1_8_12"]={role="dealer", classType="Swiftblade"}
C.byClassKey["name_1_5_12"]={role="dealer", classType="Swiftblade"}
C.byClassKey["name_1_9_12"]={role="dealer", classType="Swiftblade"}
C.byClassKey["name_7_8_11"]={role="none", classType="Malediction"}
C.byClassKey["name_2_7_11"]={role="none", classType="Malediction"}
C.byClassKey["name_4_8_11"]={role="none", classType="Malediction"}
C.byClassKey["name_7_9_11"]={role="none", classType="Malediction"}
C.byClassKey["name_8_9_11"]={role="none", classType="Malediction"}
C.byClassKey["name_5_9_11"]={role="none", classType="Malediction"}
C.byClassKey["name_4_9_11"]={role="none", classType="Malediction"}
C.byClassKey["name_4_7_9"]={role="none", classType="Mage"}
C.byClassKey["name_7_8_9"]={role="none", classType="Mage"}
C.byClassKey["name_4_7_8"]={role="none", classType="Mage"}
C.byClassKey["name_4_7_11"]={role="none", classType="Mage"}
C.byClassKey["name_3_4_7"]={role="none", classType="Mage"}
C.byClassKey["name_2_7_8"]={role="none", classType="Mage"}
C.byClassKey["name_2_4_7"]={role="none", classType="Mage"}
C.byClassKey["name_4_5_7"]={role="none", classType="Mage"}
C.byClassKey["name_2_5_7"]={role="none", classType="Mage"}
C.byClassKey["name_7_9_14"]={role="none", classType="Mage"}
C.byClassKey["name_6_8_9"]={role="ranged", classType="Archer"}
C.byClassKey["name_6_9_10"]={role="ranged", classType="Archer"}
C.byClassKey["name_2_6_9"]={role="ranged", classType="Archer"}
C.byClassKey["name_3_6_8"]={role="ranged", classType="Archer"}
C.byClassKey["name_6_9_12"]={role="ranged", classType="Archer"}
C.byClassKey["name_4_6_8"]={role="ranged", classType="Archer"}
C.byClassKey["name_4_6_9"]={role="ranged", classType="Archer"}
C.byClassKey["name_4_6_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_6_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_6_9_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_4_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_6_8_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_6_13_14"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_10_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_4_8_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_5_6_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_8_9_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_4_9_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_9_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_5_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_9_13_14"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_8_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_1_3_13"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_13_14"]={role="ranged", classType="Gunner"}
C.byClassKey["name_3_4_9"]={role="tank", classType="Songer"}
C.byClassKey["name_2_3_9"]={role="tank", classType="Songer"}
C.byClassKey["name_2_4_9"]={role="tank", classType="Songer"}
C.byClassKey["name_3_6_9"]={role="tank", classType="Songer"}
C.byClassKey["name_4_8_9"]={role="tank", classType="Songer"}
C.byClassKey["name_4_9_14"]={role="tank", classType="Dancer"}
C.byClassKey["name_9_10_14"]={role="healer", classType="Dancer"}
C.byClassKey["name_8_10_14"]={role="healer", classType="Dancer"}
C.byClassKey["name_2_10_14"]={role="healer", classType="Dancer"}
C.byClassKey["name_3_4_14"]={role="tank", classType="Dancer"}
C.byClassKey["name_1_3_14"]={role="tank", classType="Dancer"}
C.byClassKey["name_8_9_14"]={role="tank", classType="Dancer"}
C.byClassKey["name_3_9_14"]={role="tank", classType="Dancer"}
C.byClassKey["name_3_10_14"]={role="healer", classType="Healer"}
C.byClassKey["name_3_8_10"]={role="healer", classType="Healer"}
C.byClassKey["name_2_8_10"]={role="healer", classType="Healer"}
C.byClassKey["name_4_8_10"]={role="healer", classType="Healer"}
C.byClassKey["name_5_8_10"]={role="healer", classType="Healer"}
C.byClassKey["name_2_9_10"]={role="healer", classType="Healer"}
C.byClassKey["name_8_9_10"]={role="healer", classType="Healer"}
C.byClassKey["name_3_9_10"]={role="healer", classType="Healer"}
C.byClassKey["name_4_9_10"]={role="healer", classType="Healer"}
C.byClassKey["name_2_5_10"]={role="healer", classType="Healer"}
C.byClassKey["name_2_3_10"]={role="healer", classType="Healer"}
C.byClassKey["name_2_4_10"]={role="healer", classType="Healer"}
S.Data.TeamAutoRoleCatalog=C
