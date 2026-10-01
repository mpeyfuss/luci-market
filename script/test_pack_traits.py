import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pack_traits import TraitInputError, convert_csv


class PackTraitsTest(unittest.TestCase):
    def _convert(self, csv_text: str, batch_size: int = 250):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "traits.csv"
            path.write_text(csv_text, encoding="utf-8")
            return convert_csv(path, batch_size)

    def test_encodes_slots(self):
        result = self._convert("token_id,trait_0,trait_1,trait_2,trait_3\n1,5,12,,\n2,6,12,,\n")

        self.assertEqual(result["trait_config"], "0x00008080")
        self.assertEqual(result["batches"][0]["traits"], ["0x00008c85", "0x00008c86"])
        self.assertEqual(result["warnings"], [])

    def test_blank_slot_is_unset_and_warns_when_partial(self):
        result = self._convert("token_id,trait_0,trait_1,trait_2,trait_3\n1,5,,,\n2,,6,,\n")

        self.assertEqual(result["batches"][0]["traits"], ["0x00000085", "0x00008600"])
        self.assertEqual(len(result["warnings"]), 2)

    def test_batches(self):
        result = self._convert(
            "token_id,trait_0,trait_1,trait_2,trait_3\n1,1,,,\n2,2,,,\n3,3,,,\n", batch_size=2
        )

        self.assertEqual(len(result["batches"]), 2)
        self.assertEqual(result["batches"][0]["token_ids"], [1, 2])
        self.assertEqual(result["batches"][1]["token_ids"], [3])

    def test_rejects_duplicate_and_out_of_range_values(self):
        with self.assertRaises(TraitInputError):
            self._convert("token_id,trait_0,trait_1,trait_2,trait_3\n1,1,,,\n1,2,,,\n")
        with self.assertRaises(TraitInputError):
            self._convert("token_id,trait_0,trait_1,trait_2,trait_3\n1,64,,,\n")

    def test_rejects_wrong_header(self):
        with self.assertRaises(TraitInputError):
            self._convert("token,trait_0,trait_1,trait_2,trait_3\n1,1,,,\n")


if __name__ == "__main__":
    unittest.main()
