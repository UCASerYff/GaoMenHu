"""Verify the launcher and installer carry the same icon sizes as the release ICO."""

import argparse
import struct
from pathlib import Path

import pefile
from PIL import Image


def icon_groups(executable):
    with pefile.PE(str(executable)) as binary:
        resources = binary.DIRECTORY_ENTRY_RESOURCE.entries
        group_type = next((entry for entry in resources if entry.id == pefile.RESOURCE_TYPE["RT_GROUP_ICON"]), None)
        if group_type is None:
            return []
        groups = []
        for group in group_type.directory.entries:
            for language in group.directory.entries:
                resource = language.data.struct
                data = binary.get_data(resource.OffsetToData, resource.Size)
                reserved, icon_type, count = struct.unpack_from("<HHH", data)
                if reserved or icon_type != 1 or len(data) != 6 + count * 14:
                    raise ValueError(f"Invalid RT_GROUP_ICON in {executable.name}")
                groups.append({(data[offset] or 256, data[offset + 1] or 256) for offset in range(6, len(data), 14)})
        return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ico", type=Path)
    parser.add_argument("executables", type=Path, nargs="+")
    args = parser.parse_args()
    with Image.open(args.ico) as image:
        expected = image.ico.sizes()
    for executable in args.executables:
        if not any(expected <= group for group in icon_groups(executable)):
            raise SystemExit(f"{executable.name} has no icon group with the complete release ICO size set: {sorted(expected)}")
        print(f"{executable.name}: {len(expected)} embedded icon sizes verified")


if __name__ == "__main__":
    main()
