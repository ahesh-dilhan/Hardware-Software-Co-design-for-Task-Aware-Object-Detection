`timescale 1ns/1ps
`default_nettype none

// Standalone streaming signed-INT8 3x3 convolution primitive.
//
// Pixels arrive in raster order: IMAGE_WIDTH accepted pixels per row and
// IMAGE_HEIGHT rows per frame.  The nine coefficients use row-major order:
//
//   coefficient 0  1  2
//               3  4  5
//               6  7  8
//
// As is conventional for CNN hardware, the implemented operation is spatial
// cross-correlation (the coefficient matrix is not flipped):
//
//   result = bias + sum(window[tap] * coefficient[tap])
//
// No padding is inserted.  A W x H input frame therefore produces a
// (W-2) x (H-2) output frame.  Results remain signed ACC_WIDTH accumulations;
// requantisation, rounding, activation, and saturation are deliberately left
// to a separate stage.
//
// The output register is a one-entry elastic buffer.  A downstream stall
// freezes the input interface and all line/window state, which makes the
// ready/valid contract straightforward and lossless.  The line memories have
// asynchronous reads and synchronous writes; their physical FPGA mapping and
// timing must be established by synthesis rather than assumed here.  They are
// intentionally not reset: the first two complete rows after reset or a frame
// boundary overwrite every location before any output window is declared
// valid.
//
// Coefficients and bias are sampled with the accepted bottom-right pixel of
// each window.  A frame-level configuration must therefore remain stable for
// the complete input frame, and all input payload signals must remain stable
// whenever s_valid is asserted while s_ready is deasserted.
module signed_int8_conv3x3 #(
    parameter integer IMAGE_WIDTH = 16,
    parameter integer IMAGE_HEIGHT = 16,
    parameter integer DATA_WIDTH = 8,
    parameter integer COEFFICIENT_WIDTH = 8,
    parameter integer ACC_WIDTH = 32
) (
    input  wire logic clk,
    input  wire logic aresetn,

    input  wire logic                                  s_valid,
    output logic                                       s_ready,
    input  wire logic signed [DATA_WIDTH-1:0]           s_pixel,
    input  wire logic signed [9*COEFFICIENT_WIDTH-1:0]  s_coefficients,
    input  wire logic signed [ACC_WIDTH-1:0]            s_bias,

    output logic                                       m_valid,
    input  wire logic                                  m_ready,
    output logic signed [ACC_WIDTH-1:0]                m_accumulator,
    output logic                                       m_start_of_frame,
    output logic                                       m_end_of_line,
    output logic                                       m_end_of_frame
);

    localparam integer PRODUCT_WIDTH = DATA_WIDTH + COEFFICIENT_WIDTH;
    localparam integer X_WIDTH = (IMAGE_WIDTH <= 2) ? 1 : $clog2(IMAGE_WIDTH);
    localparam integer Y_WIDTH = (IMAGE_HEIGHT <= 2) ? 1 : $clog2(IMAGE_HEIGHT);

    // At column x, line_previous[x] holds row y-1 and line_two_back[x]
    // holds row y-2 before the accepted input updates those locations.
    logic signed [DATA_WIDTH-1:0] line_previous [0:IMAGE_WIDTH-1];
    logic signed [DATA_WIDTH-1:0] line_two_back [0:IMAGE_WIDTH-1];

    logic signed [DATA_WIDTH-1:0] top_x_minus_2;
    logic signed [DATA_WIDTH-1:0] top_x_minus_1;
    logic signed [DATA_WIDTH-1:0] middle_x_minus_2;
    logic signed [DATA_WIDTH-1:0] middle_x_minus_1;
    logic signed [DATA_WIDTH-1:0] bottom_x_minus_2;
    logic signed [DATA_WIDTH-1:0] bottom_x_minus_1;

    logic [X_WIDTH-1:0] x_position;
    logic [Y_WIDTH-1:0] y_position;

    logic signed [9*DATA_WIDTH-1:0] window_pixels;
    logic signed [ACC_WIDTH-1:0] convolution_result;

    wire logic signed [DATA_WIDTH-1:0] previous_row_pixel =
        line_previous[x_position];
    wire logic signed [DATA_WIDTH-1:0] two_rows_back_pixel =
        line_two_back[x_position];

    wire logic input_transfer = s_valid && s_ready;
    wire logic output_transfer = m_valid && m_ready;
    wire logic window_is_valid = (x_position >= 2) && (y_position >= 2);

    function automatic signed [ACC_WIDTH-1:0] convolve_window;
        input logic signed [9*DATA_WIDTH-1:0] pixel_vector;
        input logic signed [9*COEFFICIENT_WIDTH-1:0] coefficient_vector;
        input logic signed [ACC_WIDTH-1:0] bias_value;

        logic signed [DATA_WIDTH-1:0] pixel_value;
        logic signed [COEFFICIENT_WIDTH-1:0] coefficient_value;
        logic signed [PRODUCT_WIDTH-1:0] product_value;
        logic signed [ACC_WIDTH-1:0] accumulator;
        integer tap;
        begin
            accumulator = bias_value;
            for (tap = 0; tap < 9; tap = tap + 1) begin
                pixel_value = pixel_vector[tap*DATA_WIDTH +: DATA_WIDTH];
                coefficient_value = coefficient_vector[
                    tap*COEFFICIENT_WIDTH +: COEFFICIENT_WIDTH
                ];
                product_value = pixel_value * coefficient_value;
                // Arithmetic deliberately wraps at ACC_WIDTH.  With the
                // default INT8 operands, 20 signed bits cover the nine-product
                // sum; software must also choose a bias representable in the
                // configured accumulator width.
                accumulator = accumulator + product_value;
            end
            convolve_window = accumulator;
        end
    endfunction

    always_comb begin
        // Window order is top-left to bottom-right.  The newest pixel forms
        // the bottom-right corner of the window.
        window_pixels = '0;
        window_pixels[0*DATA_WIDTH +: DATA_WIDTH] = top_x_minus_2;
        window_pixels[1*DATA_WIDTH +: DATA_WIDTH] = top_x_minus_1;
        window_pixels[2*DATA_WIDTH +: DATA_WIDTH] = two_rows_back_pixel;
        window_pixels[3*DATA_WIDTH +: DATA_WIDTH] = middle_x_minus_2;
        window_pixels[4*DATA_WIDTH +: DATA_WIDTH] = middle_x_minus_1;
        window_pixels[5*DATA_WIDTH +: DATA_WIDTH] = previous_row_pixel;
        window_pixels[6*DATA_WIDTH +: DATA_WIDTH] = bottom_x_minus_2;
        window_pixels[7*DATA_WIDTH +: DATA_WIDTH] = bottom_x_minus_1;
        window_pixels[8*DATA_WIDTH +: DATA_WIDTH] = s_pixel;

        convolution_result = convolve_window(
            window_pixels,
            s_coefficients,
            s_bias
        );
    end

    // The same edge may consume the held result and accept its replacement.
    // Freezing the entire input path while a result is stalled avoids a
    // separate skid/window buffer and is functionally lossless.
    always_comb begin
        s_ready = aresetn && (!m_valid || m_ready);
    end

    always_ff @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            x_position      <= '0;
            y_position      <= '0;
            top_x_minus_2   <= '0;
            top_x_minus_1   <= '0;
            middle_x_minus_2 <= '0;
            middle_x_minus_1 <= '0;
            bottom_x_minus_2 <= '0;
            bottom_x_minus_1 <= '0;
            m_valid          <= 1'b0;
            m_accumulator    <= '0;
            m_start_of_frame <= 1'b0;
            m_end_of_line    <= 1'b0;
            m_end_of_frame   <= 1'b0;
        end else begin
            if (output_transfer)
                m_valid <= 1'b0;

            if (input_transfer) begin
                // Read-before-write behavior advances the two line delays.
                line_two_back[x_position] <= previous_row_pixel;
                line_previous[x_position] <= s_pixel;

                top_x_minus_2    <= top_x_minus_1;
                top_x_minus_1    <= two_rows_back_pixel;
                middle_x_minus_2 <= middle_x_minus_1;
                middle_x_minus_1 <= previous_row_pixel;
                bottom_x_minus_2 <= bottom_x_minus_1;
                bottom_x_minus_1 <= s_pixel;

                if (window_is_valid) begin
                    m_accumulator    <= convolution_result;
                    m_start_of_frame <= (x_position == 2) &&
                                        (y_position == 2);
                    m_end_of_line    <= (x_position == IMAGE_WIDTH-1);
                    m_end_of_frame   <= (x_position == IMAGE_WIDTH-1) &&
                                        (y_position == IMAGE_HEIGHT-1);
                    m_valid          <= 1'b1;
                end

                if (x_position == IMAGE_WIDTH-1) begin
                    x_position <= '0;
                    if (y_position == IMAGE_HEIGHT-1)
                        y_position <= '0;
                    else
                        y_position <= y_position + 1'b1;
                end else begin
                    x_position <= x_position + 1'b1;
                end
            end
        end
    end

    initial begin : validate_parameters
        if (IMAGE_WIDTH < 3)
            $error("IMAGE_WIDTH must be at least 3");
        if (IMAGE_HEIGHT < 3)
            $error("IMAGE_HEIGHT must be at least 3");
        if (DATA_WIDTH < 2)
            $error("DATA_WIDTH must support signed arithmetic");
        if (COEFFICIENT_WIDTH < 2)
            $error("COEFFICIENT_WIDTH must support signed arithmetic");
        if (ACC_WIDTH < PRODUCT_WIDTH + 4)
            $error("ACC_WIDTH must cover a worst-case nine-product sum");
    end

endmodule

`default_nettype wire
