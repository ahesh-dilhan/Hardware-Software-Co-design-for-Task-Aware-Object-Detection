`timescale 1ns/1ps
`default_nettype none

module tb_dcse_apb_systolic_demo;

    localparam int N       = 4;
    localparam int DATA_W  = 8;
    localparam int ACC_W   = 32;
    localparam int LATENCY = (3*N) - 2;

    localparam logic [7:0] REG_CONTROL        = 8'h08;
    localparam logic [7:0] REG_STATUS         = 8'h0c;
    localparam logic [7:0] REG_IRQ_ENABLE     = 8'h10;
    localparam logic [7:0] REG_IRQ_STATUS     = 8'h14;
    localparam logic [7:0] REG_LAYER_INDEX    = 8'h18;
    localparam logic [7:0] REG_INPUT_ADDR_LO  = 8'h20;
    localparam logic [7:0] REG_INPUT_ADDR_HI  = 8'h24;
    localparam logic [7:0] REG_START_COUNT    = 8'h48;
    localparam logic [7:0] REG_COMPLETE_COUNT = 8'h4c;

    logic        PCLK;
    logic        PRESETn;
    logic        PSEL;
    logic        PENABLE;
    logic        PWRITE;
    logic [7:0]  PADDR;
    logic [31:0] PWDATA;
    logic [31:0] PRDATA;
    logic        PREADY;
    logic        PSLVERR;

    logic [(N*N*DATA_W)-1:0] a_matrix;
    logic [(N*N*DATA_W)-1:0] b_matrix;
    logic [(N*N*ACC_W)-1:0]  c_matrix;
    logic                     irq;
    logic                     accel_busy;
    logic                     accel_done;

    integer a_values [0:(N*N)-1];
    integer b_values [0:(N*N)-1];
    integer expected [0:(N*N)-1];
    integer checks;
    integer failures;
    integer latency;
    integer row;
    integer col;
    integer k;
    integer index;
    integer actual;
    integer clock_edge_count;
    integer first_control_access_edge;
    integer first_busy_edge;
    integer first_raw_done_edge;
    integer first_sticky_done_edge;
    integer second_control_access_edge;
    integer second_busy_edge;
    integer second_raw_done_edge;
    integer second_sticky_done_edge;
    logic [31:0] read_data;

    dcse_apb_systolic_demo #(
        .N      (N),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) dut (
        .PCLK         (PCLK),
        .PRESETn      (PRESETn),
        .PSEL         (PSEL),
        .PENABLE      (PENABLE),
        .PWRITE       (PWRITE),
        .PADDR        (PADDR),
        .PWDATA       (PWDATA),
        .PRDATA       (PRDATA),
        .PREADY       (PREADY),
        .PSLVERR      (PSLVERR),
        .a_matrix_i   (a_matrix),
        .b_matrix_i   (b_matrix),
        .c_matrix_o   (c_matrix),
        .irq_o        (irq),
        .accel_busy_o (accel_busy),
        .accel_done_o (accel_done)
    );

    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    // Monotonic rising-edge timestamp for explicit interface-boundary timing
    // checks.  Sampling is done after #1 in the transaction tasks so this
    // blocking testbench counter and all DUT nonblocking updates have settled.
    always @(posedge PCLK)
        clock_edge_count = clock_edge_count + 1;

    // Independent watchdog: no defect in an APB task or transaction wait may
    // leave an unattended regression running forever.
    initial begin : test_watchdog
        repeat (500) @(posedge PCLK);
        $fatal(1, "timeout: APB-to-systolic integration test did not finish");
    end

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic apb_write(
        input logic [7:0] address,
        input logic [31:0] data,
        input logic expected_error
    );
        begin
            // APB setup phase.
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b1;
            PADDR   = address;
            PWDATA  = data;
            #1;
            check(PSLVERR === 1'b0,
                  "PSLVERR must remain low in APB setup phase");

            // APB access phase.  The slave is zero-wait-state.
            @(negedge PCLK);
            PENABLE = 1'b1;
            #1;
            check(PREADY === 1'b1, "PREADY must be high");
            check(PSLVERR === expected_error,
                  "write PSLVERR did not match expectation");

            @(posedge PCLK);
            #1;
            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = '0;
            PWDATA  = '0;
        end
    endtask

    task automatic apb_read(
        input  logic [7:0] address,
        input  logic expected_error,
        output logic [31:0] data
    );
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = address;
            PWDATA  = '0;
            #1;
            check(PSLVERR === 1'b0,
                  "PSLVERR must remain low in APB setup phase");

            @(negedge PCLK);
            PENABLE = 1'b1;
            #1;
            check(PREADY === 1'b1, "PREADY must be high");
            check(PSLVERR === expected_error,
                  "read PSLVERR did not match expectation");
            data = PRDATA;

            @(posedge PCLK);
            #1;
            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PADDR   = '0;
        end
    endtask

    task automatic load_case(input integer case_number);
        begin
            if (case_number == 1) begin
                a_values[ 0] =    1; a_values[ 1] =   -2;
                a_values[ 2] =    3; a_values[ 3] =    4;
                a_values[ 4] =   -5; a_values[ 5] =    6;
                a_values[ 6] =    7; a_values[ 7] =   -8;
                a_values[ 8] =    9; a_values[ 9] =   10;
                a_values[10] =  -11; a_values[11] =   12;
                a_values[12] =  -13; a_values[13] =   14;
                a_values[14] =   15; a_values[15] =   16;

                b_values[ 0] =   -1; b_values[ 1] =    2;
                b_values[ 2] =    0; b_values[ 3] =    3;
                b_values[ 4] =    4; b_values[ 5] =   -5;
                b_values[ 6] =    6; b_values[ 7] =    0;
                b_values[ 8] =    7; b_values[ 9] =    8;
                b_values[10] =   -9; b_values[11] =   10;
                b_values[12] =    0; b_values[13] =   11;
                b_values[14] =   12; b_values[15] =  -13;
            end else begin
                // Signed extremes multiplied by an identity matrix make the
                // expected second result visually and numerically distinct.
                a_values[ 0] = -128; a_values[ 1] =  127;
                a_values[ 2] =   -1; a_values[ 3] =    0;
                a_values[ 4] =   64; a_values[ 5] =  -64;
                a_values[ 6] =   32; a_values[ 7] =  -32;
                a_values[ 8] =    5; a_values[ 9] =    6;
                a_values[10] =    7; a_values[11] =    8;
                a_values[12] =   -9; a_values[13] =   10;
                a_values[14] =  -11; a_values[15] =   12;

                for (index = 0; index < (N*N); index = index + 1)
                    b_values[index] = 0;
                b_values[ 0] = 1;
                b_values[ 5] = 1;
                b_values[10] = 1;
                b_values[15] = 1;
            end

            a_matrix = '0;
            b_matrix = '0;
            for (index = 0; index < (N*N); index = index + 1) begin
                a_matrix[(index*DATA_W) +: DATA_W] = a_values[index];
                b_matrix[(index*DATA_W) +: DATA_W] = b_values[index];
            end

            for (row = 0; row < N; row = row + 1) begin
                for (col = 0; col < N; col = col + 1) begin
                    expected[(row*N) + col] = 0;
                    for (k = 0; k < N; k = k + 1) begin
                        expected[(row*N) + col]
                            = expected[(row*N) + col]
                            + (a_values[(row*N) + k]
                               * b_values[(k*N) + col]);
                    end
                end
            end
        end
    endtask

    task automatic wait_for_gemm_completion(
        output integer measured_latency,
        output integer busy_rise_edge,
        output integer raw_done_edge
    );
        integer launch_wait_cycles;
        begin
            // busy rises on the GEMM's accepted-start edge.  Count subsequent
            // rising edges through the raw one-cycle done pulse.
            launch_wait_cycles = 0;
            while (accel_busy !== 1'b1) begin
                @(posedge PCLK);
                #1;
                launch_wait_cycles = launch_wait_cycles + 1;
                if (launch_wait_cycles > 4)
                    $fatal(1, "timeout waiting for accepted START to raise busy");
            end

            busy_rise_edge = clock_edge_count;

            measured_latency = 0;
            while (accel_done !== 1'b1) begin
                @(posedge PCLK);
                #1;
                measured_latency = measured_latency + 1;
                if (measured_latency > (LATENCY + 2)) begin
                    $fatal(1, "timeout waiting for systolic completion");
                end
            end
            raw_done_edge = clock_edge_count;
        end
    endtask

    task automatic check_result(input integer case_number);
        begin
            for (index = 0; index < (N*N); index = index + 1) begin
                actual = $signed(c_matrix[(index*ACC_W) +: ACC_W]);
                check(actual == expected[index],
                      $sformatf("case %0d C[%0d][%0d]: got %0d expected %0d",
                                case_number, index/N, index%N,
                                actual, expected[index]));
            end
        end
    endtask

    initial begin
        checks   = 0;
        failures = 0;
        clock_edge_count = 0;
        PRESETn  = 1'b0;
        PSEL     = 1'b0;
        PENABLE  = 1'b0;
        PWRITE   = 1'b0;
        PADDR    = '0;
        PWDATA   = '0;
        a_matrix = '0;
        b_matrix = '0;

        repeat (3) @(posedge PCLK);
        #1;
        check(accel_busy === 1'b0, "GEMM busy reset value");
        check(accel_done === 1'b0, "GEMM done reset value");
        check(irq === 1'b0, "IRQ reset value");
        check(c_matrix == '0, "GEMM result reset value");

        @(negedge PCLK);
        PRESETn = 1'b1;

        // These APB descriptor fields are exercised as control-block state.
        // The demonstrator intentionally does not use them to fetch matrices.
        apb_write(REG_INPUT_ADDR_LO, 32'h1234_0000, 1'b0);
        apb_write(REG_INPUT_ADDR_HI, 32'h0000_0001, 1'b0);
        apb_write(REG_LAYER_INDEX,   32'd7,         1'b0);
        apb_read(REG_INPUT_ADDR_LO, 1'b0, read_data);
        check(read_data == 32'h1234_0000, "descriptor register readback");
        apb_read(REG_LAYER_INDEX, 1'b0, read_data);
        check(read_data == 32'd7, "layer register readback");

        // Enable completion IRQs and launch the first signed GEMM through APB.
        apb_write(REG_IRQ_ENABLE, 32'h0000_0001, 1'b0);
        load_case(1);
        apb_write(REG_CONTROL, 32'h0000_0001, 1'b0);
        // apb_write returns at the falling edge immediately following the
        // accepted APB access edge, before another rising edge can occur.
        first_control_access_edge = clock_edge_count;

        fork
            begin : monitor_first_gemm
                wait_for_gemm_completion(
                    latency, first_busy_edge, first_raw_done_edge);
            end
            begin : exercise_apb_during_first_gemm
                wait (accel_busy === 1'b1);

                // Inputs may change once the GEMM has captured its tiles.
                a_matrix = '0;
                b_matrix = '0;

                apb_read(REG_STATUS, 1'b0, read_data);
                check(read_data[0] === 1'b1, "APB status reports job busy");
                check(read_data[3] === 1'b0,
                      "APB status reports accelerator non-idle");

                // A second launch is rejected while the first job is active.
                apb_write(REG_CONTROL, 32'h0000_0001, 1'b1);
                apb_read(REG_START_COUNT, 1'b0, read_data);
                check(read_data == 32'd1, "busy START is not counted");
            end
        join

        check((first_raw_done_edge - first_busy_edge) == LATENCY,
              $sformatf("first raw busy-to-done: got %0d expected %0d edges",
                        first_raw_done_edge - first_busy_edge, LATENCY));
        check(latency == LATENCY,
              $sformatf("first GEMM latency counter: got %0d expected %0d",
                        latency, LATENCY));
        check((first_raw_done_edge - first_control_access_edge)
                  == (LATENCY + 1),
              $sformatf("first APB-access-to-raw-done: got %0d expected %0d edges",
                        first_raw_done_edge - first_control_access_edge,
                        LATENCY + 1));
        check_result(1);

        // dcse_apb3_ctrl samples the raw GEMM done pulse on this next edge.
        @(posedge PCLK);
        #1;
        first_sticky_done_edge = clock_edge_count;
        check((first_sticky_done_edge - first_control_access_edge)
                  == (LATENCY + 2),
              $sformatf("first APB-access-to-sticky-done: got %0d expected %0d edges",
                        first_sticky_done_edge - first_control_access_edge,
                        LATENCY + 2));
        check(irq === 1'b1, "completion raises enabled IRQ");
        apb_read(REG_STATUS, 1'b0, read_data);
        check(read_data[4:0] == 5'b1_1010,
              "APB status reports idle, sticky done, and IRQ");
        apb_read(REG_COMPLETE_COUNT, 1'b0, read_data);
        check(read_data == 32'd1, "first completion counted");
        apb_write(REG_IRQ_STATUS, 32'h0000_0001, 1'b0);
        check(irq === 1'b0, "done W1C clears first IRQ");

        // A second transaction verifies restart behavior, signed INT8
        // extremes, result replacement, counters, and a second W1C sequence.
        load_case(2);
        apb_write(REG_CONTROL, 32'h0000_0001, 1'b0);
        second_control_access_edge = clock_edge_count;
        wait_for_gemm_completion(
            latency, second_busy_edge, second_raw_done_edge);
        check((second_raw_done_edge - second_busy_edge) == LATENCY,
              $sformatf("second raw busy-to-done: got %0d expected %0d edges",
                        second_raw_done_edge - second_busy_edge, LATENCY));
        check(latency == LATENCY,
              $sformatf("second GEMM latency counter: got %0d expected %0d",
                        latency, LATENCY));
        check((second_raw_done_edge - second_control_access_edge)
                  == (LATENCY + 1),
              $sformatf("second APB-access-to-raw-done: got %0d expected %0d edges",
                        second_raw_done_edge - second_control_access_edge,
                        LATENCY + 1));
        check_result(2);

        @(posedge PCLK);
        #1;
        second_sticky_done_edge = clock_edge_count;
        check((second_sticky_done_edge - second_control_access_edge)
                  == (LATENCY + 2),
              $sformatf("second APB-access-to-sticky-done: got %0d expected %0d edges",
                        second_sticky_done_edge - second_control_access_edge,
                        LATENCY + 2));
        check(irq === 1'b1, "second completion raises IRQ");
        apb_read(REG_START_COUNT, 1'b0, read_data);
        check(read_data == 32'd2, "two accepted STARTs counted");
        apb_read(REG_COMPLETE_COUNT, 1'b0, read_data);
        check(read_data == 32'd2, "two completions counted");
        apb_read(REG_IRQ_STATUS, 1'b0, read_data);
        check(read_data[1:0] == 2'b01, "done cause is sticky");
        apb_write(REG_IRQ_STATUS, 32'h0000_0001, 1'b0);
        check(irq === 1'b0, "second done W1C clears IRQ");

        if (failures == 0) begin
            $display("PASS: APB-to-systolic demo checked two N=%0d GEMMs; busy-to-raw-done=%0d, APB-access-to-raw-done=%0d, APB-access-to-sticky-done/IRQ=%0d clocks; counters and W1C verified (%0d checks)",
                     N, LATENCY, LATENCY + 1, LATENCY + 2, checks);
            $finish;
        end

        $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
    end

endmodule

`default_nettype wire
