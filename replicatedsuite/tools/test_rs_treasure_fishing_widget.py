from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


class TreasureFishingSurfaceContractTests(unittest.TestCase):
    def test_fishing_floating_widget_exposes_same_reversible_auto_r_commands(self):
        text = read("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
        block = text.split('featureName = "Fishing"', 1)[1]
        self.assertIn("buildControls = function", block)
        self.assertIn("Feature.Commands:ArmAuto()", block)
        self.assertIn("Feature.Commands:DisarmAuto()", block)
        self.assertIn('armed and "关闭自动 R"', block)
        self.assertIn('"自动 R 不可用"', block)

    def test_fishing_floating_toggle_does_not_fall_through_to_arm_when_disarm_fails(self):
        text = read("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
        block = text.split('featureName = "Fishing"', 1)[1]
        self.assertNotIn('armed and Feature.Commands:DisarmAuto() or Feature.Commands:ArmAuto()', block)
        self.assertIn('if armed then', block)

    def test_treasure_scan_uses_shared_inventory_authority_not_fixed_bag_zero_name_filter(self):
        text = read("features/life/rs_life_m16_bundle.lua")
        block = text.split("-- Treasure maps", 1)[1].split("-- Fishing", 1)[0]
        self.assertIn("InventorySnapshotV3", block)
        self.assertIn(':BuildSnapshot("bag"', block)
        self.assertIn("ReadPhysicalBagSlot", block)
        self.assertNotIn('GetBagItemInfo", 0, slot', block)
        self.assertNotIn('string.find(name, "藏宝图"', block)

    def test_treasure_map_key_keeps_legacy_coordinate_slot_shape_for_saved_selection_compatibility(self):
        text = read("features/life/rs_life_m16_bundle.lua")
        block = text.split("-- Treasure maps", 1)[1].split("-- Fishing", 1)[0]
        self.assertIn('key = text .. ":" .. tostring(slot)', block)
        self.assertNotIn('key = text .. ":" .. tostring(row and row.itemType', block)

    def test_treasure_feature_exposes_capability_gated_world_map_location_command(self):
        feature = read("features/life/rs_life_m16_bundle.lua")
        block = feature.split("-- Treasure maps", 1)[1].split("-- Fishing", 1)[0]
        self.assertIn("ShowSelectedOnMap", block)
        self.assertIn('Action("X2Map:ShowWorldmapLocation"', block)
        self.assertIn('"X2Map:ShowWorldmapLocation"', block)

        caps = read("core/rs_api_capabilities.lua")
        self.assertIn('["X2Map:ShowWorldmapLocation"]', caps)

        registry = read("features/rs_feature_registry.lua")
        treasure = registry.split('Add("life_treasure"', 1)[1].split('Add("life_fishing"', 1)[0]
        self.assertIn('"X2Map:ShowWorldmapLocation"', treasure)

    def test_treasure_floating_widget_has_explicit_map_location_action(self):
        text = read("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
        block = text.split('featureName = "Treasure"', 1)[1].split('featureName = "Fishing"', 1)[0]
        self.assertIn("buildControls = function", block)
        self.assertIn("Feature.Commands:ShowSelectedOnMap", block)
        self.assertIn('text = "地图定位"', block)

    def test_acceptance_requires_treasure_map_command_and_widget_contract_revision(self):
        text = read("presentation/v3/rs_v3_acceptance.lua")
        self.assertIn('"ShowSelectedOnMap"', text)
        self.assertIn("treasureMapLocationContractVersion", text)


if __name__ == "__main__":
    unittest.main()
