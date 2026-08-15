# Genesys 2 mapping notes

## Purpose and evidence level

This document records two different implementation questions without conflating
them:

1. **Does the RTL structurally map to sensible Xilinx 7-series primitives?**
   The reproducible Yosys flow answers this at a family level.
2. **Does the design fit and meet 150 MHz after placement and routing on the
   exact Genesys 2 part?** The licensed Vivado flow must answer this; the local
   attempt could not pass the device-license check.

The systolic, convolution, APB3, APB-to-systolic demo, and mapping artifacts
were added on **2026-08-15**, after the preceding CV/application snapshot.

## Board target

The Digilent Genesys 2 uses a Kintex-7 **XC7K325T-2FFG900C**. The Vivado part
identifier used by the repository is `xc7k325tffg900-2`. The
[Genesys 2 Reference Manual](https://digilent.com/reference/_media/reference/programmable-logic/genesys-2/genesys2_rm.pdf)
lists 50,950 logic slices, 840 DSP slices, and approximately 16 Mbit of internal
block RAM for the device.

These board capacities are context, not proof of routed fit. In particular,
Yosys “estimated logic cells” are not the same unit as Kintex-7 slices, so this
document does not calculate a LUT/logic percentage from incompatible units.

## Reproducible open-source flow

Tool used: **Yosys 0.33, git revision 2584903a060**

```bash
make synth-xc7
```

The three scripts under [`scripts/yosys`](../scripts/yosys) read SystemVerilog,
select one standalone top, and run:

```text
synth_xilinx -family xc7 -noiopad
check
stat -tech xilinx
```

The design defaults used for the recorded results are N=16, signed 8-bit inputs
and signed 32-bit accumulators for the systolic core; a 16 x 16 frame with
signed 8-bit pixels/coefficients and signed 32-bit output for convolution; and
the default 8-bit relative APB address width.

The table reports the three leaf RTL tops. The APB-to-systolic demo has a
functional integration test but no separate Yosys script or combined mapping
result, so no demo-level utilization is inferred by adding leaf counts.

### Structural results

| Standalone top | DSP48E1 | FF total | LUT1 | LUT2 | LUT3 | LUT4 | LUT5 | LUT6 | LUT total | Estimated LCs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `systolic_gemm`, N=16 | 256 | 8,712 | 20 | 306 | 1,217 | 2 | 215 | 2,914 | 4,674 | 4,348 |
| `signed_int8_conv3x3` | 9 | 348 | 0 | 8 | 3 | 10 | 12 | 82 | 115 | 107 |
| `dcse_apb3_ctrl` | 0 | 404 | 0 | 44 | 12 | 21 | 52 | 123 | 252 | 214 |

FF totals combine the variants reported by Yosys:

- systolic: 8,712 `FDRE`;
- convolution: 92 `FDCE` plus 256 `FDRE`; and
- APB3: 404 `FDCE`.

The result matches the intended multiplier structure: one DSP48E1 per PE for
the 16 x 16 systolic array and nine DSP48E1 cells for the nine convolution
taps. The APB3 block is control logic and maps no DSP.

As a **preliminary structural reference only**, 256 inferred systolic DSPs are
30.48% of the board device's 840 DSP slices; nine convolution DSPs are 1.07%.
Those percentages are not routed utilization. The blocks are independent and
have not been integrated or synthesized together, so their counts must not be
summed and presented as a system result.

## Systolic feeder optimization

The first correct systolic version selected a feeder word using the active
cycle index. At N=16, that created large data-selector structures around every
row and column. The optimized version stores each row/column in a packed shift
queue and always reads word zero; only one-bit valid timing carries the spatial
skew.

| Yosys Xilinx-7 statistic | Cycle-indexed feeder | Fixed-head shift feeder | Change |
| --- | ---: | ---: | ---: |
| DSP48E1 | 256 | 256 | unchanged |
| Flip-flops | 8,712 | 8,712 | unchanged |
| LUT6 | 9,429 | 2,914 | -6,515 (-69.1%) |
| Estimated logic cells | 10,129 | 4,348 | -5,781 (-57.1%) |

Both versions passed the same functional interface behavior; the final N=4 and
N=16 regressions validate the optimized source. This comparison demonstrates a
specific architecture/refactoring effect in one synthesis tool. It does not
predict exact Vivado post-route resources or Fmax.

The constant FF count is expected: both versions retain complete accepted input
tiles and registered PE forwarding state. The improvement removes broad
cycle-indexed data selection rather than the storage itself.

## Exact-part Vivado flow

[`scripts/run_vivado_ooc.tcl`](../scripts/run_vivado_ooc.tcl) supplies a
reproducible out-of-context flow for the exact part. It sets:

- part: `xc7k325tffg900-2`;
- target clock period: 6.667 ns (150 MHz);
- clock uncertainty: 0.200 ns; and
- synthesis, optimization, placement, physical optimization, routing,
  utilization/timing/methodology/DRC reports, and a routed checkpoint.

Example commands are:

```bash
vivado -mode batch -source scripts/run_vivado_ooc.tcl -tclargs \
  systolic_gemm systolic_n16 clk_i N=16 \
  rtl/systolic/systolic_gemm.sv

vivado -mode batch -source scripts/run_vivado_ooc.tcl -tclargs \
  signed_int8_conv3x3 convolution clk - \
  rtl/convolution/signed_int8_conv3x3.sv

vivado -mode batch -source scripts/run_vivado_ooc.tcl -tclargs \
  dcse_apb3_ctrl apb3_ctrl PCLK - \
  rtl/integration/dcse_apb3_ctrl.sv
```

### Recorded blocker

A local Vivado 2025.2 run for `signed_int8_conv3x3` reached `synth_design` but
stopped with **Common 17-345** because no valid license was available for the
Kintex-7 XC7K325T device. No alternative part was substituted, because that
would not answer the exact-board question.

Consequently, this repository currently has:

- no exact-part Vivado synthesis result;
- no placed or routed design;
- no setup/hold slack or Fmax;
- no exact LUT/FF/BRAM/DSP utilization report;
- no congestion, DRC, methodology, or power result; and
- no board bitstream or measurement.

The failure is an environment/license blocker, not evidence that the design
passes or fails timing.

## Acceptance criteria for a Genesys 2 claim

Before reporting “optimized for Genesys 2” as a measured result, archive at
least:

1. the source commit, Vivado version, exact part, constraints, and generic
   parameters;
2. successful synthesis and routed checkpoint;
3. hierarchical utilization showing arithmetic, feeders, line storage, and
   control separately;
4. timing summary with no unconstrained core paths and passing setup/hold at
   the stated clock;
5. DRC and methodology reports with reviewed exceptions;
6. clock/reset, I/O, memory, and board-wrapper constraints—not only isolated
   core clocks;
7. post-route simulation or on-board arithmetic comparison against a versioned
   software oracle; and
8. end-to-end transfer-inclusive latency, throughput, and power under a named
   workload if system performance is claimed.

Until then, the accurate result is: **the standalone RTL passes simulation and
maps structurally to Xilinx 7-series primitives; exact Genesys 2 timing and
place-and-route remain unverified because the required local device license was
unavailable.**
