## Decode actual shim fragments after each real child. No mocks. A successful
## exit comparison is insufficient if the early flush loses the file read.
import std/[os, strutils]
import io_mon/[types, writer]

doAssert paramCount() == 1
let folder = paramStr(1)
let merged = mergeFragments(folder, folder / "merged.iomon")
var reads = 0
for record in merged.records:
  if record.kind == mrFileRead and
      record.path.toLowerAscii.endsWith("shutdown-probe.txt"):
    inc reads
doAssert reads > 0, "the real marker read did not survive the early flush"
echo "shutdown marker reads retained: ", reads
