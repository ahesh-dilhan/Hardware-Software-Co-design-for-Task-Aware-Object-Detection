`timescale 1ns/1ps

// Default-configuration smoke test for the standalone systolic GEMM.
// This intentionally instantiates systolic_gemm without parameter overrides,
// checks every result of a fully populated signed 16x16 multiplication, and
// enforces the documented 3*N-2 = 46 active-cycle completion time.
module tb_systolic_gemm_n16;

    localparam int N             = 16;
    localparam int DATA_W        = 8;
    localparam int ACC_W         = 32;
    localparam int ACTIVE_CYCLES = (3*N) - 2;

    logic                       clk_i;
    logic                       rst_ni;
    logic                       start_i;
    logic [(N*N*DATA_W)-1:0]    a_matrix_i;
    logic [(N*N*DATA_W)-1:0]    b_matrix_i;
    logic                       busy_o;
    logic                       done_o;
    logic [(N*N*ACC_W)-1:0]     c_matrix_o;

    integer a_reference [0:N-1][0:N-1];
    integer b_reference [0:N-1][0:N-1];
    longint signed expected [0:N-1][0:N-1];
    integer errors;

    // No parameter override: this verifies the public default configuration.
    systolic_gemm dut (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .start_i     (start_i),
        .a_matrix_i  (a_matrix_i),
        .b_matrix_i  (b_matrix_i),
        .busy_o      (busy_o),
        .done_o      (done_o),
        .c_matrix_o  (c_matrix_o)
    );

    initial clk_i = 1'b0;
    always #5 clk_i = ~clk_i;

    task automatic load_inputs_and_reference;
        integer row;
        integer col;
        integer k;
        integer a_value;
        integer b_value;
        begin
            a_matrix_i = '0;
            b_matrix_i = '0;

            // Both matrices are non-symmetric and fully populated.  The A
            // pattern spans negative and positive INT8 values; the smaller B
            // coefficients keep the exact dot products comfortably in INT32.
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    a_value = ((row*29 + col*17 + 5) % 255) - 127;
                    b_value = ((row*7  + col*11 + 3) % 9) - 4;
                    a_reference[row][col] = a_value;
                    b_reference[row][col] = b_value;
                    a_matrix_i[((row*N + col)*DATA_W) +: DATA_W] = a_value;
                    b_matrix_i[((row*N + col)*DATA_W) +: DATA_W] = b_value;
                end
            end

            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    expected[row][col] = 0;
                    for (k = 0; k < N; k = k + 1) begin
                        expected[row][col] = expected[row][col]
                            + (a_reference[row][k] * b_reference[k][col]);
                    end
                end
            end
        end
    endtask

    task automatic check_all_outputs;
        integer row;
        integer col;
        logic signed [ACC_W-1:0] observed;
        begin
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    observed = $signed(
                        c_matrix_o[((row*N + col)*ACC_W) +: ACC_W]);
                    if (observed != expected[row][col]) begin
                        $error("N16: C[%0d][%0d] expected %0d, observed %0d",
                            row, col, expected[row][col], observed);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    initial begin : run_smoke_test
        integer active_cycle;

        rst_ni     = 1'b0;
        start_i    = 1'b0;
        a_matrix_i = '0;
        b_matrix_i = '0;
        errors     = 0;

        repeat (3) @(posedge clk_i);
        @(negedge clk_i);
        rst_ni = 1'b1;

        load_inputs_and_reference();

        @(negedge clk_i);
        start_i = 1'b1;
        @(posedge clk_i);
        #1;
        if (!busy_o || done_o) begin
            $error("N16: launch was not accepted cleanly");
            errors = errors + 1;
        end
        @(negedge clk_i);
        start_i = 1'b0;

        for (active_cycle = 1;
                active_cycle <= ACTIVE_CYCLES;
                active_cycle = active_cycle + 1) begin
            @(posedge clk_i);
            #1;
            if (active_cycle < ACTIVE_CYCLES) begin
                if (!busy_o || done_o) begin
                    $error("N16: early completion at active cycle %0d",
                        active_cycle);
                    errors = errors + 1;
                end
            end else if (busy_o || !done_o) begin
                $error("N16: missing completion at active cycle %0d",
                    active_cycle);
                errors = errors + 1;
            end
        end

        check_all_outputs();

        @(posedge clk_i);
        #1;
        if (done_o) begin
            $error("N16: done_o remained asserted for more than one clock");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: default N=16 systolic_gemm checked 256 outputs in 46 active cycles");
            $finish;
        end else begin
            $fatal(1, "FAIL: default N=16 smoke test found %0d errors", errors);
        end
    end

    initial begin
        #2000;
        $fatal(1, "FAIL: default N=16 smoke test timeout");
    end

endmodule
