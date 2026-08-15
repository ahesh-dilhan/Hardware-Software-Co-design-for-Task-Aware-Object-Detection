# Architecture and integration notes

## 1. Implemented computation

For every pixel `(row, column)` and output channel `oc`, the accelerator
currently computes:

```text
acc = bias[oc]
for ic in [0, input_channels):
    acc += input[row][column][ic] * weights[oc][ic]

if mode == IDENTITY_RESIDUAL and oc < input_channels:
    acc += input[row][column][oc]
```

Inputs and weights are signed INT8. Bias is signed INT16 and the result is
accumulated and stored as signed INT32. Sixteen output channels are generated
for each position in a 16 x 16 tile. Source pragmas request MAC and pipeline
parallelism, but only a completed synthesis report can establish the achieved
structure, initiation interval, or resource mapping.

This is a parallel MAC tile. A systolic array would require an explicit spatial
schedule in which operands or partial sums move between processing elements;
that communication structure does not exist in this implementation.

## 2. Data layout

The top-level C arrays define contiguous row-major buffers:

| Buffer | Logical shape | Element | Used elements |
| --- | --- | --- | ---: |
| `input_tile` | `[16][16][256]` | signed 8-bit | 65,536 |
| `weights` | `[16][256]` | signed 8-bit | 4,096 |
| `bn_bias` | `[16]` | signed 16-bit | 16 |
| `tile_rom` | `[35]` | unsigned 64-bit | 35 |
| `output_tile` | `[16][16][16]` | signed 32-bit | 4,096 |

A true 3x3 implementation would require a separate spatial-kernel dimension
and a line/window buffer to select neighboring pixels; neither is implied by
the compact pointwise weight layout.

## 3. Layer descriptor

Each 64-bit table entry uses the following layout:

| Bits | Field | Current behavior |
| --- | --- | --- |
| 63:48 | output channels | Reserved; hardware output width remains 16 |
| 47:32 | input channels | Used; software must provide a value from 1 to 256 |
| 31:16 | kernel size | Reserved; does not yet change spatial behavior |
| 15:0 | layer type | `0`: reserved 3x3 ID (currently pointwise), `1`: pointwise projection, `2`: identity residual |

`layer_idx` selects one of 35 entries. The kernel checks the table index before
reading memory, then accepts only 1 through 256 input channels and layer types
0, 1, or 2. An invalid configuration produces an all-zero output tile. There is
no separate error-status register yet, so software must still validate the
descriptor, allocated buffer sizes, and physical addresses before starting.
The output-channel and kernel-size fields remain ignored; the zero response is
therefore deterministic containment for selected fields, not complete input or
memory-safety enforcement.

## 4. HLS-generated interfaces

The HLS top function declares five independent AXI4 master bundles:

- `gmem0`: input tensor;
- `gmem1`: weight tensor;
- `gmem2`: bias vector;
- `gmem3`: descriptor table;
- `gmem4`: output tensor.

Because the AXI masters use `offset=slave`, HLS generates AXI4-Lite base-address
registers for their buffers. The control interface also carries `layer_idx` and
the standard block-level start/done/idle/ready control associated with `return`.
The exact register offsets and signal-level RTL are generated-tool artifacts;
they should be recorded from the packaged IP rather than guessed in source
documentation.

An SoC may merge these logical memory bundles into fewer physical ports. That
choice changes bandwidth contention and therefore requires a new synthesis and
system-level performance measurement.

## 5. Standalone SystemVerilog MAC primitive

[`rtl/int8_mac_tile_16x16.sv`](../rtl/int8_mac_tile_16x16.sv) is a separately
verifiable 16-input x 16-output arithmetic slice. One ready/valid transaction
contains 16 activations, a 16 x 16 weight tile, 16 INT32 biases, and optional
INT32 residual values. Its one-entry elastic output register supports
back-to-back traffic and holds data stable under downstream stalls.

This primitive is not a drop-in RTL equivalent of `dcse_top`: it computes one
16-input channel chunk, while the HLS kernel reduces as many as 256 channels
and owns external-memory interfaces. A future wrapper must sequence channel
chunks, retain partial sums, mask unavailable residual channels, and connect
the memory/control protocols.

## 6. Control and data sequence

```text
software                control interface          accelerator / memory
   | validate descriptor       |                              |
   | allocate/fill buffers     |                              |
   | write addresses + index   |----------------------------->|
   | assert start              |----------------------------->|
   |                           |   AXI reads, MAC, residual    |
   |                           |<-------------------- done ----|
   | invalidate/read output    |                              |
```

If a processor cache is not hardware coherent with the FPGA master port,
software must flush input/weight/bias ranges before start and invalidate the
output range after completion. This is an integration requirement, not an
implemented feature of the HLS kernel.

## 7. Processor-integration boundary

The repository stops at the accelerator IP boundary. A defensible VEGA
integration needs concrete answers for:

1. Which VEGA/SoC memory interface is exposed in the selected platform?
2. Is AXI4-Lite connected directly, or is an APB/AHB/AXI bridge required?
3. Who translates virtual to physical addresses, if virtual memory is used?
4. Are data buffers coherent with processor caches?
5. Is completion polled or interrupt driven?
6. Which clocks and resets cross the processor/accelerator boundary?
7. How are illegal addresses, timeouts, and malformed descriptors contained?

Until a specific accessible SoC integration tree answers those questions, the
correct artifact is an interface contract and test plan—not an invented memory
map.

## 8. Verification strategy

Current checks:

- deterministic HLS C simulation against a separately written golden loop;
- all 4,096 outputs compared for every case;
- both non-residual identifiers and identity-residual mode;
- channel boundaries at 1, 7, 16, 31, and 256;
- specific coverage for residual outputs where `oc >= input_channels`;
- four invalid-configuration cases that require deterministic zero output; the
  out-of-range index case also proves no descriptor-table read is required;
- dependency-free Python unit tests for arithmetic and descriptor semantics;
- self-checking standalone RTL tests for signed MAC arithmetic, residual input,
  ready/valid backpressure, back-to-back transfers, and asynchronous reset.

Required before board-performance claims:

- C/RTL co-simulation of all functional cases;
- AXI protocol assertions and randomized stalls/backpressure;
- AXI address faults, reset during a memory transaction, and timeout tests;
- synthesis and implementation reports archived with tool and commit versions;
- board tests that compare FPGA output to a software oracle and record both
  accelerator-only and end-to-end latency.

## 9. Design trade-offs

- **Fixed 16-channel output tile:** exposes parallelism and keeps control simple,
  but layers with other output widths require tiling in software.
- **Channel-reduction parallelism:** the source pragma exposes a throughput vs.
  multiplier/routing/bandwidth trade-off; the achieved mapping remains unknown
  until synthesis completes.
- **Separate memory bundles:** make concurrency visible to HLS, but the physical
  platform may not supply five independent high-bandwidth ports.
- **INT8 products / INT32 accumulation:** avoid accumulator overflow for the
  configured 256-channel dot product, but quantization scale, rounding, and
  output requantization are not yet part of this kernel.
- **Descriptor-driven modes:** reduce control traffic across layers. Bounds/type
  checks give selected invalid fields a deterministic response, but ignored
  fields and missing error-status reporting still leave work for a resilient
  production design.

The next research-quality step is to convert these known trust assumptions into
explicit hardware checks and fault-injection tests.
