#!/usr/bin/env python3
"""Stage a verified gVisor copy and a Go modfile with the audited UDP adjustment."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


GVISOR_MODULE = "gvisor.dev/gvisor@v0.0.0-20260401053414-479e1cc2c3d9"
UDP_ENDPOINT = "pkg/tcpip/transport/udp/endpoint.go"
ENDPOINT_SHA256 = "fcdd574274ec973e412a4243e3c306d3863239cc6f2bee663d24d82d58f385d7"
# Charge fixed metadata to bound zero-length as well as nonempty datagrams.
# Charge/decharge must remain symmetric, including peek and close paths.
REPLACEMENTS = (
    (
        "// endpoint represents a UDP endpoint.",
        "// MacDPIQueuedDatagramOverhead charges memory even for empty datagrams.\n"
        "const MacDPIQueuedDatagramOverhead = 256\n\n"
        "// endpoint represents a UDP endpoint.",
    ),
    (
        "e.rcvBufSize -= p.pkt.Data().Size()",
        "e.rcvBufSize -= p.pkt.Data().Size() + MacDPIQueuedDatagramOverhead",
    ),
    (
        "if e.frozen || e.rcvBufSize >= int(rcvBufSize) {",
        "queuedBytes := pkt.Data().Size() + MacDPIQueuedDatagramOverhead\n"
        "\tif e.frozen || queuedBytes > int(rcvBufSize)-e.rcvBufSize {",
    ),
    ("e.rcvBufSize += pkt.Data().Size()", "e.rcvBufSize += queuedBytes"),
)


def prepare(cache: Path, output: Path) -> None:
    module = (cache / GVISOR_MODULE).resolve()
    source = module / UDP_ENDPOINT
    original = source.read_bytes()
    if hashlib.sha256(original).hexdigest() != ENDPOINT_SHA256:
        raise SystemExit("gVisor UDP source hash does not match the reviewed version")
    text = original.decode()
    for old, new in REPLACEMENTS:
        if text.count(old) != 1:
            raise SystemExit("gVisor UDP source is missing a unique reviewed patch location")
        text = text.replace(old, new)
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="gvisor-", dir=output))
    module_copy = stage / "source"
    shutil.copytree(module, module_copy, copy_function=shutil.copyfile)
    for directory, _, _ in os.walk(module_copy):
        Path(directory).chmod(0o755)
    modified = module_copy / UDP_ENDPOINT
    modified.write_text("// Modified by MacDPI to account for per-datagram queue memory.\n" + text)
    worker = Path(__file__).resolve().parent
    module_file = stage / "worker.mod"
    module_file.write_text(
        (worker / "go.mod").read_text() + f"\nreplace gvisor.dev/gvisor => {json.dumps(str(module_copy))}\n"
    )
    shutil.copyfile(worker / "go.sum", stage / "worker.sum")
    print(module_file)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module_cache", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    prepare(args.module_cache, args.output_directory)
