`timescale 1ns/1ps
`default_nettype none

// Parallel INT8 dot-product tile used by the task-aware accelerator prototype.
//
// One transaction contains 16 activation lanes and a 16x16 weight tile.  The
// module computes 16 independent output-channel accumulations:
//
//   output[oc] = bias[oc] + residual[oc]
//                + sum(activation[ic] * weight[oc][ic])
//
// This is a parallel MAC tile, not a systolic array: operands do not move
// between neighbouring processing elements.  The registered output is a
// one-entry elastic buffer, so a new transaction can replace a consumed result
// on the same clock edge.  Timing/Fmax and DSP mapping must be established by
// synthesis for the intended Kintex-7 configuration.  The residual port is a
// generic INT32 vector; a wrapper matching dcse_top must sign-extend identity
// samples and drive zero for output channels that have no identity channel.
module int8_mac_tile_16x16 #(
    parameter integer LANES       = 16,
    parameter integer OUTPUTS     = 16,
    parameter integer DATA_WIDTH  = 8,
    parameter integer ACC_WIDTH   = 32
) (
    input  wire logic                                 clk,
    input  wire logic                                 aresetn,

    input  wire logic                                 s_valid,
    output logic                                      s_ready,
    input  wire logic signed [LANES*DATA_WIDTH-1:0]   s_activations,
    input  wire logic signed [OUTPUTS*LANES*DATA_WIDTH-1:0] s_weights,
    input  wire logic signed [OUTPUTS*ACC_WIDTH-1:0]  s_bias,
    input  wire logic                                 s_residual_enable,
    input  wire logic signed [OUTPUTS*ACC_WIDTH-1:0]  s_residual,

    output logic                                      m_valid,
    input  wire logic                                 m_ready,
    output logic signed [OUTPUTS*ACC_WIDTH-1:0]       m_accumulators
);

    localparam integer PRODUCT_WIDTH = 2 * DATA_WIDTH;

    logic [OUTPUTS*ACC_WIDTH-1:0] computed_accumulators;
    wire input_transfer  = s_valid && s_ready;
    wire output_transfer = m_valid && m_ready;

    function automatic signed [ACC_WIDTH-1:0] accumulate_one;
        input logic signed [LANES*DATA_WIDTH-1:0] activation_vector;
        input logic signed [LANES*DATA_WIDTH-1:0] weight_vector;
        input logic signed [ACC_WIDTH-1:0]        bias_value;
        input logic signed [ACC_WIDTH-1:0]        residual_value;
        input logic                               residual_enable;

        logic signed [ACC_WIDTH-1:0]     accumulator;
        logic signed [DATA_WIDTH-1:0]    activation_value;
        logic signed [DATA_WIDTH-1:0]    weight_value;
        logic signed [PRODUCT_WIDTH-1:0] product_value;
        integer lane;
        begin
            accumulator = bias_value;
            if (residual_enable)
                accumulator = accumulator + residual_value;

            for (lane = 0; lane < LANES; lane = lane + 1) begin
                activation_value = activation_vector[
                    lane*DATA_WIDTH +: DATA_WIDTH
                ];
                weight_value = weight_vector[lane*DATA_WIDTH +: DATA_WIDTH];
                product_value = activation_value * weight_value;
                accumulator = accumulator + product_value;
            end

            // ACC_WIDTH arithmetic is deliberately two's-complement wrapping.
            // Requantisation, activation, and saturation belong to a later
            // pipeline stage and are not hidden inside this primitive.
            accumulate_one = accumulator;
        end
    endfunction

    integer output_channel;
    always_comb begin
        computed_accumulators = '0;
        for (output_channel = 0; output_channel < OUTPUTS;
             output_channel = output_channel + 1) begin
            computed_accumulators[
                output_channel*ACC_WIDTH +: ACC_WIDTH
            ] = accumulate_one(
                s_activations,
                s_weights[
                    output_channel*LANES*DATA_WIDTH +: LANES*DATA_WIDTH
                ],
                s_bias[output_channel*ACC_WIDTH +: ACC_WIDTH],
                s_residual[output_channel*ACC_WIDTH +: ACC_WIDTH],
                s_residual_enable
            );
        end
    end

    always_comb begin
        s_ready = aresetn && (!m_valid || m_ready);
    end

    always_ff @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            m_valid        <= 1'b0;
            m_accumulators <= '0;
        end else begin
            if (output_transfer)
                m_valid <= 1'b0;

            if (input_transfer) begin
                m_accumulators <= computed_accumulators;
                m_valid        <= 1'b1;
            end
        end
    end

    initial begin : validate_parameters
        if (LANES < 1)
            $error("LANES must be positive");
        if (OUTPUTS < 1)
            $error("OUTPUTS must be positive");
        if (DATA_WIDTH < 2)
            $error("DATA_WIDTH must be at least 2 for signed INT arithmetic");
        if (ACC_WIDTH < PRODUCT_WIDTH)
            $error("ACC_WIDTH must be at least twice DATA_WIDTH");
    end

endmodule

`default_nettype wire
