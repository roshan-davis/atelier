# PR #153: Fast vs Hair Detail Fine Edges (measured at dd9fd44)

Each crop shows three columns: **Vision** (no Fine Edges), **Fast** (BiRefNet lite), and **Hair Detail** (BiRefNet HR matting).
- Top row: the Select Subject matte (feather 3, as Lens Blur's Refine makes it).
- Bottom row: the Lens Blur Save (Amount 100, with that Select Subject as the Focus area).

All crops are at 100% (192 px for the 1376 px JPEGs, 256 px for Z62_0193.NEF). Each crop sits where Hair Detail differs most from Fast and from Vision.

Method: a debug build, one variant per process, under `nice -n 10`, while Rosh was using the Mac. The sandbox HOME (`CFFIXED_USER_HOME`) held only the model under test.
- `FineEdgesFastModelTests.swift.txt` is the opt-in test.
- `local-test-hook.diff` adds a `fineEdges:` parameter to `subjectMask`. It is test-only and not in the PR.
- `results.txt` holds the raw lines.
