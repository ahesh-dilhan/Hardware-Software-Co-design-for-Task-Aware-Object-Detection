# Verification matrix

This matrix keeps the HLS kernel, the portable Python specification, and the
standalone 16-input SystemVerilog MAC slice distinct. Passing one of these paths
does not by itself prove equivalence of the other two.

Status meanings: **checked** = exercised by a named passing current test;
**partial** = evidence covers only part of the stated requirement; **gap** = no
executable evidence is published yet.

| Requirement or invariant | Current evidence | Status | Remaining gap / acceptance criterion |
|---|---|---:|---|
| Descriptor fields pack/unpack as four unsigned 16-bit fields in one 64-bit word. | Round-trip unit test in [`model/tests/test_dcse_model.py`](../model/tests/test_dcse_model.py). | **checked** | Cross-check packed words with generated HLS control/software artifacts when those exist. |
| The software contract accepts 16 outputs, 1..256 inputs, and only documented mode IDs. | Python positive/negative descriptor tests include zero channels, 257 channels, unsupported output width, and an unknown mode. | **checked** | Decide and test the reserved kernel-size field policy; hardware still ignores output-channel/kernel-size fields. |
| Pointwise arithmetic is signed INT8 x INT8, INT16-biased, and accumulated/stored as INT32. | Known Python dot-product test; Vitis HLS 2025.2 C simulation passed the deterministic C golden loop and all-output scoreboard. | **checked** | Cross-feed shared vectors from the Python oracle and run C/RTL co-simulation. |
| Identity residual is added only when `oc < input_channels`; missing identity channels contribute zero. | Python residual-boundary test; HLS C cases at 7 and 31 channels; standalone RTL test drives absent residual lanes to zero. | **partial** | Run HLS C/RTL co-simulation and prove the wrapper/sign-extension contract between the INT8 HLS identity and INT32 RTL residual port. |
| HLS arithmetic handles input-channel cases 1, 7, 16, 31, and 256. | Vitis HLS 2025.2 C simulation passed every directed all-output case. | **checked** | Run C/RTL co-simulation; add signed extrema and repeated-call vectors shared with Python. |
| Invalid table index, input-channel count, or mode ID produces deterministic zero output without reading an out-of-range descriptor. | Vitis HLS 2025.2 C simulation passed cases for 0, 257, type 99, and index 35. | **checked** | C/RTL co-simulate; add an error status and validate caller-provided memory addresses. Hardware still ignores output-channel/kernel-size fields. |
| Mode ID 0 does not masquerade as implemented spatial 3x3 convolution. | Source names it `SPATIAL3x3_RESERVED`; docs and HLS test identify its current pointwise behavior. | **partial** | Implement nine spatial taps plus window/border behavior, or reject the reserved ID in hardware. |
| The standalone 16-input/16-output RTL MAC computes all lanes correctly. | Three directed vectors and 48 output comparisons in [`sim/tb_int8_mac_tile_16x16.sv`](../sim/tb_int8_mac_tile_16x16.sv). | **checked** | Add randomized/extreme/overflow vectors and a shared Python-generated vector file. |
| Standalone RTL ready/valid supports back-to-back replacement, holds output under stall, and clears on reset. | Directed back-to-back, four-cycle stall, stability, ready, and asynchronous-reset checks in the RTL testbench. | **checked** | Add arbitrary-stall assertions/formal proof and synchronised reset-release integration checks. |
| The standalone RTL slice composes into the 1..256-channel HLS kernel. | Relationship and residual wrapper obligation are documented in RTL comments. | **gap** | Build the multi-chunk accumulator/wrapper and prove equivalence against `dcse_top` for every supported channel count. |
| HLS pragmas generate five intended AXI4 masters plus correct AXI4-Lite control/registers. | Interface pragmas exist in [`src/dcse_top.cpp`](../src/dcse_top.cpp). | **gap** | Generate/package RTL, record register offsets, and run AXI protocol tests with READY stalls, responses, and address faults. |
| Requested pipelining/channel unrolling, II, latency, resource use, and 150 MHz timing are achieved. | Source pragmas and a clock constraint exist, but the bounded synthesis attempt did not complete and no report is committed. | **gap** | Add explicit local buffering/tiling, complete synthesis/implementation for `xc7k325tffg900-2`, and archive reports with tool and commit versions. |
| Full YOLO/object-detection inference is numerically correct and faster than software. | Explicitly outside the current kernel scope. | **gap** | Add exported model/quantization metadata, supported-layer graph, activation/requantization, detection head/NMS, accuracy comparison, and transfer-inclusive latency. |
| VEGA/RISC-V, APB/bridge, DMA, CDC, cache coherency, interrupt, and fault handling are correct. | Interface questions and planned contract are documented; no integration is claimed. | **gap** | Add a concrete SoC tree, address map, firmware, assertions/tests, and board traces. |
| Functional/code/branch/toggle coverage and formal/security properties meet stated targets. | No coverage or formal report is published. | **gap** | Define requirements, add assertions/fault cases, and archive reproducible coverage/formal results. |

Portable regression command: `make test`; it runs the Python model tests and
the standalone RTL slice simulation. Run `make hls-csim` separately where
Vitis HLS is installed. These checks do not establish HLS synthesis, AXI
correctness, HLS-to-RTL equivalence, full detector behavior, processor
integration, or board performance.
