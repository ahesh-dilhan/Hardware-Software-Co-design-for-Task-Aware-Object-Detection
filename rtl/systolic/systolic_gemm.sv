`timescale 1ns/1ps

// One processing element (PE) in an output-stationary systolic GEMM array.
//
// On every asserted step_i:
//   * the west operand is registered and forwarded one column east;
//   * the north operand is registered and forwarded one row south; and
//   * when both valid bits are set, their signed product is accumulated locally.
//
// The accumulator never moves between PEs, hence "output stationary".  The
// forwarding registers make operand movement explicitly neighbor-to-neighbor;
// there is no combinational broadcast across a row or column.
module systolic_gemm_pe #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         clear_i,
    input  logic                         step_i,

    input  logic signed [DATA_W-1:0]     a_west_i,
    input  logic                         a_west_valid_i,
    input  logic signed [DATA_W-1:0]     b_north_i,
    input  logic                         b_north_valid_i,

    output logic signed [DATA_W-1:0]     a_east_o,
    output logic                         a_east_valid_o,
    output logic signed [DATA_W-1:0]     b_south_o,
    output logic                         b_south_valid_o,
    output logic signed [ACC_W-1:0]      accumulator_o
);

    // Form the full DATA_W-by-DATA_W signed product before assigning it into
    // the wider accumulator domain.  This avoids relying on expression-size
    // rules for sign extension.
    function automatic logic signed [ACC_W-1:0] product_for_accumulator(
        input logic signed [DATA_W-1:0] lhs,
        input logic signed [DATA_W-1:0] rhs
    );
        logic signed [(2*DATA_W)-1:0] full_product;
        begin
            full_product            = lhs * rhs;
            product_for_accumulator = full_product;
        end
    endfunction

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            a_east_o         <= '0;
            a_east_valid_o   <= 1'b0;
            b_south_o        <= '0;
            b_south_valid_o  <= 1'b0;
            accumulator_o    <= '0;
        end else if (clear_i) begin
            a_east_o         <= '0;
            a_east_valid_o   <= 1'b0;
            b_south_o        <= '0;
            b_south_valid_o  <= 1'b0;
            accumulator_o    <= '0;
        end else if (step_i) begin
            a_east_o         <= a_west_i;
            a_east_valid_o   <= a_west_valid_i;
            b_south_o        <= b_north_i;
            b_south_valid_o  <= b_north_valid_i;

            if (a_west_valid_i && b_north_valid_i) begin
                accumulator_o <= accumulator_o
                               + product_for_accumulator(a_west_i, b_north_i);
            end
        end
    end

`ifndef SYNTHESIS
    // Correct wavefront scheduling presents A[i,k] and B[k,j] together.  A
    // one-sided valid at any PE indicates a skew/forwarding control defect.
    always @(posedge clk_i) begin
        if (rst_ni && step_i
                && (a_west_valid_i !== b_north_valid_i)) begin
            $error("systolic_gemm_pe: misaligned operand valid signals");
        end
    end
`endif

endmodule


// Parameterized square, output-stationary systolic matrix-multiply primitive.
// Computes C = A * B for one signed N-by-N tile.  It intentionally contains no
// detector, convolution im2col engine, memory DMA, processor bus, or software
// integration; those functions belong in wrappers around this standalone GEMM.
//
// Matrix ports are packed in row-major order.  Element [row][column] occupies:
//   matrix[((row*N + column)*WIDTH) +: WIDTH]
//
// Cycle protocol (all events occur on rising clk_i edges):
//
//   E0: start_i is accepted only when busy_o == 0.  Each A row and B column is
//       loaded into a word-shift feeder queue, every PE accumulator/forwarding
//       register is cleared, and busy_o becomes 1.
//
//   E0+1+s, s=0..3*N-3: one systolic step is performed per clock.
//       A[row][k] is injected at the west edge when s = row + k.
//       B[k][col] is injected at the north edge when s = col + k.
//       Each PE[row][col] therefore consumes the aligned pair at
//       s = row + col + k, for k=0..N-1.
//
//   E0+(3*N-2): the final products are accumulated, busy_o deasserts, and
//       done_o pulses for one clock.  c_matrix_o contains the completed tile
//       after that edge and remains stable until the next accepted start_i.
//
// Inputs may change after E0 because the complete tiles are latched internally.
// start_i is ignored while busy_o is asserted.  There is deliberately no
// backpressure within a tile: after acceptance the latency is fixed at 3*N-2
// clocks.  rst_ni is an active-low synchronous reset.
module systolic_gemm #(
    parameter int N      = 16,
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         start_i,
    input  logic [(N*N*DATA_W)-1:0]      a_matrix_i,
    input  logic [(N*N*DATA_W)-1:0]      b_matrix_i,

    output logic                         busy_o,
    output logic                         done_o,
    output logic [(N*N*ACC_W)-1:0]       c_matrix_o
);

    localparam int LAST_STEP = (3*N) - 3;
    localparam int CYCLE_W   = (LAST_STEP < 1) ? 1 : $clog2(LAST_STEP + 1);

    logic [CYCLE_W-1:0] cycle_q;

    // Each packed feeder stores element k in word k, with k=0 in its least
    // significant DATA_W bits.  A feeder's boundary is therefore a fixed
    // part-select rather than an N:1, cycle-indexed data mux.  The queue shifts
    // right by one word only while its row/column injection window is active.
    logic [(N*DATA_W)-1:0] a_row_feeder_q [0:N-1];
    logic [(N*DATA_W)-1:0] b_col_feeder_q [0:N-1];

    // Hop index 0 is the array boundary.  Every later hop is driven only by
    // the registered output of the immediately preceding PE.
    wire signed [DATA_W-1:0] a_hop       [0:N-1][0:N];
    wire                     a_valid_hop [0:N-1][0:N];
    wire signed [DATA_W-1:0] b_hop       [0:N][0:N-1];
    wire                     b_valid_hop [0:N][0:N-1];
    wire signed [ACC_W-1:0]  accumulator [0:N-1][0:N-1];

    wire clear_pes = start_i && !busy_o;

    generate
        for (genvar boundary = 0; boundary < N; boundary = boundary + 1) begin : g_boundary
            // The boundary data path is a fixed word-zero connection.  Only
            // these one-bit valids implement the row/column time skew.
            assign a_hop[boundary][0]
                = $signed(a_row_feeder_q[boundary][0 +: DATA_W]);
            assign a_valid_hop[boundary][0]
                = busy_o
                && (cycle_q >= boundary)
                && (cycle_q < (boundary + N));
            assign b_hop[0][boundary]
                = $signed(b_col_feeder_q[boundary][0 +: DATA_W]);
            assign b_valid_hop[0][boundary]
                = busy_o
                && (cycle_q >= boundary)
                && (cycle_q < (boundary + N));
        end

        for (genvar row = 0; row < N; row = row + 1) begin : g_row
            for (genvar col = 0; col < N; col = col + 1) begin : g_col
                systolic_gemm_pe #(
                    .DATA_W (DATA_W),
                    .ACC_W  (ACC_W)
                ) u_pe (
                    .clk_i             (clk_i),
                    .rst_ni            (rst_ni),
                    .clear_i           (clear_pes),
                    .step_i            (busy_o),
                    .a_west_i          (a_hop[row][col]),
                    .a_west_valid_i    (a_valid_hop[row][col]),
                    .b_north_i         (b_hop[row][col]),
                    .b_north_valid_i   (b_valid_hop[row][col]),
                    .a_east_o          (a_hop[row][col+1]),
                    .a_east_valid_o    (a_valid_hop[row][col+1]),
                    .b_south_o         (b_hop[row+1][col]),
                    .b_south_valid_o   (b_valid_hop[row+1][col]),
                    .accumulator_o     (accumulator[row][col])
                );
            end
        end
    endgenerate

    // Row-major packing of the stationary PE accumulators.
    always_comb begin : pack_result
        integer row;
        integer col;
        c_matrix_o = '0;
        for (row = 0; row < N; row = row + 1) begin
            for (col = 0; col < N; col = col + 1) begin
                c_matrix_o[((row*N + col)*ACC_W) +: ACC_W]
                    = accumulator[row][col];
            end
        end
    end

    // Transaction controller and fixed-index row/column feeder queues.
    always_ff @(posedge clk_i) begin : control_and_capture
        integer row;
        integer col;

        if (!rst_ni) begin
            busy_o <= 1'b0;
            done_o <= 1'b0;
            cycle_q <= '0;
            for (row = 0; row < N; row = row + 1) begin
                a_row_feeder_q[row] <= '0;
                b_col_feeder_q[row] <= '0;
            end
        end else begin
            done_o <= 1'b0;

            if (!busy_o) begin
                busy_o  <= 1'b0;
                cycle_q <= '0;

                if (start_i) begin
                    busy_o <= 1'b1;
                    for (row = 0; row < N; row = row + 1) begin
                        // A row is contiguous in the row-major input port.
                        a_row_feeder_q[row]
                            <= a_matrix_i[(row*N*DATA_W) +: (N*DATA_W)];

                        // B is row-major at the port, so gather each column
                        // into one feeder with k=0 at the queue head.
                        for (col = 0; col < N; col = col + 1) begin
                            b_col_feeder_q[row][col*DATA_W +: DATA_W]
                                <= b_matrix_i[((col*N + row)*DATA_W) +: DATA_W];
                        end
                    end
                end
            end else begin
                // A queue shifts on exactly the N cycles in which its row is
                // injecting.  The PE consumes the pre-shift word zero on this
                // edge; nonblocking assignment exposes the next word afterward.
                for (row = 0; row < N; row = row + 1) begin
                    if ((cycle_q >= row) && (cycle_q < (row + N))) begin
                        a_row_feeder_q[row]
                            <= a_row_feeder_q[row] >> DATA_W;
                    end
                end

                // The same fixed-head queue discipline feeds B down columns.
                for (col = 0; col < N; col = col + 1) begin
                    if ((cycle_q >= col) && (cycle_q < (col + N))) begin
                        b_col_feeder_q[col]
                            <= b_col_feeder_q[col] >> DATA_W;
                    end
                end

                if (cycle_q == LAST_STEP) begin
                    // The PEs perform LAST_STEP on this same edge.  Their NBA
                    // accumulator updates and done_o become visible together.
                    busy_o  <= 1'b0;
                    done_o  <= 1'b1;
                    cycle_q <= '0;
                end else begin
                    cycle_q <= cycle_q + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (N < 1) begin
            $fatal(1, "systolic_gemm: N must be at least one");
        end
        if (DATA_W < 1) begin
            $fatal(1, "systolic_gemm: DATA_W must be at least one");
        end
        if (ACC_W < ((2*DATA_W) + $clog2(N))) begin
            $fatal(1,
                "systolic_gemm: ACC_W is too small for an untruncated N-term dot product");
        end
    end
`endif

endmodule
