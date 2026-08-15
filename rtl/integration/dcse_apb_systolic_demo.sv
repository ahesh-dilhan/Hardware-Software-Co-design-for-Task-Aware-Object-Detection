`timescale 1ns/1ps
`default_nettype none

// Minimal APB3-to-systolic integration demonstrator.
//
// This wrapper proves one narrow control path: software can launch the
// standalone systolic_gemm through dcse_apb3_ctrl, poll its busy/completion
// state, and receive an interrupt.  The complete A and B tiles remain explicit
// packed input ports and C remains an explicit packed output port.  Those
// direct ports deliberately stand in for a future memory/data-movement path.
//
// Scope boundary -- this module is NOT:
//   * a VEGA processor or VEGA SoC integration;
//   * an AXI-to-APB bridge, AXI master, DMA engine, or address consumer;
//   * a cache-coherent or cache-maintenance implementation;
//   * a clock-domain-crossing implementation; or
//   * a complete detector/convolution accelerator.
//
// The APB buffer-address and layer registers are retained and readable because
// they are part of dcse_apb3_ctrl, but this demonstrator does not consume them.
// PCLK clocks both contained blocks.  PRESETn is asynchronous for the APB
// control block and is sampled synchronously by systolic_gemm.
module dcse_apb_systolic_demo #(
    parameter int ADDR_WIDTH = 8,
    parameter int N          = 16,
    parameter int DATA_W     = 8,
    parameter int ACC_W      = 32
) (
    input  wire logic                       PCLK,
    input  wire logic                       PRESETn,
    input  wire logic                       PSEL,
    input  wire logic                       PENABLE,
    input  wire logic                       PWRITE,
    input  wire logic [ADDR_WIDTH-1:0]      PADDR,
    input  wire logic [31:0]                PWDATA,
    output      logic [31:0]                PRDATA,
    output      logic                       PREADY,
    output      logic                       PSLVERR,

    input  wire logic [(N*N*DATA_W)-1:0]    a_matrix_i,
    input  wire logic [(N*N*DATA_W)-1:0]    b_matrix_i,
    output      logic [(N*N*ACC_W)-1:0]     c_matrix_o,

    output      logic                       irq_o,
    output      logic                       accel_busy_o,
    output      logic                       accel_done_o
);

    logic [63:0] cfg_input_addr_unused;
    logic [63:0] cfg_weights_addr_unused;
    logic [63:0] cfg_bias_addr_unused;
    logic [63:0] cfg_descriptor_addr_unused;
    logic [63:0] cfg_output_addr_unused;
    logic [5:0]  cfg_layer_idx_unused;

    logic job_start;
    logic job_busy;
    logic gemm_busy;
    logic gemm_done;

    // The GEMM has no error output: its accepted operation has deterministic
    // latency and no runtime fault condition.  Error wiring is therefore tied
    // inactive rather than inventing an error mechanism this slice does not
    // implement.
    dcse_apb3_ctrl #(
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_ctrl (
        .PCLK                (PCLK),
        .PRESETn             (PRESETn),
        .PSEL                (PSEL),
        .PENABLE             (PENABLE),
        .PWRITE              (PWRITE),
        .PADDR               (PADDR),
        .PWDATA              (PWDATA),
        .PRDATA              (PRDATA),
        .PREADY              (PREADY),
        .PSLVERR             (PSLVERR),
        .cfg_input_addr      (cfg_input_addr_unused),
        .cfg_weights_addr    (cfg_weights_addr_unused),
        .cfg_bias_addr       (cfg_bias_addr_unused),
        .cfg_descriptor_addr (cfg_descriptor_addr_unused),
        .cfg_output_addr     (cfg_output_addr_unused),
        .cfg_layer_idx       (cfg_layer_idx_unused),
        .job_start           (job_start),
        .job_busy            (job_busy),
        .irq                 (irq_o),
        .accel_idle          (!gemm_busy),
        .accel_done          (gemm_done),
        .accel_error         (1'b0),
        .accel_error_code    (8'h00)
    );

    systolic_gemm #(
        .N      (N),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) u_gemm (
        .clk_i      (PCLK),
        .rst_ni     (PRESETn),
        .start_i    (job_start),
        .a_matrix_i (a_matrix_i),
        .b_matrix_i (b_matrix_i),
        .busy_o     (gemm_busy),
        .done_o     (gemm_done),
        .c_matrix_o (c_matrix_o)
    );

    assign accel_busy_o = gemm_busy;
    assign accel_done_o = gemm_done;

`ifndef SYNTHESIS
    // A control START must never reach a non-idle GEMM.  The APB block rejects
    // START while its own job is busy or while accel_idle is low.
    always @(posedge PCLK) begin
        if (PRESETn && job_start && gemm_busy)
            $error("dcse_apb_systolic_demo: GEMM start asserted while busy");

        // job_busy may lead gemm_busy during launch and trail it during
        // completion, but compute must never be active outside an APB job.
        if (PRESETn && gemm_busy && !job_busy)
            $error("dcse_apb_systolic_demo: GEMM active without APB job_busy");
    end
`endif

endmodule

`default_nettype wire
