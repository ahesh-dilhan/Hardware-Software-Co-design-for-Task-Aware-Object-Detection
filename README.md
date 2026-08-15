# Task-Aware Object-Detection Accelerator: FPGA/HLS Prototype

[![verify](https://github.com/ahesh-dilhan/Hardware-Software-Co-design-for-Task-Aware-Object-Detection/actions/workflows/verify.yml/badge.svg)](https://github.com/ahesh-dilhan/Hardware-Software-Co-design-for-Task-Aware-Object-Detection/actions/workflows/verify.yml)

This repository explores accelerator building blocks for a task-aware
object-detection system. It now contains several deliberately separate
implementation paths: an HLS pointwise-projection kernel, standalone RTL
arithmetic primitives, and a generic APB3 control boundary with a portable C
register driver. One narrow demo wrapper connects APB start/status control to
the systolic core while keeping matrices on direct packed ports. Each path has
its own test evidence; none is presented as an integrated detector or complete
processor/FPGA system.

The central engineering rule is **evidence before claims**. Simulation of one
block is not equivalence proof for another, structural synthesis is not
place-and-route timing closure, and an APB peripheral is not a VEGA SoC
integration.

## Scope and current status

| Artifact | Implemented behavior | Current evidence | Integration status |
| --- | --- | --- | --- |
| HLS kernel | Signed INT8 pointwise channel projection, 16 outputs, INT32 accumulation, INT16 bias, optional identity residual | Python model and Vitis HLS 2025.2 C simulation | Independent kernel; generated RTL is not committed |
| `int8_mac_tile_16x16` | One 16-input x 16-output parallel dot-product transaction with bias/residual and an elastic output | Self-checking RTL simulation | Standalone; **not systolic** and not equivalent to the full HLS kernel |
| `systolic_gemm` | Parameterized signed N x N output-stationary GEMM with registered neighbor-to-neighbor operand movement | N=4 directed regression and default N=16 all-output smoke test | Standalone; no DMA, convolution lowering, bias, or requantization |
| `signed_int8_conv3x3` | One-channel signed 3x3 cropped CNN cross-correlation with bias, framing, and ready/valid backpressure | Two-frame self-checking RTL test | Standalone; not connected to the HLS datapath |
| `dcse_apb3_ctrl` | Zero-wait APB3 configuration/status registers, job command, sticky completion/error, counters, and IRQ | 167-check RTL test | Generic control boundary; **not a VEGA hookup or AXI/APB bridge** |
| `dcse_apb_systolic_demo` | Connects APB start/busy/done/IRQ to `systolic_gemm`; matrices/results remain direct packed ports | Two APB-launched N=4 signed GEMMs and 112 integration checks | Narrow control demo; programmed addresses are retained but not consumed |
| Portable C register driver | Programs five 64-bit addresses, a layer index, start/status, and interrupts through a symbolic base | Strict host build and 66-check mock-MMIO test | Register-contract driver; no board address, cache policy, PLIC, or hardware fence |
| Xilinx 7-series structural mapping | Maps the three new leaf RTL blocks to Xilinx 7-series primitives | Reproducible Yosys scripts and recorded cell counts | No placement, routing, timing, power, or board result |

This is **not a complete object detector**. It does not contain an integrated
YOLO graph, trained weights, activation/requantization stages, detection head,
non-maximum suppression, tensor DMA, processor/accelerator interconnect, or a
validated board application.

### Development chronology

The systolic GEMM, signed 3x3 convolution, APB3 control block, APB-to-systolic
demo, portable driver, and Xilinx 7-series mapping flow were added on
**2026-08-15**, after the CV and application snapshot that preceded this work.
They are current, post-CV prototypes and should not be used to imply that those
exact artifacts existed when earlier application material was submitted. Git
history preserves that chronology.

## Architecture at a glance

```text
existing HLS path (pointwise only)

buffer addresses + layer index              external memory
             |                      input / weights / bias / descriptor
             v                                     |
      HLS AXI4-Lite control                 five HLS AXI4 masters
             |                                     |
             +----------> dcse_top <---------------+
                              |
                    pointwise / residual output


RTL research blocks

 direct packed A/B -----------+       APB3 control
                              |            |
                              v            v
                    +--------------------------------+
                    | dcse_apb_systolic_demo         |
                    | ctrl --start--> systolic_gemm  |
                    | ctrl <--done--- systolic_gemm  |
                    +--------------------------------+
                              |            |
                       direct packed C     irq

 raster pixels -> signed_int8_conv3x3 -> cropped 3x3 accumulation

 int8_mac_tile_16x16 remains a separate non-systolic parallel MAC slice

 APB buffer addresses are stored/readable but unused by the demo datapath
```

The HLS mode named `SPATIAL3x3_RESERVED` still executes the pointwise HLS
datapath. The new RTL 3x3 block is a real spatial primitive, but no wrapper
currently substitutes it into `dcse_top`. Similarly, the true systolic GEMM is
separate from both the HLS kernel and the older parallel MAC tile. The demo
connects only its APB job handshake: it does not fetch matrices through the
programmed address registers.

See [architecture notes](docs/architecture.md), the
[verification matrix](docs/verification_matrix.md), and the
[VEGA integration boundary](docs/vega_integration.md) for the precise
interfaces and remaining system work. The
[design-review walkthrough](docs/review_walkthrough.md) provides a short path
from each statement to its source and test evidence.

## Reproduce the checks

The portable regression requires Python 3, a C11 compiler, Icarus Verilog, and
`vvp`:

```bash
make test
```

It runs the Python model, all RTL testbenches, and the host-side C
driver test. Individual targets include `model-test`, `rtl-mac-test`,
`rtl-systolic-test`, `rtl-systolic-n16-test`, `rtl-convolution-test`,
`rtl-apb-test`, `rtl-apb-systolic-demo-test`, and `software-test`.

For reproducible structural mapping with Yosys:

```bash
make synth-xc7
```

The scripts use `synth_xilinx -family xc7 -noiopad`. The result is useful for
checking primitive inference and architecture scale, but it is not exact
Genesys 2 utilization or timing. See
[Genesys 2 mapping notes](docs/genesys2_mapping.md).

To run the HLS C simulation with Vitis HLS on `PATH`:

```bash
make hls-csim
```

To request C simulation followed by HLS synthesis:

```bash
make hls
```

If synthesis completes, review
`dcse_hls_project/solution1/syn/report/dcse_top_csynth.rpt` rather than inferring
latency, initiation interval, or resource use from source pragmas.

### Evidence snapshot: 2026-08-15

- Portable Python model: **10/10 tests passed**.
- HLS C simulation: six valid arithmetic cases and four invalid-configuration
  cases passed; every 4,096-element output tile was checked.
- Parallel MAC RTL: three vectors and **48 output accumulations** passed,
  including back-to-back traffic, a four-cycle stall, and reset.
- Systolic RTL: three N=4 cases checked 48 outputs with exact 10-cycle active
  latency; the default N=16 case checked all **256 outputs in 46 active
  cycles**.
- 3x3 RTL: **84 signed pixels produced 40 checked cropped outputs** across two
  7 x 6 frames, with two kernels, signed extremes, bias, bubbles,
  backpressure, and framing.
- APB3 RTL: **167 checks passed**.
- APB-to-systolic demo: **112 checks passed** across two APB-launched signed
  N=4 GEMMs. Timing was checked at all boundaries: 10 clocks from raw GEMM busy
  to raw done, 11 from the accepted APB `CONTROL` access to raw done, and 12
  from that access to sticky done/IRQ. Busy-start rejection, input capture,
  status, counters, W1C, and restart were also checked.
- Portable driver: strict C11 compilation and **66 mock-MMIO checks passed**.

The exact command/result boundary is recorded in
[local results](docs/local_results.md).

## Processor integration contract

The generic APB3 block makes the proposed software-visible control state
executable: five buffer addresses, layer index, start, busy/done/error status,
interrupt enables/causes, and job counters. The portable C API exercises that
same relative register map.

`dcse_apb_systolic_demo` proves a small part of that contract end to end: an
APB start launches the systolic core and completion is visible through status,
counters, and IRQ. A and B still enter as direct packed top-level ports, C
leaves the same way, and the APB buffer addresses are not consumed.

It does not select a VEGA physical base address or connect to a VEGA
interconnect. Public VEGA ET1031/AT1051 material describes configurable AXI4 or
AHB interfaces, so an actual build must inspect the selected SoC tree and then
either connect the generated HLS AXI4-Lite control interface directly or add a
verified platform-specific bridge/wrapper. Tensor traffic must remain on a
high-bandwidth memory path, not APB.

Still required are a concrete address decoder, generated HLS register-map
cross-check, memory arbitration, cache/coherency rules, PLIC assignment,
clock-domain/reset analysis, DMA or equivalent data movement, fault handling,
and software-to-board verification. Until those exist, the defensible status
is: **APB3 control peripheral and portable register driver implemented and
simulation-checked; VEGA system integration remains future work.**

## Project provenance

This repository began as a team/DVCon submission snapshot. Git history
preserves the original Stage 2A import under the contributor identity
`codingNR29`; repository ownership alone should not be read as sole authorship
of that material. Root contest archives, notebooks, and media are preserved
historical/team artifacts and are not evidence for the accelerator paths
documented here.

The recorded team contribution split is:

- **Ahesh Dilhan:** primary hardware lead—hardware architecture, hardware
  design and planning, accelerator analysis, and hardware verification.
- **Cubing and Kavija:** machine-learning work.

The source-first RTL slices, portable model/tests, verification matrix, and
documentation are a later hardware-side hardening layer led by Ahesh. History
has not been rewritten to obscure the distinction. See
[`CONTRIBUTORS.md`](CONTRIBUTORS.md).

## Next milestones

1. Define a wrapper-level dataflow and prove the standalone arithmetic blocks
   against shared software vectors before connecting them to HLS or memory.
2. Generate/package the HLS IP, archive its exact AXI register map and reports,
   and test AXI behavior under randomized stalls and error responses.
3. Obtain the exact VEGA contest/integration tree, choose the real AXI/AHB/APB
   boundary, and implement the address, cache, interrupt, reset, and CDC plan.
4. Complete licensed implementation for `xc7k325tffg900-2`, then report timing,
   routed utilization, power, and repeatable board measurements from archived
   artifacts.
5. Add the missing detector-level stages and compare end-to-end accuracy and
   transfer-inclusive latency against a versioned software oracle.

## License

The newly authored repository-hardening material is MIT licensed. The original
team/contest/HLS snapshot and third-party collateral are excluded from that
grant and retain any terms attached to their original files. See
[`LICENSE`](LICENSE).
