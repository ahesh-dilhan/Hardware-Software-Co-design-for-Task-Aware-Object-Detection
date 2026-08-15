# Task-Aware Object-Detection Accelerator: FPGA/HLS Prototype

[![verify](https://github.com/ahesh-dilhan/Hardware-Software-Co-design-for-Task-Aware-Object-Detection/actions/workflows/verify.yml/badge.svg)](https://github.com/ahesh-dilhan/Hardware-Software-Co-design-for-Task-Aware-Object-Detection/actions/workflows/verify.yml)

This repository explores the accelerator side of a hardware/software
co-design for task-aware object detection. The current prototype is a
fixed-size, 16-output-channel INT8 MAC tile with an optional identity-residual
primitive. It is written in Xilinx HLS C++ and targets the Kintex-7
device used by the Digilent Genesys 2 board.

The most important design rule in this repository is **evidence before
claims**. The HLS C testbench, portable Python model, and standalone RTL slice
have separate checks; passing one is not presented as equivalence proof for the
others. Timing, latency, and utilization are reported only from completed
synthesis reports.

This is an accelerator-kernel prototype, not an end-to-end object detector. It
does not yet contain a YOLO graph or trained weights, spatial convolution,
activation/requantization, a detection head, or non-maximum suppression.

## What is implemented

| Capability | Status | Evidence |
| --- | --- | --- |
| INT8 channel projection, 16 output channels | Implemented | [`src/dcse_top.cpp`](src/dcse_top.cpp) |
| INT32 accumulation with INT16 bias | Implemented | HLS source and boundary tests |
| Optional identity-residual primitive | Implemented | C simulation includes 7- and 31-channel residual cases |
| Deterministic zero-output response for selected invalid configuration fields | Implemented | Directed tests cover layer index, channel count, and mode |
| Standalone 16-input x 16-output SystemVerilog MAC primitive | Implemented | Self-checking ready/valid testbench covers 48 accumulations, stalls, back-to-back traffic, and reset |
| AXI4 memory ports and AXI4-Lite control | Described by HLS interface pragmas | Generated RTL must be inspected after HLS synthesis |
| Genesys 2 Kintex-7 target, 150 MHz constraint | Configured | [`run_hls.tcl`](run_hls.tcl); timing closure is not yet claimed |
| Dependency-free executable reference model | Implemented | `make model-test` |
| Spatial 3x3 convolution | **Not implemented** | Descriptor value exists, but the current datapath is pointwise |
| VEGA processor, APB bridge, DMA, or CDC integration | **Not implemented here** | Integration boundary and roadmap are documented below |
| Board-measured end-to-end detector performance | **Not measured** | Requires packaged IP, SoC integration, and repeatable board tests |

The MAC implementation is a **parallel dot-product tile**, not a systolic
array. Inputs and weights do not propagate between processing elements in the
current design.

## Architecture at a glance

```text
software: start, layer_idx, base addresses       external memory
          |                             input / weights / bias
          |                                  + descriptor table
          v                                           |
   AXI4-Lite control                           AXI4 reads: gmem0..3
  +----------------+       +--------------------------v-----+
  | control + bases|------>| 16-output-channel INT8 MAC tile|
  +----------------+       +---------------+----------------+
                                             |
                        +--------------------+------------------+
                        |                                       |
                 non-residual mode                identity-residual mode
                        |                            identity-bank add
                        +--------------------+------------------+
                                             |
                                gmem4 writes to output memory
```

See [`docs/architecture.md`](docs/architecture.md) for tensor layouts, the
descriptor format, interface ownership, design trade-offs, and the staged
processor-integration plan.

## Reproduce the checks

The full local check runs the dependency-free Python model tests and the
self-checking SystemVerilog testbench (Icarus Verilog is required for RTL):

```bash
make test
```

To run the checked HLS C simulation with Vitis HLS on `PATH`:

```bash
make hls-csim
```

To request C simulation followed by synthesis:

```bash
make hls
```

Review
`dcse_hls_project/solution1/syn/report/dcse_top_csynth.rpt` for achieved clock,
latency, initiation interval, and resources. The repository deliberately does
not copy aspirational numbers into this README. Vitis HLS 2025.2 is the only
version exercised for the current source state.

### Current local result

- 10/10 portable Python tests passed.
- The standalone RTL test passed 3 vectors, 48 output accumulations,
  back-to-back traffic, a four-cycle stall, and asynchronous reset.
- Vitis HLS 2025.2 C simulation passed all six valid arithmetic cases and four
  invalid-configuration cases.
- A bounded local C-synthesis attempt was stopped before completion, so this
  revision makes no latency, II, utilization, or timing-closure claim.

The exact commands and result boundary are recorded in
[`docs/local_results.md`](docs/local_results.md).

## Verification coverage

The HLS C testbench uses deterministic randomized tensors and checks every
output value for:

- pointwise projection with 1, 7, and 256 input channels;
- the currently compatible behavior of the 3x3 mode identifier;
- identity-residual mode at 7 and 31 channels, including outputs that have no
  matching identity channel.
- invalid zero/oversized channel counts, an unknown mode, and an out-of-range
  layer-table index, all of which must produce an all-zero output.

The portable Python tests independently cover descriptor packing, signed INT8
range enforcement, projection arithmetic, residual boundaries, and all channel
counts used by the HLS testbench. The standalone RTL test checks three vectors,
48 output accumulations, back-to-back transfers, a four-cycle downstream stall,
and reset. CI runs both suites on every push and pull request.

## Processor integration contract

The intended processor/accelerator split is:

- software validates and packs layer descriptors, allocates contiguous tensor
  buffers, and sequences accelerator jobs;
- the accelerator reads tensors/descriptors through `gmem0` through `gmem3`,
  writes results through `gmem4`, and exposes start/status control through the
  AXI4-Lite block generated by HLS;
- a future VEGA-based system must add an SoC-specific interconnect or bridge,
  address map, cache-coherency policy, interrupt handling, and CDC analysis.

No APB, DMA, CDC, or complete VEGA integration is claimed by this repository.
The [VEGA ET1031 documentation](https://cdac-vega.gitlab.io/socoverview/microprocessors.html)
is the external processor reference; access to an actual SoC integration tree
and its memory map is a prerequisite for that phase.

## Project provenance

This repository began as a team/DVCon submission snapshot. Git history
preserves the original Stage 2A import under the contributor identity
`codingNR29`; repository ownership alone should not be read as sole authorship
of that material. The root contest archives, notebooks, and media are preserved
historical/team artifacts and are not evidence for the accelerator path
documented here. Any presentation of the project should name the team and state
each person's exact contribution.

The source-first RTL slice, portable model/tests, verification matrix, and
documentation are a later repository-hardening layer. History has not been
rewritten to obscure the distinction.

## Next milestones

1. Implement a line/window buffer and use nine weight positions for true 3x3
   spatial convolution.
2. Export the HLS IP, archive the generated reports, and test AXI behavior under
   backpressure.
3. Build the processor-side driver against a concrete SoC address map; add
   negative tests for invalid descriptors and addresses.
4. Measure board latency, throughput, utilization, power, and software overhead
   with a versioned bitstream and test vector set.

This staged plan keeps the project useful today while making the remaining
research questions explicit and falsifiable.

## License

The newly authored repository-hardening material is MIT licensed. The original
team/contest/HLS snapshot and third-party collateral are excluded from that
grant and retain any terms attached to their original files. See
[`LICENSE`](LICENSE).
