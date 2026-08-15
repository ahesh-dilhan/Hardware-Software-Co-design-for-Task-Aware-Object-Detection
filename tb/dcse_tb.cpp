#include <cstdlib>
#include <iostream>

#include "dcse_top.h"

static tile_cfg_t make_entry(int output_channels, int input_channels,
                             int kernel_size, int layer_type) {
    tile_cfg_t entry = 0;
    entry(63, 48) = (ap_uint<16>)output_channels;
    entry(47, 32) = (ap_uint<16>)input_channels;
    entry(31, 16) = (ap_uint<16>)kernel_size;
    entry(15, 0) = (ap_uint<16>)layer_type;
    return entry;
}

static void golden_projection(
    int8_t_hw input[TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw weights[MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bias[MCP_SIZE],
    int32_t_hw reference[TILE_H][TILE_W][MCP_SIZE], int input_channels,
    bool residual) {
    for (int row = 0; row < TILE_H; ++row) {
        for (int column = 0; column < TILE_W; ++column) {
            for (int output_channel = 0; output_channel < MCP_SIZE;
                 ++output_channel) {
                int accumulator = (int)bias[output_channel];
                for (int input_channel = 0; input_channel < input_channels;
                     ++input_channel) {
                    accumulator +=
                        (int)input[row][column][input_channel] *
                        (int)weights[output_channel][input_channel];
                }
                // The residual contributes zero when the input tensor does not
                // contain the corresponding output channel.
                if (residual && output_channel < input_channels) {
                    accumulator += (int)input[row][column][output_channel];
                }
                reference[row][column][output_channel] =
                    (int32_t_hw)accumulator;
            }
        }
    }
}

static int run_case(
    const char *name, int input_channels, int layer_type,
    int8_t_hw input[TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw weights[MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bias[MCP_SIZE], tile_cfg_t tile_rom[35],
    int32_t_hw output[TILE_H][TILE_W][MCP_SIZE],
    int32_t_hw reference[TILE_H][TILE_W][MCP_SIZE]) {
    const bool residual = layer_type == IDENTITY_RESIDUAL;
    const int kernel_size = layer_type == SPATIAL3x3_RESERVED ? 3 : 1;

    tile_rom[0] = make_entry(MCP_SIZE, input_channels, kernel_size, layer_type);
    golden_projection(input, weights, bias, reference, input_channels,
                      residual);
    dcse_top(input, weights, bias, tile_rom, (ap_uint<6>)0, output);

    int mismatches = 0;
    for (int row = 0; row < TILE_H; ++row) {
        for (int column = 0; column < TILE_W; ++column) {
            for (int output_channel = 0; output_channel < MCP_SIZE;
                 ++output_channel) {
                if (output[row][column][output_channel] !=
                    reference[row][column][output_channel]) {
                    ++mismatches;
                    if (mismatches <= 3) {
                        std::cout << "  mismatch " << name << " [" << row
                                  << "][" << column << "][" << output_channel
                                  << "]: HLS="
                                  << output[row][column][output_channel]
                                  << " REF="
                                  << reference[row][column][output_channel]
                                  << std::endl;
                    }
                }
            }
        }
    }

    std::cout << (mismatches == 0 ? "PASS " : "FAIL ") << name
              << " (channels=" << input_channels
              << ", values=" << TILE_H * TILE_W * MCP_SIZE << ")"
              << std::endl;
    return mismatches;
}

static int run_invalid_case(
    const char *name, int input_channels, int layer_type, int layer_index,
    int8_t_hw input[TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw weights[MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bias[MCP_SIZE], tile_cfg_t tile_rom[35],
    int32_t_hw output[TILE_H][TILE_W][MCP_SIZE]) {
    tile_rom[0] = make_entry(MCP_SIZE, input_channels, 1, layer_type);
    for (int row = 0; row < TILE_H; ++row) {
        for (int column = 0; column < TILE_W; ++column) {
            for (int output_channel = 0; output_channel < MCP_SIZE;
                 ++output_channel) {
                output[row][column][output_channel] = 0x12345678;
            }
        }
    }

    dcse_top(input, weights, bias, tile_rom, (ap_uint<6>)layer_index, output);

    int nonzero_values = 0;
    for (int row = 0; row < TILE_H; ++row) {
        for (int column = 0; column < TILE_W; ++column) {
            for (int output_channel = 0; output_channel < MCP_SIZE;
                 ++output_channel) {
                if (output[row][column][output_channel] != 0) {
                    ++nonzero_values;
                }
            }
        }
    }
    std::cout << (nonzero_values == 0 ? "PASS " : "FAIL ") << name
              << " (deterministic zero output)" << std::endl;
    return nonzero_values;
}

int main() {
    std::cout << "=== DCSE functional C simulation ===" << std::endl;

    static int8_t_hw input[TILE_H][TILE_W][MAX_CHANNELS];
    static int8_t_hw weights[MCP_SIZE][MAX_CHANNELS];
    static int16_t_hw bias[MCP_SIZE];
    static tile_cfg_t tile_rom[35];
    static int32_t_hw output[TILE_H][TILE_W][MCP_SIZE];
    static int32_t_hw reference[TILE_H][TILE_W][MCP_SIZE];

    std::srand(42);
    for (int row = 0; row < TILE_H; ++row) {
        for (int column = 0; column < TILE_W; ++column) {
            for (int input_channel = 0; input_channel < MAX_CHANNELS;
                 ++input_channel) {
                input[row][column][input_channel] =
                    (int8_t_hw)((std::rand() % 255) - 128);
            }
        }
    }
    for (int output_channel = 0; output_channel < MCP_SIZE;
         ++output_channel) {
        for (int input_channel = 0; input_channel < MAX_CHANNELS;
             ++input_channel) {
            weights[output_channel][input_channel] =
                (int8_t_hw)((std::rand() % 255) - 128);
        }
        bias[output_channel] = (int16_t_hw)((std::rand() % 511) - 256);
    }
    for (int index = 0; index < 35; ++index) {
        tile_rom[index] = make_entry(MCP_SIZE, 16, 1, POINTWISE_PROJECTION);
    }

    int total_mismatches = 0;
    total_mismatches += run_case("pointwise/minimum-channels", 1,
                                 POINTWISE_PROJECTION,
                                 input, weights, bias, tile_rom, output,
                                 reference);
    total_mismatches += run_case("pointwise/non-vector-width", 7,
                                 POINTWISE_PROJECTION,
                                 input, weights, bias, tile_rom, output,
                                 reference);
    total_mismatches += run_case("3x3-id/current-pointwise-behavior", 16,
                                 SPATIAL3x3_RESERVED,
                                 input, weights, bias, tile_rom, output,
                                 reference);
    total_mismatches += run_case("identity-residual/channel-boundary", 7,
                                 IDENTITY_RESIDUAL, input, weights, bias,
                                 tile_rom, output, reference);
    total_mismatches += run_case("identity-residual/multiple-vectors", 31,
                                 IDENTITY_RESIDUAL,
                                 input, weights, bias, tile_rom, output,
                                 reference);
    total_mismatches += run_case("pointwise/maximum-channels", MAX_CHANNELS,
                                 POINTWISE_PROJECTION, input, weights, bias, tile_rom,
                                 output, reference);
    total_mismatches += run_invalid_case(
        "invalid/zero-input-channels", 0, POINTWISE_PROJECTION, 0, input,
        weights, bias, tile_rom, output);
    total_mismatches += run_invalid_case(
        "invalid/too-many-input-channels", MAX_CHANNELS + 1,
        POINTWISE_PROJECTION, 0, input, weights, bias, tile_rom, output);
    total_mismatches += run_invalid_case(
        "invalid/unknown-layer-type", 16, 99, 0, input, weights, bias,
        tile_rom, output);
    total_mismatches += run_invalid_case(
        "invalid/out-of-range-layer-index", 16, POINTWISE_PROJECTION, 35,
        input, weights, bias, tile_rom, output);

    if (total_mismatches != 0) {
        std::cout << "FAIL: " << total_mismatches
                  << " total mismatches." << std::endl;
        return 1;
    }

    std::cout << "PASS: implemented arithmetic paths and channel-boundary "
                 "cases are bit-exact."
              << std::endl;
    std::cout << "Timing and resource results must be taken from the HLS "
                 "synthesis report."
              << std::endl;
    return 0;
}
