# Architecture and integration notes

## 1. Scope and chronology

This repository contains mostly independent accelerator experiments, not one
connected detector datapath. One narrow control demo connects APB to GEMM. The
original path is an HLS pointwise-projection/residual kernel plus a separately
verifiable parallel RTL MAC slice. On **2026-08-15**, after the
preceding CV/application snapshot, the repository added four post-CV
architecture prototypes:

- a true parameterized output-stationary systolic GEMM;
- a signed streaming 3x3 spatial cross-correlation primitive;
- a generic APB3 control/status block with a portable C register driver; and
- a narrow APB-to-systolic demo wrapper with direct packed matrix ports.

The new blocks are executable evidence for those individual architectural
ideas. They are not retroactive evidence, and they are not connected to the HLS
kernel, a complete detector, or a VEGA system. The demo wrapper is the one
intentional connection between new blocks: APB job control to systolic GEMM.

## 2. Artifact boundary

```text
independent paths

HLS arrays ----> dcse_top                 pixels ----> signed_int8_conv3x3
                 pointwise/residual                    cropped 3x3, 1 channel

16-input/16-output txn -> int8_mac_tile_16x16   C API -> relative APB contract
                          parallel, not systolic

narrow connected demo

direct packed A/B -----------+                 APB3
                             |                   |
                             v                   v
                   +-----------------------------------+
                   | dcse_apb_systolic_demo            |
                   | dcse_apb3_ctrl --start--> GEMM    |
                   | dcse_apb3_ctrl <--done--- GEMM    |
                   +-----------------------------------+
                             |                   |
                      direct packed C           irq
```

The demo consumes APB command/status handshakes only. Its inherited buffer
address and layer registers remain readable state but do not fetch or transform
the direct matrix ports.

## 3. Existing HLS computation

For every position `(row, column)` and output channel `oc`, `dcse_top` currently
computes:

```text
acc = bias[oc]
for ic in [0, input_channels):
    acc += input[row][column][ic] * weights[oc][ic]

if mode == IDENTITY_RESIDUAL and oc < input_channels:
    acc += input[row][column][oc]
```

Inputs and weights are signed INT8. Bias is signed INT16; the result is
accumulated and stored as signed INT32. Sixteen output channels are generated
for each position in a 16 x 16 tile. Source pragmas request MAC and pipeline
parallelism, but only completed synthesis reports can establish the achieved
structure, initiation interval, latency, or resource use.

### HLS data layout

The top-level C arrays define contiguous row-major buffers:

| Buffer | Logical shape | Element | Used elements |
| --- | --- | --- | ---: |
| `input_tile` | `[16][16][256]` | signed 8-bit | 65,536 |
| `weights` | `[16][256]` | signed 8-bit | 4,096 |
| `bn_bias` | `[16]` | signed 16-bit | 16 |
| `tile_rom` | `[35]` | unsigned 64-bit | 35 |
| `output_tile` | `[16][16][16]` | signed 32-bit | 4,096 |

### HLS layer descriptor

Each 64-bit table entry uses this layout:

| Bits | Field | Current behavior |
| --- | --- | --- |
| 63:48 | output channels | Reserved; hardware output width remains 16 |
| 47:32 | input channels | Used; accepted range is 1 through 256 |
| 31:16 | kernel size | Reserved; does not change HLS spatial behavior |
| 15:0 | layer type | `0`: reserved 3x3 ID that currently remains pointwise; `1`: pointwise projection; `2`: identity residual |

`layer_idx` selects one of 35 entries. The kernel checks the index before
reading the table, then accepts only the documented channel range and mode IDs.
Selected invalid fields produce an all-zero output tile. Output-channel and
kernel-size fields remain ignored, and there is no HLS error-status register,
so this is deterministic containment rather than complete validation.

The mode constant `SPATIAL3x3_RESERVED` must not be described as HLS 3x3
convolution. The real spatial RTL primitive described in section 6 is separate.

### HLS interfaces

The top function declares five independent AXI4 master bundles:

- `gmem0`: input tensor;
- `gmem1`: weight tensor;
- `gmem2`: bias vector;
- `gmem3`: descriptor table; and
- `gmem4`: output tensor.

Because the masters use `offset=slave`, Vitis HLS also generates AXI4-Lite base
address registers. The control interface carries `layer_idx` and standard
block-level start/done/idle/ready control. Exact offsets and signal behavior
must be taken from generated IP artifacts, not inferred from the C source.

## 4. Existing parallel RTL MAC slice

[`int8_mac_tile_16x16`](../rtl/int8_mac_tile_16x16.sv) accepts one transaction
containing 16 signed INT8 activations, a 16 x 16 signed INT8 weight tile, 16
INT32 biases, and optional INT32 residual values. It computes 16 independent
16-term dot products. A one-entry elastic output register permits back-to-back
replacement and holds its payload under downstream stalls.

This module is **not a systolic array**: operands do not move between
processing elements. It is also not a drop-in equivalent of `dcse_top`, which
reduces up to 256 channels and owns external-memory interfaces. A future
wrapper would have to sequence 16-channel chunks, retain partial sums, handle
residual-lane validity, and implement memory/control protocols.

## 5. Output-stationary systolic GEMM

[`systolic_gemm`](../rtl/systolic/systolic_gemm.sv) is a parameterized square
array with defaults `N=16`, `DATA_W=8`, and `ACC_W=32`. It computes signed
matrix multiplication:

```text
C[row][col] = sum(A[row][k] * B[k][col]), k = 0 .. N-1
```

The design is genuinely systolic:

- each PE owns one stationary accumulator for `C[row][col]`;
- A operands enter at the west boundary and move east through registered PE
  outputs;
- B operands enter at the north boundary and move south through registered PE
  outputs;
- row/column feeder timing applies the required wavefront skew; and
- no combinational operand broadcast spans a complete row or column.

Both input matrices are packed row-major and captured on an accepted `start_i`.
The controller then runs without intra-tile backpressure. `start_i` is ignored
while busy, `done_o` pulses for one cycle, and the result remains stable until a
later accepted job.

The active latency from the accepted-start edge to the completion edge is
fixed:

```text
latency = 3*N - 2 clocks
```

That is 10 clocks for N=4 and 46 clocks for the default N=16 configuration.
This is compute-core latency only; it excludes loading matrices from memory,
software overhead, and result transfer.

The current feeder implementation uses fixed-head packed shift queues. An
earlier cycle-indexed feeder produced large data multiplexers; replacing those
multiplexers preserved behavior and DSP/FF counts while materially reducing
the open-source Xilinx-7 LUT estimate. The before/after evidence is recorded in
[Genesys 2 mapping notes](genesys2_mapping.md).

This GEMM has no bias, activation, requantization, rectangular tiling,
convolution-lowering engine, DMA, AXI interface, overlapping jobs, or detector
control.

## 6. Signed 3x3 spatial primitive

[`signed_int8_conv3x3`](../rtl/convolution/signed_int8_conv3x3.sv) consumes one
signed pixel per accepted ready/valid transfer in raster order. Nine row-major
signed coefficients and an INT32 bias define:

```text
result = bias + sum(window[tap] * coefficient[tap]), tap = 0 .. 8
```

As in common CNN implementations, this is **cross-correlation**: coefficients
are not flipped. With no padding, a W x H input produces a `(W-2) x (H-2)`
output. The block emits start-of-frame, end-of-line, and end-of-frame markers.

Two line-delay arrays and horizontal shift registers construct the window. Nine
parallel signed multipliers feed the INT32 accumulation. The output is a
one-entry elastic register; when it is full and the consumer is not ready, the
input and every line/window state element freeze. Coefficients and bias must
remain stable for a frame.

Important limits are explicit:

- one input channel and one output channel per instance;
- no padding, dilation, stride selection, or kernel flip;
- no channel reduction or feature-map tiling;
- no rounding, saturation, requantization, or activation; and
- asynchronous line-memory reads whose final FPGA memory mapping and timing
  must be established by implementation.

This block does not change the HLS mode-0 behavior. Connecting it requires a
new wrapper, tensor schedule, multi-channel accumulation policy, and
equivalence tests.

## 7. Generic APB3 control boundary

[`dcse_apb3_ctrl`](../rtl/integration/dcse_apb3_ctrl.sv) is a zero-wait-state,
32-bit APB3 register block. It exposes five 64-bit buffer addresses, a layer
index, one-cycle accepted start, busy/done/error status, independent sticky IRQ
causes with write-one-to-clear behavior, an error code, and start/completion
counters. Job address/index writes are rejected while a job is busy.

The block assumes accelerator status inputs are synchronous to `PCLK`. It
contains neither a CDC nor an AXI/AHB-to-APB bridge. It also does not drive the
Vitis-generated AXI4-Lite interface; a platform wrapper would be required if
this programmer's model is retained.

[`software/dcse_apb3.h`](../software/dcse_apb3.h) and
[`software/dcse_apb3.c`](../software/dcse_apb3.c) implement the relative
register contract with a caller-supplied base. The driver performs RV32-sized
halves of 64-bit address writes and uses C11 compiler barriers. It deliberately
does not assign a physical address, issue a RISC-V hardware fence, maintain
caches, configure the PLIC, report platform bus faults, or serialize multiple
callers.

The complete register map, public VEGA interface evidence, and concrete
integration steps are in [VEGA integration notes](vega_integration.md).

### APB-to-systolic demonstration

[`dcse_apb_systolic_demo`](../rtl/integration/dcse_apb_systolic_demo.sv)
instantiates `dcse_apb3_ctrl` and `systolic_gemm` on the same `PCLK`. An
accepted APB `START` drives the GEMM, while GEMM busy/done feed the control
block's job status, sticky completion, counter, and interrupt behavior. The
GEMM exposes no runtime error output, so the demo's accelerator-error inputs
are tied inactive rather than inventing an error path.

The demonstration is intentionally direct-port based. Complete packed A and B
matrices are top-level inputs and packed C is a top-level output. Although the
APB block retains all five buffer address registers and the layer index, the
wrapper does not consume them. It has no address generator, memory master, DMA,
AXI/AHB interface, cache operation, physical-address translation, or CDC. Both
blocks use `PCLK`; APB reset is asynchronous while the systolic core samples
the shared active-low reset synchronously.

The N=4 integration test launches two signed GEMMs through APB and passes 112
checks. It verifies every output and the latency at three explicit boundaries:
10 clocks from raw GEMM busy to raw done, 11 clocks from accepted APB
`CONTROL` access to raw done, and 12 clocks from that access to sticky done/IRQ.
It also checks matrix input capture, status while active, busy-time start
rejection, counters, W1C acknowledgment, and restart. The default N=16 wrapper
elaborates cleanly, but the integration regression uses N=4 for compact,
inspectable control timing.

This closes one control-loop question; it does not close the memory or VEGA
integration questions in section 8.

## 8. What a connected system still requires

```text
VEGA CPU
   |
   | actual AXI4/AHB interconnect from the selected SoC tree
   v
address decoder / optional verified control bridge ----> PLIC
   |
   v
accelerator wrapper ----> generated HLS control or selected RTL core
   |
   +---- high-bandwidth tensor path / arbitration ----> external memory
```

A real integration must answer, with artifacts from the selected platform:

1. Which CPU/interconnect interface is available, and with what widths and
   protocol options?
2. Is HLS AXI4-Lite connected directly, or is a verified bridge/wrapper used?
3. Which physical range is assigned, and how is it kept consistent across the
   RTL decoder, linker/platform files, and driver?
4. How do five logical HLS memory bundles share physical memory bandwidth?
5. Are CPU caches coherent with accelerator traffic; if not, which flush and
   invalidate operations are required?
6. Which PLIC source carries completion/error, and how are faults recovered?
7. Which clock/reset crossings exist, and how are reset assertion/release and
   in-flight transactions handled?
8. How are illegal addresses, bus errors, timeouts, malformed descriptors, and
   partial jobs contained?

Public VEGA descriptions alone cannot answer these implementation-specific
questions. The exact accessible VEGA/contest integration tree is a prerequisite
for truthful system claims.

## 9. Verification boundary

Passing evidence currently exists for:

- HLS C arithmetic against a separate golden loop, including valid channel and
  residual boundaries plus selected invalid configurations;
- dependency-free Python descriptor/arithmetic tests;
- parallel MAC signed arithmetic and ready/valid behavior;
- systolic wavefront timing, signed arithmetic, repeated jobs, busy-time start
  rejection, and every output in N=4 and N=16 tests;
- 3x3 signed arithmetic, two frames/configurations, bubbles, output stalls,
  propagated input backpressure, and frame/line markers;
- APB3 setup/access behavior, legal and illegal accesses, configuration lock,
  command/status/counter behavior, interrupts, and reset;
- the APB-to-systolic start/busy/done/IRQ control loop across two direct-port
  GEMM jobs;
- host-side portable driver register sequencing and validation; and
- open-source mapping to Xilinx 7-series primitives.

That evidence does not establish cross-block equivalence, HLS RTL behavior,
AXI correctness, exact-part timing, full-detector correctness, VEGA integration,
or board performance. See the [verification matrix](verification_matrix.md).

## 10. Design trade-offs

- **Independent research slices:** make each architectural question small and
  testable, but integration and data movement remain unsolved.
- **Fixed 16-channel HLS output tile:** exposes useful parallelism while
  requiring software tiling for other output widths.
- **Full N x N systolic tile ports:** make wavefront behavior easy to verify,
  but a practical system needs local memories/streaming and tile scheduling.
- **Output-stationary GEMM:** keeps partial sums local and exposes 256 parallel
  multiplies at N=16; that consumes substantial DSP capacity and makes feeder
  and routing architecture important.
- **Nine-parallel-multiplier 3x3:** produces a window result without serializing
  taps, but multi-channel convolution still needs accumulation and buffering.
- **Backpressure freezes the convolution state:** gives simple lossless
  semantics at the cost of stalling the full pixel pipeline.
- **APB for control only:** is appropriate for low-rate register access, while
  tensor movement must use AXI/AHB memory infrastructure.
- **Direct packed matrices in the demo:** isolate and verify the control loop,
  but deliberately bypass every practical memory, bandwidth, and cache issue.
- **INT8 products with INT32 accumulation:** give clear signed arithmetic, but
  quantization scale, rounding, activation, and saturation remain separate
  design decisions.

The next research-quality step is wrapper-level composition with shared vectors
and explicit memory/control behavior, followed by licensed exact-part
implementation and board measurement.
