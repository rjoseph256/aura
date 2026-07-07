import unittest
from build_gems import (CATEGORIES, BBOX, validate, to_gem, haversine_m)

def row(**kw):
    base = dict(slug="a-b", name="A B", category="park", tier="2",
                why="A place.", photo="", attribution="", lat="40.44", lon="-80.00", query="A B, Pittsburgh")
    base.update(kw); return base

class ValidateTests(unittest.TestCase):
    def test_clean_rows_have_no_errors(self):
        self.assertEqual([e for e in validate([row()]) if not e.startswith("WARN:")], [])

    def test_bad_slug_charset_is_error(self):
        self.assertTrue(any("slug" in e for e in validate([row(slug="Bad Slug")])))

    def test_duplicate_slug_is_error(self):
        self.assertTrue(any("duplicate" in e.lower() for e in validate([row(slug="x"), row(slug="x")])))

    def test_unknown_category_is_error(self):
        self.assertTrue(any("category" in e for e in validate([row(category="beach")])))

    def test_bad_tier_is_error(self):
        self.assertTrue(any("tier" in e for e in validate([row(tier="4")])))

    def test_out_of_bbox_is_error(self):
        self.assertTrue(any("bbox" in e.lower() for e in validate([row(lat="41.9", lon="-87.6")])))

    def test_empty_why_is_error(self):
        self.assertTrue(any("why" in e for e in validate([row(why="")])))

    def test_embedded_tab_is_error(self):
        self.assertTrue(any("tab" in e.lower() or "newline" in e.lower() for e in validate([row(why="a\tb")])))

    def test_photo_without_attribution_is_error(self):
        self.assertTrue(any("attribution" in e for e in validate([row(photo="gem-a-b", attribution="")])))

    def test_photo_name_must_match_gem_slug(self):
        self.assertTrue(any("gem-" in e for e in validate([row(photo="wrong", attribution="PD")])))

    def test_tier3_within_1500m_is_error(self):
        r1 = row(slug="t1", tier="3", lat="40.4400", lon="-80.0000")
        r2 = row(slug="t2", tier="3", lat="40.4410", lon="-80.0000")  # ~111m apart
        self.assertTrue(any("1.5" in e or "1500" in e for e in validate([r1, r2])))

    def test_25m_proximity_is_warning_not_error(self):
        r1 = row(slug="p1", lat="40.44000", lon="-80.00000")
        r2 = row(slug="p2", lat="40.44010", lon="-80.00000")  # ~11m apart
        errs = validate([r1, r2])
        self.assertTrue(any(e.startswith("WARN:") for e in errs))
        self.assertEqual([e for e in errs if not e.startswith("WARN:")], [])

class ToGemTests(unittest.TestCase):
    def test_emits_expected_shape(self):
        g = to_gem(row(slug="the-point", category="water", tier="2", why="Where the rivers meet."))
        self.assertEqual(g["id"], "curated:the-point")
        self.assertEqual(g["source"], "curated")
        self.assertEqual(g["tier"], 2)
        self.assertEqual(g["coordinate"], {"latitude": 40.44, "longitude": -80.00})
        self.assertIsNone(g["photoAsset"])
        self.assertIsNone(g["photoAttribution"])

    def test_public_domain_collapses_to_null_attribution(self):
        g = to_gem(row(slug="a-b", photo="gem-a-b", attribution="PD"))
        self.assertEqual(g["photoAsset"], "gem-a-b")
        self.assertIsNone(g["photoAttribution"])

    def test_credited_photo_keeps_attribution(self):
        g = to_gem(row(slug="a-b", photo="gem-a-b", attribution="Jane, CC BY 4.0"))
        self.assertEqual(g["photoAttribution"], "Jane, CC BY 4.0")

    def test_strings_are_nfc_normalized_for_determinism(self):
        # Decomposed "e" + combining acute (NFD) must serialize as composed "é" (NFC).
        g = to_gem(row(name="Café", why="A café stop."))
        self.assertEqual(g["name"], "Café")
        self.assertEqual(g["why"], "A café stop.")

class HaversineTests(unittest.TestCase):
    def test_known_distance(self):
        # ~111m per 0.001 deg latitude at this latitude.
        self.assertAlmostEqual(haversine_m(40.440, -80.0, 40.441, -80.0), 111, delta=3)

if __name__ == "__main__":
    unittest.main()
