# Local verification results

Results below were reproduced from the working tree on **2026-08-15**. The
systolic, convolution, APB3, APB-to-systolic demo, driver, and mapping results
are post-CV additions. Implementation paths are reported separately because
their passing tests do not establish cross-block equivalence or wider system
integration.

## Portable regression

Command:

```bash
make test
```

Result: **PASS**. This aggregate target ran the Python model, six RTL
testbenches, and the host-side C driver test described below.

### Python model

Equivalent individual command:

```bash
python3 -m unittest discover -s model/tests -v
```

Result: **10/10 tests passed**. Coverage includes descriptor packing and
validation, a known signed dot product, INT8 range rejection,
identity-residual boundaries, and channel counts 1, 7, 16, 31, and 256.

### Existing parallel SystemVerilog MAC

Command:

```bash
make rtl-mac-test
```

Result: **PASS** — three input vectors and 48 output accumulations, immediate
back-to-back output replacement, a four-cycle downstream stall with payload
stability checking, and asynchronous reset assertion.

### Output-stationary systolic GEMM

Commands:

```bash
make rtl-systolic-test
make rtl-systolic-n16-test
```

Results:

- N=4: **PASS** — mixed signed matrices, identity multiplication, and INT8
  sign-extension extremes; all 48 outputs checked across three cases; exact
  10-active-clock completion, repeated transactions, a start pulse while busy,
  and one-cycle done behavior checked.
- Default N=16: **PASS** — all 256 results of one fully populated,
  non-symmetric signed multiplication checked; exact 46-active-clock completion
  and one-cycle done behavior checked.

The N=4 RTL and testbench also compiled under Questa Intel FPGA Starter Edition
2021.2 with **0 errors and 0 warnings**. That compile result is not a separate
functional proof.

### Signed streaming 3x3 primitive

Command:

```bash
make rtl-convolution-test
```

Result: **PASS** — 84 signed input pixels produced 40 checked cropped 3x3
outputs across two consecutive 7 x 6 frames. The test used two signed kernels,
signed pixel extremes, biases, input bubbles, downstream stalls, propagated
input backpressure, and checked start-of-frame/end-of-line/end-of-frame markers.

The same test passed XSIM 2025.2, and the source/testbench compiled under Questa
with **0 errors and 0 warnings**. Stall-cycle totals can differ by simulator
scheduling; the acceptance criteria require and verify actual stall and
backpressure coverage rather than using those totals as a performance metric.

### Generic APB3 control block

Command:

```bash
make rtl-apb-test
```

Result: **PASS — 167 checks**. The test covers reset, APB setup/access phases,
zero-wait completion, register readback, all five 64-bit address pairs, valid
and invalid layer bounds, misaligned/unmapped/read-only/reserved/locked writes,
accepted and rejected starts, configuration freezing, sticky done/error,
interrupt enables and W1C causes, error priority/capture, and job counters.

This is evidence for the supplied generic peripheral, not for a bridge or VEGA
integration.

### APB-to-systolic control demo

Command:

```bash
make rtl-apb-systolic-demo-test
```

Result: **PASS — 112 checks**. APB launched two signed N=4 matrix
multiplications. The test checks every output and three distinct timing
boundaries for both jobs:

- raw GEMM busy to raw done: **10 clocks**;
- accepted APB `CONTROL` access to raw done: **11 clocks**; and
- accepted APB `CONTROL` access to sticky done/IRQ: **12 clocks**.

It also checks matrix input capture, APB busy/non-idle status, rejection and
non-counting of a second start while busy, start/completion counters, W1C
acknowledgment, and a second job after restart.

The wrapper's default N=16 configuration also elaborates cleanly. The
integration simulation deliberately uses N=4 so the control and 10-clock
wavefront timing remain compact and inspectable.

This demo connects `dcse_apb3_ctrl` start/status to `systolic_gemm`, but A and B
remain direct packed inputs and C remains a direct packed output. The APB buffer
addresses and layer index are retained as readable control state but are not
consumed. The result therefore proves a narrow job-control loop, not memory
movement, AXI/AHB/DMA, cache behavior, CDC, VEGA integration, or a complete
accelerator system.

Vivado 2025.2 compiled/elaborated the demo source cleanly. Its local XSIM
runtime launcher failed before simulation because of the simulator environment,
so no XSIM functional pass is claimed; the reported functional result is the
Icarus run above.

### Portable C register driver

Command used by `make software-test`:

```bash
cc -std=c11 -pedantic -Wall -Wextra -Werror -Isoftware \
  software/dcse_apb3.c tests/software/test_dcse_apb3.c \
  -o build/test_dcse_apb3
build/test_dcse_apb3
```

Result: **PASS — 66 mock-MMIO checks**. The test verifies exact relative
offsets, attach/input validation, identification/status helpers, low/high
halves of all five 64-bit buffer addresses, layer bounds, busy rejection,
interrupt-mask filtering, W1C writes, and start eligibility.

The host mock cannot establish behavior of real volatile MMIO, RISC-V hardware
fences, caches, physical addressing, PLIC routing, platform bus errors, or
concurrent callers.

## HLS C simulation

Tool: **Vitis HLS 2025.2, build 6295257**

```bash
HLS_CSIM_ONLY=1 vitis-run --mode hls --tcl run_hls.tcl
```

Result: **C simulation completed with 0 errors**. Six valid arithmetic cases
and four invalid-configuration cases passed. The scoreboard checked all 4,096
outputs for every valid tile.

A bounded HLS C-synthesis attempt was stopped during compilation after the
source expanded into a large intermediate representation. It produced no
`csynth` report. Therefore there is no HLS claim for achieved II, latency,
resources, AXI throughput, or timing.

## Open-source Xilinx 7-series mapping

Tool: **Yosys 0.33, git revision 2584903a060**

```bash
make synth-xc7
```

Result: **PASS** for all three new RTL tops using
`synth_xilinx -family xc7 -noiopad`.

| Standalone top / default configuration | DSP48E1 | Flip-flops | LUT primitives | Estimated logic cells |
| --- | ---: | ---: | ---: | ---: |
| `systolic_gemm`, N=16 | 256 | 8,712 | 4,674 | 4,348 |
| `signed_int8_conv3x3`, 16 x 16 frame | 9 | 348 | 115 | 107 |
| `dcse_apb3_ctrl` | 0 | 404 | 252 | 214 |

Flip-flop and LUT totals sum the primitive variants printed by Yosys. They are
structural mapping estimates, not exact Genesys 2 utilization. No I/O pads,
placement, routing, timing, power, or board behavior is part of this flow. The
full interpretation and feeder before/after comparison are in
[Genesys 2 mapping notes](genesys2_mapping.md).

## Exact Genesys 2 implementation attempt

[`scripts/run_vivado_ooc.tcl`](../scripts/run_vivado_ooc.tcl) targets the
Genesys 2 device `xc7k325tffg900-2` and a 6.667 ns (150 MHz) clock. A local
Vivado 2025.2 out-of-context attempt on the convolution top stopped at
`synth_design` with license error **Common 17-345**: no valid license was
available for the Kintex-7 XC7K325T device.

This is an environment blocker, not a timing failure and not a passing
synthesis. No exact-part synthesis netlist, utilization, placement, routing,
slack, Fmax, DRC, methodology, power, or checkpoint result was produced. Those
metrics must remain unclaimed until the same flow completes with an appropriate
device license.

## Evidence boundary

The current evidence supports these statements:

- the HLS pointwise/residual arithmetic passes C simulation;
- each standalone RTL primitive passes its supplied self-checking simulation;
- the generic APB register contract and matching portable C access sequence
  pass their supplied tests;
- the narrow APB-to-systolic demo passes two direct-port job/control flows; and
- the three new RTL tops structurally map to Xilinx 7-series primitives in
  Yosys.

It does **not** prove that all blocks are connected or equivalent, part of a
complete detector, integrated with VEGA, timing-closed on Genesys 2, or
measured on a board.
