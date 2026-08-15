`timescale 1ns/1ps

module tb_signed_int8_conv3x3;

    localparam integer IMAGE_WIDTH = 7;
    localparam integer IMAGE_HEIGHT = 6;
    localparam integer DATA_WIDTH = 8;
    localparam integer COEFFICIENT_WIDTH = 8;
    localparam integer ACC_WIDTH = 32;
    localparam integer FRAME_COUNT = 2;
    localparam integer OUTPUT_WIDTH = IMAGE_WIDTH - 2;
    localparam integer OUTPUT_HEIGHT = IMAGE_HEIGHT - 2;
    localparam integer OUTPUTS_PER_FRAME = OUTPUT_WIDTH * OUTPUT_HEIGHT;
    localparam integer TOTAL_OUTPUTS = FRAME_COUNT * OUTPUTS_PER_FRAME;
    localparam integer TOTAL_INPUTS = FRAME_COUNT * IMAGE_WIDTH * IMAGE_HEIGHT;

    reg clk = 1'b0;
    reg aresetn = 1'b0;

    reg s_valid = 1'b0;
    wire s_ready;
    reg signed [DATA_WIDTH-1:0] s_pixel = '0;
    reg signed [9*COEFFICIENT_WIDTH-1:0] s_coefficients = '0;
    reg signed [ACC_WIDTH-1:0] s_bias = '0;

    wire m_valid;
    reg m_ready = 1'b0;
    wire signed [ACC_WIDTH-1:0] m_accumulator;
    wire m_start_of_frame;
    wire m_end_of_line;
    wire m_end_of_frame;

    integer expected_results [0:TOTAL_OUTPUTS-1];
    integer input_count = 0;
    integer output_count = 0;
    integer output_stall_cycles = 0;
    integer input_backpressure_cycles = 0;
    integer ready_pattern_cycle = 0;
    integer expected_index;
    integer expected_value;
    integer expected_in_frame;
    integer expected_output_x;
    integer expected_output_y;

    reg stall_was_active = 1'b0;
    reg signed [ACC_WIDTH-1:0] held_accumulator = '0;
    reg held_start_of_frame = 1'b0;
    reg held_end_of_line = 1'b0;
    reg held_end_of_frame = 1'b0;

    always #5 clk = ~clk;

    signed_int8_conv3x3 #(
        .IMAGE_WIDTH(IMAGE_WIDTH),
        .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFFICIENT_WIDTH(COEFFICIENT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .aresetn(aresetn),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_pixel(s_pixel),
        .s_coefficients(s_coefficients),
        .s_bias(s_bias),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_accumulator(m_accumulator),
        .m_start_of_frame(m_start_of_frame),
        .m_end_of_line(m_end_of_line),
        .m_end_of_frame(m_end_of_frame)
    );

    function automatic integer pixel_for;
        input integer frame_number;
        input integer x;
        input integer y;
        integer sequence_position;
        begin
            sequence_position = y*IMAGE_WIDTH + x;
            if (frame_number == 0) begin
                pixel_for = ((y*17 + x*7 + 3) % 31) - 15;
            end else begin
                // Include both signed-INT8 extremes in the second frame.
                case (sequence_position % 11)
                    0: pixel_for = -128;
                    1: pixel_for = 127;
                    default:
                        pixel_for = ((sequence_position*13 + 5) % 61) - 30;
                endcase
            end
        end
    endfunction

    function automatic integer coefficient_for;
        input integer frame_number;
        input integer tap;
        begin
            if (frame_number == 0) begin
                case (tap)
                    0: coefficient_for = 1;
                    1: coefficient_for = -2;
                    2: coefficient_for = 3;
                    3: coefficient_for = -4;
                    4: coefficient_for = 5;
                    5: coefficient_for = -6;
                    6: coefficient_for = 7;
                    7: coefficient_for = -8;
                    default: coefficient_for = 9;
                endcase
            end else begin
                case (tap)
                    0: coefficient_for = -128;
                    1: coefficient_for = 127;
                    2: coefficient_for = -31;
                    3: coefficient_for = 16;
                    4: coefficient_for = -1;
                    5: coefficient_for = 2;
                    6: coefficient_for = 63;
                    7: coefficient_for = -64;
                    default: coefficient_for = 11;
                endcase
            end
        end
    endfunction

    function automatic integer bias_for;
        input integer frame_number;
        begin
            bias_for = (frame_number == 0) ? -73 : 12345;
        end
    endfunction

    task automatic configure_frame;
        input integer frame_number;
        integer tap;
        integer coefficient_value;
        begin
            s_coefficients = '0;
            for (tap = 0; tap < 9; tap = tap + 1) begin
                coefficient_value = coefficient_for(frame_number, tap);
                s_coefficients[
                    tap*COEFFICIENT_WIDTH +: COEFFICIENT_WIDTH
                ] = coefficient_value[COEFFICIENT_WIDTH-1:0];
            end
            s_bias = bias_for(frame_number);
        end
    endtask

    task automatic build_expected_results;
        integer frame_number;
        integer output_x;
        integer output_y;
        integer kernel_x;
        integer kernel_y;
        integer tap;
        integer accumulator;
        begin
            expected_index = 0;
            for (frame_number = 0; frame_number < FRAME_COUNT;
                 frame_number = frame_number + 1) begin
                for (output_y = 0; output_y < OUTPUT_HEIGHT;
                     output_y = output_y + 1) begin
                    for (output_x = 0; output_x < OUTPUT_WIDTH;
                         output_x = output_x + 1) begin
                        accumulator = bias_for(frame_number);
                        for (kernel_y = 0; kernel_y < 3;
                             kernel_y = kernel_y + 1) begin
                            for (kernel_x = 0; kernel_x < 3;
                                 kernel_x = kernel_x + 1) begin
                                tap = kernel_y*3 + kernel_x;
                                accumulator = accumulator +
                                    pixel_for(
                                        frame_number,
                                        output_x + kernel_x,
                                        output_y + kernel_y
                                    ) * coefficient_for(frame_number, tap);
                            end
                        end
                        expected_results[expected_index] = accumulator;
                        expected_index = expected_index + 1;
                    end
                end
            end
        end
    endtask

    task automatic send_frame;
        input integer frame_number;
        integer x;
        integer y;
        integer accepted;
        begin
            configure_frame(frame_number);
            for (y = 0; y < IMAGE_HEIGHT; y = y + 1) begin
                for (x = 0; x < IMAGE_WIDTH; x = x + 1) begin
                    // Deterministic input bubbles exercise state retention when
                    // no transfer occurs.
                    if (((frame_number*5 + y*3 + x) % 6) == 2) begin
                        @(negedge clk);
                        s_valid = 1'b0;
                        @(posedge clk);
                    end

                    @(negedge clk);
                    s_pixel = pixel_for(frame_number, x, y);
                    s_valid = 1'b1;
                    accepted = 0;
                    while (!accepted) begin
                        @(posedge clk);
                        if (s_ready) begin
                            accepted = 1;
                            input_count = input_count + 1;
                        end else begin
                            input_backpressure_cycles =
                                input_backpressure_cycles + 1;
                        end
                    end
                end
            end
            @(negedge clk);
            s_valid = 1'b0;
        end
    endtask

    // A repeatable non-random pattern creates single- and multi-cycle output
    // stalls, including stalls at row and frame boundaries.
    always @(negedge clk) begin
        if (!aresetn) begin
            ready_pattern_cycle = 0;
            m_ready = 1'b0;
        end else begin
            ready_pattern_cycle = ready_pattern_cycle + 1;
            m_ready = ((ready_pattern_cycle % 7) != 2) &&
                      ((ready_pattern_cycle % 7) != 3) &&
                      ((ready_pattern_cycle % 13) != 8);
        end
    end

    // Scoreboard and ready/valid stability checks sample signals immediately
    // before DUT nonblocking assignments update the next-cycle state.
    always @(posedge clk) begin
        if (!aresetn) begin
            stall_was_active = 1'b0;
        end else begin
            if (stall_was_active) begin
                if (!m_valid)
                    $fatal(1, "m_valid dropped while downstream was stalled");
                if (m_accumulator !== held_accumulator ||
                    m_start_of_frame !== held_start_of_frame ||
                    m_end_of_line !== held_end_of_line ||
                    m_end_of_frame !== held_end_of_frame)
                    $fatal(1, "Output payload changed under backpressure");
            end

            if (m_valid && !m_ready) begin
                output_stall_cycles = output_stall_cycles + 1;
                held_accumulator = m_accumulator;
                held_start_of_frame = m_start_of_frame;
                held_end_of_line = m_end_of_line;
                held_end_of_frame = m_end_of_frame;
                stall_was_active = 1'b1;
            end else begin
                stall_was_active = 1'b0;
            end

            if (m_valid && m_ready) begin
                if (output_count >= TOTAL_OUTPUTS)
                    $fatal(1, "DUT produced more outputs than expected");

                expected_value = expected_results[output_count];
                if ($signed(m_accumulator) !== expected_value)
                    $fatal(1,
                        "Output %0d: expected %0d, received %0d",
                        output_count,
                        expected_value,
                        $signed(m_accumulator));

                expected_in_frame = output_count % OUTPUTS_PER_FRAME;
                expected_output_y = expected_in_frame / OUTPUT_WIDTH;
                expected_output_x = expected_in_frame % OUTPUT_WIDTH;

                if (m_start_of_frame !==
                    ((expected_output_x == 0) && (expected_output_y == 0)))
                    $fatal(1, "Incorrect start-of-frame marker at output %0d",
                        output_count);
                if (m_end_of_line !==
                    (expected_output_x == OUTPUT_WIDTH-1))
                    $fatal(1, "Incorrect end-of-line marker at output %0d",
                        output_count);
                if (m_end_of_frame !==
                    ((expected_output_x == OUTPUT_WIDTH-1) &&
                     (expected_output_y == OUTPUT_HEIGHT-1)))
                    $fatal(1, "Incorrect end-of-frame marker at output %0d",
                        output_count);

                output_count = output_count + 1;
            end
        end
    end

    initial begin
        build_expected_results();

        repeat (4) @(posedge clk);
        #2;
        if (m_valid || s_ready)
            $fatal(1, "Reset did not suppress ready/valid state");

        @(negedge clk);
        aresetn = 1'b1;

        send_frame(0);
        send_frame(1);

        while (output_count < TOTAL_OUTPUTS)
            @(posedge clk);
        repeat (3) @(posedge clk);

        if (input_count != TOTAL_INPUTS)
            $fatal(1, "Expected %0d inputs, counted %0d",
                TOTAL_INPUTS, input_count);
        if (output_count != TOTAL_OUTPUTS)
            $fatal(1, "Expected %0d outputs, counted %0d",
                TOTAL_OUTPUTS, output_count);
        if (output_stall_cycles < 4)
            $fatal(1, "Backpressure coverage was too weak: %0d stall cycles",
                output_stall_cycles);
        if (input_backpressure_cycles < 1)
            $fatal(1, "No propagated input backpressure was observed");

        $display(
            "PASS: %0d signed pixels -> %0d cropped 3x3 outputs; two kernels, signed extremes, bias, bubbles, %0d output stalls, %0d input backpressure cycles, and framing checked",
            input_count,
            output_count,
            output_stall_cycles,
            input_backpressure_cycles
        );
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "Simulation timed out");
    end

endmodule
