import unittest
from geocode import needs_geocode, merge_coords, geocode_query

class GeocodeTests(unittest.TestCase):
    def test_needs_geocode_detects_blank_coords(self):
        self.assertTrue(needs_geocode({"lat": "", "lon": ""}))
        self.assertFalse(needs_geocode({"lat": "40.44", "lon": "-80.0"}))

    def test_merge_fills_only_blank_rows(self):
        rows = [{"slug": "a", "query": "A", "lat": "", "lon": ""},
                {"slug": "b", "query": "B", "lat": "40.4", "lon": "-80.0"}]
        out = merge_coords(rows, {"A": (40.5, -80.1)})
        self.assertEqual((out[0]["lat"], out[0]["lon"]), ("40.5", "-80.1"))
        self.assertEqual((out[1]["lat"], out[1]["lon"]), ("40.4", "-80.0"))

    def test_geocode_query_is_cache_first(self):
        calls = []
        def fetch(q): calls.append(q); return (1.0, 2.0)
        cache = {"X": [3.0, 4.0]}
        self.assertEqual(geocode_query("X", cache, fetch), (3.0, 4.0))
        self.assertEqual(calls, [])  # served from cache, no fetch
        self.assertEqual(geocode_query("Y", cache, fetch), (1.0, 2.0))
        self.assertEqual(calls, ["Y"])

if __name__ == "__main__":
    unittest.main()
