#!/usr/bin/env python3
"""Rewrite a docker-save archive into the classic docker archive format.

Docker 29 exports an archive that carries both the docker `manifest.json` and an
OCI layout (`blobs/`, `index.json`, `oci-layout`). The OCI index names every
platform's manifest, while only the pulled platform's blobs are in the archive,
so containerd's importer follows the OCI side and fails with

    Error: content digest sha256:...: not found

on an archive whose docker side is perfectly complete. That is exactly what
happens when k0s imports the bundle's image archives on the target, and it fails
the install at the first step that matters.

This keeps exactly what `manifest.json` names and drops the rest, which is what
containerd reads without complaint.

    normalize-image-tar.py <in.tar> <out.tar>

Called by build-offline-bundle.sh for every archive it writes; runnable by hand
to repair an archive that was built before this existed.
"""

import json
import sys
import tarfile


def normalize(src, dst):
    with tarfile.open(src) as tar:
        names = set(tar.getnames())
        manifest = json.load(tar.extractfile("manifest.json"))

        keep = {"manifest.json", "repositories"}
        for entry in manifest:
            keep.add(entry["Config"])
            keep.update(entry.get("Layers", []))

        missing = sorted(ref for ref in keep if ref not in names and ref != "repositories")
        if missing:
            raise SystemExit(f"{src}: manifest names {len(missing)} entries the archive lacks, e.g. {missing[:3]}")

        dropped = 0
        with tarfile.open(dst, "w") as out:
            for member in tar.getmembers():
                if member.name in keep:
                    out.addfile(member, tar.extractfile(member) if member.isfile() else None)
                else:
                    dropped += 1

        print(f"{dst}: kept {len(keep)} entries, dropped {dropped}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    normalize(sys.argv[1], sys.argv[2])
