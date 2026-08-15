# Verification matrix

This matrix keeps the HLS kernel, Python model, older parallel RTL MAC slice,
new standalone systolic and convolution cores, generic APB3/driver boundary,
and narrow APB-to-systolic demo distinct. Passing one path does not prove
equivalence or wider system integration.

Status meanings:

- **checked** — exercised by a named passing current test or reproducible
  structural check;
- **partial** — evidence establishes only part of the stated requirement; and
- **gap** — no executable evidence for the stated system requirement is
  published.

The HLS residual-path refactor, systolic, convolution, APB3,
APB-to-systolic demo, driver, and mapping additions are dated **2026-08-15**
and post-date the preceding CV/application snapshot.

| Requirement or invariant | Current evidence | Status | Remaining gap / acceptance criterion |
| --- | --- | ---: | --- |
| Descriptor fields pack/unpack as four unsigned 16-bit fields in one 64-bit word. | Round-trip unit test in [`model/tests/test_dcse_model.py`](../model/tests/test_dcse_model.py). | **checked** | Cross-check packed words with generated HLS/software artifacts when those exist. |
| The software descriptor contract accepts 16 outputs, 1..256 inputs, and only documented HLS mode IDs. | Python positive/negative descriptor tests include zero/257 channels, unsupported output width, and an unknown mode. | **checked** | Define and enforce the reserved kernel-size/output-channel field policy in hardware. |
| HLS pointwise arithmetic is signed INT8 x INT8, INT16-biased, and accumulated/stored as INT32. | Known Python dot product; Vitis HLS 2025.2 C simulation passed deterministic C golden-loop comparisons. | **checked** | Cross-feed shared vectors and run HLS C/RTL co-simulation. |
| HLS identity residual is added only when `oc < input_channels`. | Python residual-boundary test and HLS C cases at 7 and 31 channels. | **checked** | Co-simulate generated HLS RTL and verify any future RTL wrapper's sign/width contract. |
| Fusing the HLS residual and direct output preserves current C behavior while reducing compiler IR. | All six valid and four invalid CSim cases still pass; performance-stage IR fell from 93,503 to 45,929 (50.9%), and `Array/Struct` step 5 fell from 126,851 to 62,381. | **partial** | Complete `csynth` and compare achieved II, latency, storage, DSP/LUT/FF/BRAM, and clock estimate. IR counts are not hardware-resource results. |
| HLS arithmetic handles input-channel counts 1, 7, 16, 31, and 256. | Vitis HLS C simulation checked every one of 4,096 outputs for each directed case. | **checked** | Add shared signed-extreme/repeated-call vectors and C/RTL co-simulation. |
| Invalid HLS table index, channel count, or mode produces deterministic zero output without an out-of-range descriptor read. | HLS C simulation passed 0, 257, type 99, and index 35 cases. | **checked** | Add generated-RTL tests, error status, ignored-field checks, and caller-address validation. |
| HLS mode ID 0 does not masquerade as implemented spatial 3x3 convolution. | Source names it `SPATIAL3x3_RESERVED`; HLS tests and docs identify its current pointwise behavior. | **partial** | Reject the reserved ID in HLS or connect and prove a true spatial implementation. The standalone new RTL 3x3 block does not change HLS behavior. |
| The older parallel 16-input/16-output RTL MAC computes all lanes correctly. | Three directed vectors and 48 output comparisons in [`sim/tb_int8_mac_tile_16x16.sv`](../sim/tb_int8_mac_tile_16x16.sv). | **checked** | Add randomized overflow/extreme vectors and a shared Python-generated vector file. |
| Parallel MAC ready/valid supports back-to-back replacement, holds under stall, and clears on reset. | Directed back-to-back, four-cycle stall/stability, ready, and asynchronous-reset checks. | **checked** | Add arbitrary-stall assertions/formal proof and synchronized reset-release integration checks. |
| The parallel MAC composes into the 1..256-channel HLS kernel. | Relationship and wrapper obligations are documented. | **gap** | Build the channel-chunk accumulator/wrapper and prove equivalence against `dcse_top`. |
| Systolic GEMM uses registered neighbor-to-neighbor A/B movement with output-stationary accumulators. | RTL structure in [`rtl/systolic/systolic_gemm.sv`](../rtl/systolic/systolic_gemm.sv); N=4 and N=16 wavefront simulations complete only after the documented schedule. | **checked** | Add structural/formal properties for hop locality and valid alignment. |
| Systolic signed GEMM produces every expected output. | N=4 regression passes mixed signed, identity, and INT8-extreme cases (48 outputs total); N=16 smoke test compares all 256 outputs. | **checked** | Add randomized seeds, accumulator-boundary cases, non-default parameters, and shared vector files. |
| Systolic control accepts repeated jobs, ignores start while busy, pulses done once, and has fixed `3*N-2` active-clock latency. | N=4 test checks repeated jobs, busy-time start, and 10 clocks; N=16 test checks 46 clocks and one-cycle done. | **checked** | Add reset-during-job behavior and a streaming/tile-loading protocol before system use. |
| Systolic GEMM is integrated as detector convolution/matrix hardware. | The module is explicitly standalone. | **gap** | Define im2col or direct-convolution mapping, tiling, memory movement, bias/requantization, and end-to-end equivalence. |
| Standalone 3x3 RTL computes signed CNN cross-correlation with bias and cropped borders. | [`sim/convolution/tb_signed_int8_conv3x3.sv`](../sim/convolution/tb_signed_int8_conv3x3.sv) checks 84 signed pixels to 40 outputs over two 7 x 6 frames, two kernels, bias, and signed extremes. | **checked** | Add randomized frame sizes/configurations and explicit accumulator-overflow cases. |
| 3x3 stream propagates backpressure without loss and reports frame/line boundaries. | Test injects input bubbles and output stalls, checks frozen output payload, propagated input backpressure, SOF/EOL/EOF, and two consecutive frames. | **checked** | Add protocol assertions and reset/configuration-change fault cases. |
| 3x3 line storage and nine multipliers meet exact FPGA mapping/timing goals. | Xilinx-7 Yosys mapping infers nine DSP48E1 cells; no exact-part implementation completed. | **partial** | Complete licensed Genesys 2 placement/routing; verify line-memory inference and clock timing. |
| Standalone 3x3 RTL replaces HLS mode 0 and supports multi-channel detector tensors. | No HLS/wrapper connection exists. | **gap** | Add channel/output tiling, partial-sum storage, quantization stages, memory interfaces, and HLS/software equivalence tests. |
| APB3 block implements its intended zero-wait setup/access, error, register, job, sticky-status, counter, IRQ, and reset behavior. | [`sim/integration/tb_dcse_apb3_ctrl.sv`](../sim/integration/tb_dcse_apb3_ctrl.sv) passes 167 directed checks, including legal/illegal accesses and busy-time lockout. | **checked** | Add protocol assertions, randomized legal master sequences, and reset/status event race coverage. |
| Configuration remains stable during a job; accepted start is one cycle; error wins over simultaneous done. | Directed APB3 test checks all three rules plus accepted/rejected start counters. | **checked** | Verify the eventual accelerator wrapper respects the same-domain handshake and terminal-event assumptions. |
| APB job control can launch the systolic core and report its busy/completion/IRQ state with documented boundary latency. | [`sim/integration/tb_dcse_apb_systolic_demo.sv`](../sim/integration/tb_dcse_apb_systolic_demo.sv) passes 112 checks across two signed N=4 GEMMs: all outputs; 10 clocks raw busy-to-done, 11 accepted `CONTROL` access-to-raw-done, and 12 access-to-sticky-done/IRQ; captured inputs; busy-start rejection; status, counters, W1C, and restart. | **checked** | Add reset-during-job/event-race tests and prove the wrapper at other parameters; default N=16 currently elaborates but is not the integration simulation case. |
| APB-to-systolic demo moves matrices through programmed buffer addresses. | The wrapper explicitly uses direct packed A/B/C ports; its inherited address and layer registers are not consumed. | **gap** | Add an address generator and verified AXI/AHB memory path or DMA, then test bursts, errors, backpressure, cache policy, and physical addressing. |
| Portable C driver matches the relative register map and RV32 split-address sequence. | Strict C11 `-Wall -Wextra -Werror -pedantic` host build and 66 mock-MMIO checks in [`tests/software/test_dcse_apb3.c`](../tests/software/test_dcse_apb3.c). | **checked** | Cross-compile for the selected VEGA toolchain and test actual MMIO, fences, caches, interrupts, and bus faults. |
| APB3 peripheral is connected to generated HLS control and a concrete VEGA SoC. | Only a generic interface contract exists; no base address or platform tree is selected. | **gap** | Obtain the exact SoC tree, choose direct AXI4-Lite or a verified bridge/wrapper, allocate an address, connect PLIC/CDC/reset, and run software-to-hardware tests. |
| Tensor payloads use a high-bandwidth processor/accelerator memory path with correct cache/DMA behavior. | Requirement is documented; APB is intentionally control-only. | **gap** | Implement/arbitrate memory masters, define coherency and physical addressing, then test faults, backpressure, and transfer-inclusive latency. |
| New RTL maps to expected Xilinx 7-series primitive classes. | `make synth-xc7` completes with `synth_xilinx -family xc7 -noiopad`: N=16 systolic maps 256 DSP48E1, convolution maps 9 DSP48E1, and APB maps no DSP. | **checked** | Reproduce on CI/tool-version matrix and compare with licensed Vivado synthesis. |
| Exact Genesys 2 `xc7k325tffg900-2` fit, 150 MHz timing, routed resources, power, and Fmax are established. | A reproducible Vivado OOC script targets the exact part and 6.667 ns, but the local run stopped at synthesis because the installed tool had no valid device license. | **gap** | Complete synthesis, place, route, timing/DRC/methodology, and archive versioned reports. No timing/Fmax claim is currently valid. |
| HLS pragmas generate five intended AXI4 masters plus the expected AXI4-Lite controls. | Interface pragmas exist in [`src/dcse_top.cpp`](../src/dcse_top.cpp). | **gap** | Generate/package RTL, archive exact offsets, and run AXI protocol tests with stalls, error responses, address faults, and reset. |
| Full object-detection inference is numerically correct and faster than software. | Explicitly outside the current primitive scope. | **gap** | Add the versioned model/quantization metadata, supported graph, activation/requantization, detection head/NMS, accuracy comparison, and transfer-inclusive latency. |
| Functional/code/branch/toggle coverage and formal/security properties meet stated targets. | Directed tests exist; no coverage or formal report is published. | **gap** | Define targets, add assertions/fault injection/formal properties, and archive reproducible reports. |

Portable regression:

```bash
make test
```

This runs the 10-test Python model suite, the parallel MAC test, N=4 and N=16
systolic tests, the signed 3x3 test, the 167-check APB3 test, the 112-check
APB-to-systolic demo, and the 66-check C driver test. Run `make hls-csim`
separately where Vitis HLS is installed and `make synth-xc7` for structural
Xilinx-7 mapping.

These checks do not establish HLS synthesis, AXI correctness, cross-block
equivalence, exact-part timing, complete detector behavior, processor
integration, or board performance.
