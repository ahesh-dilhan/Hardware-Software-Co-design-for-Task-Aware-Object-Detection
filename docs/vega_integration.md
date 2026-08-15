# VEGA processor-integration boundary

## Evidence status

This directory now contains a **tested APB3 control/status peripheral**, not a
completed VEGA SoC integration.

Implemented and locally verified:

- `rtl/integration/dcse_apb3_ctrl.sv`: a 32-bit, zero-wait-state APB3 CSR
  slave;
- five 64-bit buffer-address registers plus a checked layer index;
- a one-cycle accepted-start pulse and configuration locking while busy;
- sticky done/error causes, interrupt enables, W1C clearing, error-code
  capture, and diagnostic counters;
- `PSLVERR` on unaligned, unmapped, read-only, locked, or invalid accesses;
- `sim/integration/tb_dcse_apb3_ctrl.sv`: 167 self-checking protocol and state
  checks;
- `software/dcse_apb3.[ch]`: a portable symbolic-base register API with 66
  host mock-MMIO checks; and
- `dcse_apb_systolic_demo`: a direct-packed-matrix control demonstration with
  112 checks across two APB-launched N=4 GEMMs.

Not implemented or claimed:

- instantiation inside a C-DAC VEGA/THEJAS/TRISUL SoC RTL tree;
- a VEGA address-decoder slot or assigned physical base address;
- an AXI/AHB-to-APB bridge;
- a bridge from this register block to the AXI4-Lite interface generated for
  `dcse_top` by Vitis HLS;
- connection of the five HLS AXI4 memory masters to system memory;
- PLIC interrupt allocation, VEGA-target firmware/driver port, cache
  maintenance, CDC/reset integration, complete synthesis/implementation, or
  board execution.

The evidence-supported status is:

> The generic APB3 control/status boundary, portable register API, and a narrow
> direct-port APB-to-systolic control demo are implemented and self-tested.
> They are not built into a VEGA SoC; the exact SoC RTL, interconnect port,
> memory map, clock/reset plan, generated HLS RTL, and memory data path must be
> selected and verified first.

## What the public VEGA sources establish

“VEGA” names a family of C-DAC RISC-V processors and SoCs, not one universal
accelerator interface.

- C-DAC describes the VEGA ET1031 as an RV32IM, three-stage, in-order core with
  a configurable AXI4 or AHB external interface:
  <https://www.vegaprocessors.in/vega-et1031.php>
- C-DAC describes the VEGA AT1051 as a five-stage 32-bit core with caches, MMU,
  PLIC support, and a configurable AXI4 or AHB external interface:
  <https://www.vegaprocessors.in/vega-at1051.php>
- C-DAC describes THEJAS32 as an ET1031-based 100 MHz SoC with SRAM and a set of
  fixed peripherals:
  <https://www.vegaprocessors.in/thejas32-soc.php>
- Its published THEJAS32 address map lists the existing peripherals but does
  not reserve an accelerator address for this project:
  <https://cdac-vega.gitlab.io/socoverview/addressmap.html>
- The C-DAC GitLab group says repository access must be requested. No matching
  public SoC integration tree was available for an honest build of this IP:
  <https://gitlab.com/cdac-vega>

These primary sources support AXI/AHB at the advertised processor boundary.
They do **not** establish that this accelerator can be attached directly as an
APB slave. APB remains a reasonable low-bandwidth CSR interface only if the
chosen SoC supplies an APB peripheral segment or a verified AXI/AHB-to-APB
bridge. The Arm APB3 transfer behavior implemented here follows the
non-confidential AMBA APB Protocol Specification, Arm IHI 0024C:
<https://documentation-service.arm.com/static/64257f64314e245d086bc8b7>

## Intended system boundary

```text
VEGA CPU
   |
   | AXI4 or AHB, depending on the selected core/SoC
   v
SoC interconnect + address decoder
   |
   | verified bridge, only if an APB segment is used
   v
dcse_apb3_ctrl  ---- irq ----> PLIC input
   |
   | stable configuration + start/done/error contract
   v
platform-specific accelerator wrapper
   |
   +---- generated HLS control interface
   |
   +---- HLS AXI4 memory masters ----> system memory
```

The APB path is for low-bandwidth control. Tensor, weight, descriptor, bias,
and output traffic must use the high-bandwidth memory path; transferring those
payloads through APB would be an architectural bottleneck.

The present HLS source requests its own AXI4-Lite control registers and five
AXI4 memory-master bundles. Consequently, this APB block is an interface
contract/prototype, not a drop-in wrapper around the generated IP. A real
implementation must choose one of two explicit approaches:

1. connect the HLS AXI4-Lite control port directly to a compatible SoC AXI
   interconnect and omit this APB block; or
2. retain this APB programmer's model and implement a platform wrapper that
   correctly drives the generated HLS control interface.

That choice cannot be validated from HLS C source alone.

## APB3 signal behavior

The peripheral implements the APB3 signals `PCLK`, `PRESETn`, `PSEL`,
`PENABLE`, `PWRITE`, `PADDR`, `PWDATA`, `PRDATA`, `PREADY`, and `PSLVERR`.
It deliberately does not use APB4-only write strobes.

- A setup cycle has `PSEL=1` and `PENABLE=0`.
- The following access cycle has `PSEL=1` and `PENABLE=1`.
- `PREADY` is always one, so there are no inserted wait states.
- Read data is combinational from the selected register.
- A legal write commits on the access-phase rising edge.
- `PSLVERR` is qualified by the access phase and is never asserted in setup.
- Invalid writes do not change state or increment the start counter.

The peripheral and the accelerator status inputs are currently assumed to be
in the `PCLK` domain. A clock-domain crossing is not hidden in this module.

## Relative register map

No VEGA physical base address is assigned. Every address below is an offset
from a base that must be allocated by the selected SoC integrator.

| Offset | Name | Access | Reset | Behavior |
| ---: | --- | --- | ---: | --- |
| `0x00` | `ID` | RO | `0x44435345` | ASCII `DCSE` |
| `0x04` | `VERSION` | RO | `0x00010000` | Interface version 1.0 |
| `0x08` | `CONTROL` | WO | 0 | Bit 0 is a write-one start command |
| `0x0c` | `STATUS` | RO | — | Bit 0 busy, 1 done, 2 error, 3 accelerator idle, 4 IRQ |
| `0x10` | `IRQ_ENABLE` | RW | 0 | Bit 0 enables done; bit 1 enables error |
| `0x14` | `IRQ_STATUS` | RW1C | 0 | Bit 0 done; bit 1 error |
| `0x18` | `LAYER_INDEX` | RW | 0 | Legal values 0 through 34 |
| `0x1c` | `ERROR_CODE` | RO | 0 | Captured eight-bit accelerator error |
| `0x20/24` | `INPUT_ADDR_LO/HI` | RW | 0 | 64-bit input-buffer address |
| `0x28/2c` | `WEIGHTS_ADDR_LO/HI` | RW | 0 | 64-bit weight-buffer address |
| `0x30/34` | `BIAS_ADDR_LO/HI` | RW | 0 | 64-bit bias-buffer address |
| `0x38/3c` | `DESC_ADDR_LO/HI` | RW | 0 | 64-bit descriptor-table address |
| `0x40/44` | `OUTPUT_ADDR_LO/HI` | RW | 0 | 64-bit output-buffer address |
| `0x48` | `START_COUNT` | RO | 0 | Accepted starts, modulo 2^32 |
| `0x4c` | `COMPLETE_COUNT` | RO | 0 | Done/error terminal events, modulo 2^32 |

All APB accesses must be word-aligned. Writes to configuration registers are
rejected with `PSLVERR` while busy, so one accepted job sees a stable
configuration. A start command is also rejected if either internal busy is set
or the downstream `accel_idle` input is low. Starting a new job clears stale
done/error state. Error has priority if `accel_done` and `accel_error` arrive
together.

The 64-bit address pairs make the boundary portable, but an RV32 driver must
write both halves before `START`. This register block does not make a pair of
32-bit writes atomic across multiple software threads; a driver lock or sole
ownership is still required.

## Verification performed

The testbench checks:

- asynchronous reset values;
- APB setup/access phase behavior and zero-wait-state completion;
- ID, version, status, address, and index readback;
- all five 64-bit address pairs;
- layer indices 34 and 35 as the valid/invalid boundary;
- misaligned, unmapped, read-only, reserved-bit, and locked writes;
- exactly one `job_start` cycle per accepted command;
- rejection of start while busy or while the accelerator is not idle;
- frozen configuration during an active job;
- sticky done and error causes, independent interrupt enables, and W1C clears;
- error-code capture and error priority over simultaneous done;
- start/completion counter behavior;
- asynchronous reset after activity.

Local command, using Icarus Verilog 12.0:

```sh
iverilog -g2012 -Wall -s tb_dcse_apb3_ctrl \
  -o /tmp/dcse_apb3_ctrl.vvp \
  rtl/integration/dcse_apb3_ctrl.sv \
  sim/integration/tb_dcse_apb3_ctrl.sv
vvp /tmp/dcse_apb3_ctrl.vvp
```

Observed on 2026-08-15:

```text
PASS: dcse_apb3_ctrl completed 167 checks
```

This result establishes functional behavior in the supplied RTL testbench. It
does not establish APB compliance under every legal master sequence, timing
closure, resource use, or compatibility with a particular VEGA netlist.

The separate `dcse_apb_systolic_demo` test passes **112 checks** over two
signed N=4 jobs. It measures 10 clocks from raw GEMM busy to raw done, 11 from
accepted APB `CONTROL` access to raw done, and 12 from that access to sticky
done/IRQ. Matrices and results use direct packed ports; programmed address and
layer registers are not consumed. This proves a narrow control loop, not an
AXI/AHB memory path, DMA, cache/CDC behavior, or VEGA integration.

## Firmware-level transaction sequence

`DCSE_BASE` must remain symbolic until the SoC memory map is assigned.

```text
1. Allocate physically accessible input, weight, bias, descriptor, and output
   buffers.
2. Populate input buffers and validate layer index in software.
3. Flush dirty cache lines if the accelerator memory path is not coherent.
4. Write both halves of every 64-bit buffer address.
5. Write LAYER_INDEX.
6. Optionally enable done/error interrupts.
7. Write CONTROL.START = 1 and check the bus response.
8. Poll STATUS or wait for the assigned PLIC interrupt.
9. On error, read ERROR_CODE; acknowledge IRQ_STATUS with W1C.
10. Invalidate output cache lines if required, then consume the output.
```

Cache maintenance, physical-address translation, and ordering barriers depend
on the chosen VEGA SoC and software environment; they are requirements, not
features already provided by this RTL.

## Concrete path to a real VEGA build

1. Name the exact target: processor core, SoC, FPGA board, tool release, and
   accessible integration-tree commit.
2. Inspect the actual CPU/interconnect port (AXI4 or AHB), data/address widths,
   clock, reset, and interrupt conventions.
3. Decide whether to use the HLS AXI4-Lite control interface directly or place
   this APB programmer's model behind a verified bridge/wrapper.
4. Reserve a non-overlapping memory range in the SoC decoder and publish the
   same base address in RTL, linker/driver headers, and documentation.
5. Generate the HLS RTL and archive its exact AXI4-Lite register map rather
   than guessing offsets from the C pragmas.
6. Connect or arbitrate the five AXI4 memory bundles; define burst, width,
   outstanding-transaction, and fault behavior.
7. Assign a PLIC interrupt source, port and validate the generic driver, and
   make cache and memory-ordering rules explicit.
8. Add CDC/reset synchronizers if the accelerator and peripheral clocks differ.
9. Run bus protocol checkers, randomized stalls, reset-during-transaction,
   address-fault, timeout, and end-to-end software-oracle tests.
10. Archive synthesis/implementation reports and board measurements before
    making frequency, throughput, resource, or real-time claims.

Until those steps pass against a named SoC revision, the accurate status is:
“APB3 control, portable register API, and a direct-port APB-to-systolic demo are
implemented and simulation-checked; VEGA system integration is the next step.”
