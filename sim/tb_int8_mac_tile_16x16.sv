`timescale 1ns/1ps

module tb_int8_mac_tile_16x16;

    localparam integer LANES      = 16;
    localparam integer OUTPUTS    = 16;
    localparam integer DATA_WIDTH = 8;
    localparam integer ACC_WIDTH  = 32;
    localparam integer RESULT_WIDTH = OUTPUTS * ACC_WIDTH;

    reg clk = 1'b0;
    reg aresetn = 1'b0;
    reg s_valid = 1'b0;
    wire s_ready;
    reg signed [LANES*DATA_WIDTH-1:0] s_activations = '0;
    reg signed [OUTPUTS*LANES*DATA_WIDTH-1:0] s_weights = '0;
    reg signed [OUTPUTS*ACC_WIDTH-1:0] s_bias = '0;
    reg s_residual_enable = 1'b0;
    reg signed [OUTPUTS*ACC_WIDTH-1:0] s_residual = '0;
    wire m_valid;
    reg m_ready = 1'b0;
    wire signed [RESULT_WIDTH-1:0] m_accumulators;

    integer expected_current [0:OUTPUTS-1];
    integer expected_first   [0:OUTPUTS-1];
    integer expected_second  [0:OUTPUTS-1];
    integer expected_third   [0:OUTPUTS-1];
    integer output_channel;
    reg [RESULT_WIDTH-1:0] held_result;

    always #5 clk = ~clk;

    int8_mac_tile_16x16 #(
        .LANES(LANES),
        .OUTPUTS(OUTPUTS),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .aresetn(aresetn),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_activations(s_activations),
        .s_weights(s_weights),
        .s_bias(s_bias),
        .s_residual_enable(s_residual_enable),
        .s_residual(s_residual),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_accumulators(m_accumulators)
    );

    function automatic integer activation_for;
        input integer case_id;
        input integer lane;
        begin
            case (case_id)
                0: activation_for = lane - 8;
                1: activation_for = (lane % 2 == 0) ? 127 : -128;
                default: activation_for = 1;
            endcase
        end
    endfunction

    function automatic integer weight_for;
        input integer case_id;
        input integer oc;
        input integer lane;
        begin
            case (case_id)
                0: weight_for = ((oc*3 + lane*5) % 17) - 8;
                1: weight_for = ((oc + lane) % 7) - 3;
                default: weight_for = oc - 8;
            endcase
        end
    endfunction

    task automatic build_case;
        input integer case_id;
        integer lane;
        integer oc;
        integer activation_value;
        integer weight_value;
        integer bias_value;
        integer residual_value;
        integer accumulator;
        begin
            s_activations = '0;
            s_weights = '0;
            s_bias = '0;
            s_residual = '0;
            s_residual_enable = (case_id == 1);

            for (lane = 0; lane < LANES; lane = lane + 1) begin
                activation_value = activation_for(case_id, lane);
                s_activations[lane*DATA_WIDTH +: DATA_WIDTH] =
                    activation_value[DATA_WIDTH-1:0];
            end

            for (oc = 0; oc < OUTPUTS; oc = oc + 1) begin
                bias_value = oc*13 - 70;
                // Case 1 models a seven-channel identity input: lanes 7..15
                // must contribute zero, matching the HLS residual boundary.
                residual_value = (case_id == 1 && oc >= 7) ?
                    0 : oc*101 - 500;
                if (case_id == 2) begin
                    bias_value = oc*10;
                    residual_value = 0;
                end

                s_bias[oc*ACC_WIDTH +: ACC_WIDTH] = bias_value;
                s_residual[oc*ACC_WIDTH +: ACC_WIDTH] = residual_value;
                accumulator = bias_value;
                if (s_residual_enable)
                    accumulator = accumulator + residual_value;

                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    activation_value = activation_for(case_id, lane);
                    weight_value = weight_for(case_id, oc, lane);
                    s_weights[(oc*LANES + lane)*DATA_WIDTH +: DATA_WIDTH] =
                        weight_value[DATA_WIDTH-1:0];
                    accumulator = accumulator + activation_value*weight_value;
                end
                expected_current[oc] = accumulator;
            end
        end
    endtask

    task automatic check_result;
        input integer expected_set;
        integer oc;
        integer expected_value;
        reg signed [ACC_WIDTH-1:0] actual_value;
        begin
            if (!m_valid)
                $fatal(1, "Expected a valid result");

            for (oc = 0; oc < OUTPUTS; oc = oc + 1) begin
                case (expected_set)
                    0: expected_value = expected_first[oc];
                    1: expected_value = expected_second[oc];
                    default: expected_value = expected_third[oc];
                endcase
                actual_value = m_accumulators[oc*ACC_WIDTH +: ACC_WIDTH];
                if (actual_value !== expected_value)
                    $fatal(1,
                        "Set %0d output %0d: expected %0d, received %0d",
                        expected_set, oc, expected_value, actual_value);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;

        // First transaction.
        build_case(0);
        for (output_channel = 0; output_channel < OUTPUTS;
             output_channel = output_channel + 1)
            expected_first[output_channel] = expected_current[output_channel];
        s_valid = 1'b1;
        m_ready = 1'b1;
        @(posedge clk);
        if (!s_ready)
            $fatal(1, "First transaction was not accepted");

        // Present a second transaction immediately.  The old result is
        // consumed on the same edge that the new one is accepted.
        @(negedge clk);
        check_result(0);
        build_case(1);
        for (output_channel = 0; output_channel < OUTPUTS;
             output_channel = output_channel + 1)
            expected_second[output_channel] = expected_current[output_channel];
        @(posedge clk);
        if (!s_ready)
            $fatal(1, "Back-to-back transaction was not accepted");

        // Stall the second result and prove all output bits remain stable.
        @(negedge clk);
        check_result(1);
        s_valid = 1'b0;
        m_ready = 1'b0;
        held_result = m_accumulators;
        repeat (4) begin
            @(negedge clk);
            if (!m_valid || m_accumulators !== held_result)
                $fatal(1, "Output changed while downstream was stalled");
            if (s_ready)
                $fatal(1, "Input ready asserted while result was stalled");
        end

        // Consume the held result.
        m_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (m_valid)
            $fatal(1, "Output valid did not clear after handshake");

        // A simple all-ones case makes every expected equation easy to inspect.
        build_case(2);
        for (output_channel = 0; output_channel < OUTPUTS;
             output_channel = output_channel + 1)
            expected_third[output_channel] = expected_current[output_channel];
        s_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        m_ready = 1'b0;
        check_result(2);

        // Asynchronous reset assertion must discard an unconsumed result.
        #2 aresetn = 1'b0;
        #1;
        if (m_valid || s_ready)
            $fatal(1, "Reset did not clear valid/ready state immediately");

        $display(
            "PASS: 3 vectors, 48 output accumulations, back-to-back/stall/reset checked"
        );
        $finish;
    end

    initial begin
        repeat (500) @(posedge clk);
        $fatal(1, "Simulation timed out");
    end

endmodule
