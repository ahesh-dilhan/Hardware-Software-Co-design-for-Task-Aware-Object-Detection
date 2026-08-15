# Local verification results

Results below were produced from the repository-hardening working tree on
2026-08-15. They are deliberately separated by implementation path.

## Portable Python model

Command:

```bash
python3 -m unittest discover -s model/tests -v
```

Result: **10/10 tests passed**. These tests cover descriptor packing and
validation, a known signed dot product, INT8 range rejection, identity-residual
boundaries, and channel counts 1, 7, 16, 31, and 256.

## Standalone SystemVerilog slice

Icarus Verilog 12 compiled and ran:

```bash
make rtl-test
```

Result: **PASS** — 3 input vectors, 48 output accumulations, immediate
back-to-back replacement, a four-cycle downstream stall with output-stability
checking, and asynchronous reset assertion.

Questa Intel FPGA Starter Edition 2021.2 also compiled the RTL and testbench
with **0 errors and 0 warnings**. A Questa simulation result is not claimed
because no local simulator license was available.

## HLS C simulation

Tool: **Vitis HLS 2025.2, build 6295257**

```bash
HLS_CSIM_ONLY=1 vitis-run --mode hls --tcl run_hls.tcl
```

Result: **CSim completed with 0 errors**. Six valid arithmetic cases and four
invalid-configuration cases passed, checking 4,096 outputs per valid case.

## What did not complete

A bounded C-synthesis attempt was stopped during compilation after the design
expanded into a large intermediate representation. No `csynth` report was
produced. Therefore this revision makes no claim for achieved II, latency,
DSP/LUT/FF/BRAM utilization, Fmax, timing closure, AXI throughput, or board
performance. The result points to the next architectural task: introduce
explicit local input/weight buffering and channel tiling before applying broad
unrolling.

The Python model, standalone RTL slice, and HLS kernel have related arithmetic
but different interfaces and scopes. These passing results are not an
equivalence proof between them.
