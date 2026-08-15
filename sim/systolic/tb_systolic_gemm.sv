`timescale 1ns/1ps

// Deterministic, self-checking tests for the standalone systolic GEMM.
// The DUT is reduced to 4x4 here so wavefront timing is easy to inspect while
// exercising exactly the same parameterized RTL used by the default 16x16 case.
module tb_systolic_gemm;

    localparam int N             = 4;
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
    integer completed_cases;

    systolic_gemm #(
        .N      (N),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) dut (
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

    task automatic clear_matrices;
        integer row;
        integer col;
        begin
            a_matrix_i = '0;
            b_matrix_i = '0;
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    a_reference[row][col] = 0;
                    b_reference[row][col] = 0;
                end
            end
        end
    endtask

    task automatic set_a(
        input integer row,
        input integer col,
        input integer value
    );
        begin
            a_reference[row][col] = value;
            a_matrix_i[((row*N + col)*DATA_W) +: DATA_W] = value;
        end
    endtask

    task automatic set_b(
        input integer row,
        input integer col,
        input integer value
    );
        begin
            b_reference[row][col] = value;
            b_matrix_i[((row*N + col)*DATA_W) +: DATA_W] = value;
        end
    endtask

    task automatic calculate_reference;
        integer row;
        integer col;
        integer k;
        begin
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

    task automatic load_mixed_signed_case;
        integer row;
        integer col;
        begin
            clear_matrices();
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    set_a(row, col, ((row*11 + col*7 + 3) % 23) - 11);
                    set_b(row, col, ((row*5  + col*13 + 1) % 21) - 10);
                end
            end
        end
    endtask

    task automatic load_identity_case;
        integer row;
        integer col;
        begin
            clear_matrices();
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    set_a(row, col, (row*19) - (col*9) - 17);
                    set_b(row, col, (row == col) ? 1 : 0);
                end
            end
        end
    endtask

    task automatic load_extreme_signed_case;
        integer row;
        integer col;
        integer selector;
        begin
            clear_matrices();
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    selector = (row + col) % 3;
                    if (selector == 0) begin
                        set_a(row, col, -128);
                    end else if (selector == 1) begin
                        set_a(row, col, 127);
                    end else begin
                        set_a(row, col, -1);
                    end

                    set_b(row, col, ((row + 2*col) % 5) - 2);
                end
            end
        end
    endtask

    task automatic check_result(input string case_name);
        integer row;
        integer col;
        logic signed [ACC_W-1:0] observed;
        begin
            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    observed = $signed(
                        c_matrix_o[((row*N + col)*ACC_W) +: ACC_W]);
                    if (observed != expected[row][col]) begin
                        $error("%s: C[%0d][%0d] expected %0d, observed %0d",
                            case_name, row, col,
                            expected[row][col], observed);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    task automatic run_case(
        input string case_name,
        input bit pulse_start_while_busy
    );
        integer active_cycle;
        begin
            calculate_reference();

            // Launch on the next rising edge.  Tiles are stable before start.
            @(negedge clk_i);
            start_i = 1'b1;
            @(posedge clk_i);
            #1;
            if (!busy_o || done_o) begin
                $error("%s: launch was not accepted cleanly", case_name);
                errors = errors + 1;
            end
            @(negedge clk_i);
            start_i = 1'b0;

            // The first compute wavefront step is the first rising edge after
            // launch.  Completion must occur on exactly ACTIVE_CYCLES.
            for (active_cycle = 1;
                    active_cycle <= ACTIVE_CYCLES;
                    active_cycle = active_cycle + 1) begin
                @(posedge clk_i);
                #1;

                if (active_cycle < ACTIVE_CYCLES) begin
                    if (!busy_o || done_o) begin
                        $error("%s: early completion at active cycle %0d",
                            case_name, active_cycle);
                        errors = errors + 1;
                    end
                end else begin
                    if (busy_o || !done_o) begin
                        $error("%s: missing completion at active cycle %0d",
                            case_name, active_cycle);
                        errors = errors + 1;
                    end
                end

                // Exercise the documented rule that start_i is ignored while
                // busy.  Holding the same input tiles makes any accidental
                // accumulator clear visible as a result mismatch.
                if (pulse_start_while_busy && (active_cycle == 3)) begin
                    @(negedge clk_i);
                    start_i = 1'b1;
                end
                if (pulse_start_while_busy && (active_cycle == 4)) begin
                    @(negedge clk_i);
                    start_i = 1'b0;
                end
            end

            check_result(case_name);
            completed_cases = completed_cases + 1;
            $display("PASS: %s (%0d outputs, %0d active cycles)",
                case_name, N*N, ACTIVE_CYCLES);
        end
    endtask

    initial begin
        rst_ni          = 1'b0;
        start_i         = 1'b0;
        a_matrix_i      = '0;
        b_matrix_i      = '0;
        errors          = 0;
        completed_cases = 0;

        // Synchronous reset is held across three rising edges.
        repeat (3) @(posedge clk_i);
        @(negedge clk_i);
        rst_ni = 1'b1;

        load_mixed_signed_case();
        run_case("mixed signed matrices", 1'b1);

        // Each following load/launch begins at the earliest legal edge after
        // done_o, demonstrating repeated transactions without another reset.
        load_identity_case();
        run_case("identity multiplication", 1'b0);

        load_extreme_signed_case();
        run_case("INT8 sign-extension extremes", 1'b0);

        // done_o is a pulse, not a level that remains asserted while idle.
        @(posedge clk_i);
        #1;
        if (done_o) begin
            $error("done_o remained asserted for more than one clock");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: systolic_gemm completed %0d deterministic cases",
                completed_cases);
            $finish;
        end else begin
            $fatal(1, "FAIL: systolic_gemm testbench found %0d errors", errors);
        end
    end

    initial begin
        // Independent watchdog for deadlock or accidental clock-protocol edits.
        #5000;
        $fatal(1, "FAIL: systolic_gemm testbench timeout");
    end

endmodule
