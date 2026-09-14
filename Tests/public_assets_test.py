"""Keep documentation PNGs free of unnecessary identifying metadata."""
import pathlib
import struct
import unittest
import zlib


class PublicAssetsTests(unittest.TestCase):
    def test_documentation_pngs_have_valid_chunks_without_private_metadata(self):
        images = pathlib.Path(__file__).resolve().parents[1] / "docs" / "images"
        paths = list(images.glob("*.png"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(image=path.name):
                data = path.read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                offset = 8
                kind = None
                while offset < len(data):
                    length = struct.unpack(">I", data[offset:offset + 4])[0]
                    kind = data[offset + 4:offset + 8]
                    end = offset + 8 + length
                    self.assertLessEqual(end + 4, len(data))
                    self.assertEqual(zlib.crc32(data[offset + 4:end]),
                                     struct.unpack(">I", data[end:end + 4])[0])
                    self.assertNotIn(kind, {b"eXIf", b"iTXt", b"tEXt", b"zTXt", b"tIME"})
                    offset = end + 4
                self.assertEqual(kind, b"IEND")


if __name__ == "__main__":
    unittest.main()
