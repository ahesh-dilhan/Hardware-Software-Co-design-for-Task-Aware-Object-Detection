# Design-review walkthrough

This walkthrough gives a reviewer a reproducible **5–10 minute** path through
the repository. Its purpose is to connect each architectural statement to
source, tests, and the correct evidence boundary.

## 1. Establish the chronology and scope

Start with the [README scope table](../README.md) and Git history. The HLS
pointwise/residual path and older non-systolic MAC are distinct from the
systolic, convolution, APB3, driver, and mapping work added on 2026-08-15 after
the preceding CV/application snapshot. That update also includes one narrow
wrapper connecting APB job control to direct-port systolic GEMM.

The single most important scope statement is:

> These are simulation-checked standalone architecture slices, not an integrated object
> detector or VEGA/Genesys 2 system.

## 2. Reproduce the functional evidence

```bash
make test
```

Expected summary:

| Test path | Expected passing evidence |
| --- | --- |
| Python model | 10 tests |
| Parallel MAC RTL | 3 vectors, 48 outputs |
| Systolic RTL, N=4 | 3 cases, 48 outputs, 10 active clocks per job |
| Systolic RTL, N=16 | 256 outputs, 46 active clocks |
| Signed 3x3 RTL | 84 input pixels, 40 outputs across two frames |
| APB3 RTL | 167 checks |
| APB-to-systolic demo | 112 checks, two N=4 jobs; 10/11/12-clock raw/control/sticky boundaries |
| Portable C driver | 66 checks |

The testbench is part of the design evidence: identify the oracle, enumerate
which outputs are compared, and point out explicit protocol/latency checks.

## 3. Review the original HLS path

Open [`src/dcse_top.cpp`](../src/dcse_top.cpp) and
[`docs/architecture.md`](architecture.md#3-existing-hls-computation).

Verify these facts:

- weights have shape `[16][256]`, so the datapath is pointwise across input
  channels;
- the output has 16 channels and uses INT32 accumulation;
- identity residual is conditional on output-channel availability;
- the descriptor mode named `SPATIAL3x3_RESERVED` does not select nine spatial
  taps; and
- AXI pragmas request interfaces, but generated-RTL behavior and synthesis
  metrics require generated reports.

Then open [`rtl/int8_mac_tile_16x16.sv`](../rtl/int8_mac_tile_16x16.sv). It is a
parallel 16-input-by-16-output dot-product slice with ready/valid output, not a
systolic array and not a complete RTL replacement for the HLS kernel.

## 4. Review why the new GEMM is systolic

Open [`rtl/systolic/systolic_gemm.sv`](../rtl/systolic/systolic_gemm.sv).

Trace one element `A[row][k]`:

1. the row feeder presents it at the west boundary at schedule step `row+k`;
2. each PE registers and forwards it one column east; and
3. it reaches PE `[row][col]` at `row+col+k`.

Trace `B[k][col]` analogously from north to south. The two valid operands meet
at the same PE/clock, where the product is added to that PE's stationary
accumulator. This explicit registered hop structure—not merely parallel
multiplication—is what supports the word “systolic.”

The last wavefront product occurs at the documented `3*N-2` completion edge.
The N=4 test makes timing easy to inspect; the N=16 smoke test confirms the
default configuration and all 256 output values.

Also inspect the fixed-head row/column shift feeders. The
[mapping comparison](genesys2_mapping.md#systolic-feeder-optimization) records
why they replaced cycle-indexed word selection and quantifies the structural
LUT reduction without claiming post-route timing.

## 5. Review the spatial 3x3 primitive

Open
[`rtl/convolution/signed_int8_conv3x3.sv`](../rtl/convolution/signed_int8_conv3x3.sv)
and its [testbench](../sim/convolution/tb_signed_int8_conv3x3.sv).

Check the operation carefully:

```text
bias + sum(window[tap] * coefficient[tap]), tap = 0..8
```

It is CNN cross-correlation, so the kernel is not flipped. Two line delays and
horizontal registers form the window. There is no padding, so W x H becomes
`(W-2) x (H-2)`. Nine parallel multipliers implement one input/output-channel
window; multi-channel reduction is not present.

The ready equation permits output consumption and replacement on one edge. If
the output is blocked, input readiness drops and all window state freezes. The
testbench verifies that the held payload does not change and that input
backpressure propagates.

## 6. Review the control/software boundary

Open [`rtl/integration/dcse_apb3_ctrl.sv`](../rtl/integration/dcse_apb3_ctrl.sv),
[`software/dcse_apb3.h`](../software/dcse_apb3.h), and
[`docs/vega_integration.md`](vega_integration.md).

Follow one job:

1. software writes low/high halves of five 64-bit addresses;
2. software writes a layer index;
3. an accepted `CONTROL.START` creates one `job_start` pulse and locks the
   configuration while busy;
4. terminal done/error creates a sticky cause and optional IRQ; and
5. software reads status/error and acknowledges causes with W1C writes.

Then identify the deliberate boundary: this APB block is neither an AXI/APB
bridge nor a wrapper around generated HLS RTL. The portable driver uses a
symbolic base and compiler barriers; a concrete port still needs a physical
address, hardware fence/cache policy, PLIC configuration, CDC/reset treatment,
and real bus-fault behavior.

Next open
[`rtl/integration/dcse_apb_systolic_demo.sv`](../rtl/integration/dcse_apb_systolic_demo.sv)
and its
[`testbench`](../sim/integration/tb_dcse_apb_systolic_demo.sv). This wrapper
closes only the start/busy/done/IRQ loop between APB and GEMM. The test launches
two N=4 jobs and checks all results plus 112 control/data conditions. Its three
timing boundaries are 10 clocks from raw busy to raw done, 11 from accepted APB
`CONTROL` access to raw done, and 12 from that access to sticky done/IRQ. The
matrices/results remain direct packed ports; programmed APB addresses and the
layer index are not consumed. Default N=16 elaborates, but the integration
simulation is N=4.

## 7. Reproduce and interpret structural mapping

```bash
make synth-xc7
```

Confirm that the N=16 systolic core infers 256 DSP48E1 cells, convolution
infers nine, and APB3 infers none. Treat the remaining Yosys counts as
family-level structural estimates.

Do not convert this result into a 150 MHz or routed-utilization claim. The
exact-part Vivado script targets `xc7k325tffg900-2`, but the recorded local run
stopped at the device-license check. The correct conclusion is “open-source
Xilinx-7 mapping passed; exact Genesys 2 synthesis/place/route/timing remains
unverified.”

## 8. Claim audit

| Statement | Evidence status |
| --- | --- |
| HLS pointwise/residual kernel passes C simulation | Supported |
| Separate parallel RTL MAC passes ready/valid simulation | Supported |
| Standalone output-stationary systolic GEMM exists and passes N=4/N=16 tests | Supported as post-CV work |
| Standalone signed cropped 3x3 spatial primitive exists and passes stream tests | Supported as post-CV work |
| Generic APB3 peripheral and matching portable register API pass supplied tests | Supported as post-CV work |
| APB can launch the systolic core and report completion in the direct-port demo | Supported as narrow post-CV work |
| New RTL maps to Xilinx 7-series DSP/LUT/FF primitives in Yosys | Supported as structural evidence |
| Complete object detector is implemented | Not supported |
| HLS kernel now performs spatial 3x3 | Not supported |
| Systolic/3x3 blocks are connected to HLS or memory | Not supported |
| APB3 block is integrated with VEGA | Not supported |
| Design meets 150 MHz or is optimized/validated on Genesys 2 | Not yet supported by exact-part implementation |

End the review by selecting one open boundary—wrapper composition, exact VEGA
interconnect, licensed implementation, or detector-level dataflow—and turning
it into the next measurable milestone rather than widening the current claim.
