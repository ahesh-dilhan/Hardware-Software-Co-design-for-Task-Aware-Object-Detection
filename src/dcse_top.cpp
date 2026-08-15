#include "dcse_top.h"

// Bank C holds the identity tensor for the optional residual primitive.
static int8_t_hw bank_c[BANK_C_DEPTH];

// ─────────────────────────────────────────────────────────────────────────────
// Sixteen-output-channel MAC tile (INT8 products, INT32 accumulation).
// This is a parallel dot-product engine, not a systolic array: values do not
// move between processing elements.
// ─────────────────────────────────────────────────────────────────────────────
static void parallel_mac_tile(
    int8_t_hw  in  [TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw  w   [MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bias[MCP_SIZE],
    int32_t_hw out [TILE_H][TILE_W][MCP_SIZE],
    int in_ch)
{
#pragma HLS INLINE off
#pragma HLS ARRAY_PARTITION variable=w    complete dim=1
#pragma HLS ARRAY_PARTITION variable=out  complete dim=3
#pragma HLS ARRAY_PARTITION variable=bias complete dim=1

    ROWS: for (int r = 0; r < TILE_H; r++) {
        COLS: for (int c = 0; c < TILE_W; c++) {
#pragma HLS PIPELINE II=1
            OC: for (int oc = 0; oc < MCP_SIZE; oc++) {
                // Bias initializes the accumulator before channel reduction.
                int32_t_hw acc = (int32_t_hw)bias[oc];
                IC: for (int ic = 0; ic < MAX_CHANNELS; ic++) {
#pragma HLS UNROLL factor=16
                    if (ic < in_ch)
                        acc += (int32_t_hw)in[r][c][ic] * (int32_t_hw)w[oc][ic];
                }
                out[r][c][oc] = acc;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Residual store: copy the input identity tensor into Bank C.
// ─────────────────────────────────────────────────────────────────────────────
static void rap_store(
    int8_t_hw in[TILE_H][TILE_W][MAX_CHANNELS],
    int in_ch)
{
#pragma HLS INLINE off

    for (int r = 0; r < TILE_H; r++) {
        for (int c = 0; c < TILE_W; c++) {
#pragma HLS PIPELINE II=1
            for (int ic = 0; ic < MAX_CHANNELS; ic++) {
                if (ic < in_ch)
                    bank_c[r * TILE_W * MAX_CHANNELS + c * MAX_CHANNELS + ic] = in[r][c][ic];
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Residual add: MAC output plus the stored identity when a channel exists.
// ─────────────────────────────────────────────────────────────────────────────
static void residual_add(
    int32_t_hw mcp_out[TILE_H][TILE_W][MCP_SIZE],
    int32_t_hw out    [TILE_H][TILE_W][MCP_SIZE],
    int in_ch)
{
#pragma HLS INLINE off

    for (int r = 0; r < TILE_H; r++) {
        for (int c = 0; c < TILE_W; c++) {
#pragma HLS PIPELINE II=1
            for (int oc = 0; oc < MCP_SIZE; oc++) {
                // Add identity from Bank C (RAP residual)
                int8_t_hw identity = (oc < in_ch) ?
                    bank_c[r * TILE_W * MAX_CHANNELS + c * MAX_CHANNELS + oc] :
                    (int8_t_hw)0;
                out[r][c][oc] = mcp_out[r][c][oc] + (int32_t_hw)identity;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Direct output path (no residual addition).
// ─────────────────────────────────────────────────────────────────────────────
static void direct_store(
    int32_t_hw mcp_out[TILE_H][TILE_W][MCP_SIZE],
    int32_t_hw out    [TILE_H][TILE_W][MCP_SIZE])
{
#pragma HLS INLINE off

    for (int r = 0; r < TILE_H; r++) {
        for (int c = 0; c < TILE_W; c++) {
#pragma HLS PIPELINE II=1
            for (int oc = 0; oc < MCP_SIZE; oc++) {
                out[r][c][oc] = mcp_out[r][c][oc];
            }
        }
    }
}

// Deterministic response for an invalid descriptor or layer-table index.
static void clear_output(
    int32_t_hw out[TILE_H][TILE_W][MCP_SIZE])
{
#pragma HLS INLINE off

    for (int r = 0; r < TILE_H; r++) {
        for (int c = 0; c < TILE_W; c++) {
#pragma HLS PIPELINE II=1
            for (int oc = 0; oc < MCP_SIZE; oc++) {
                out[r][c][oc] = 0;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP-LEVEL: mode decoder + caller-provided external descriptor table
// ─────────────────────────────────────────────────────────────────────────────
void dcse_top(
    int8_t_hw  input_tile [TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw  weights    [MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bn_bias    [MCP_SIZE],
    tile_cfg_t tile_rom   [35],
    ap_uint<6> layer_idx,
    int32_t_hw output_tile[TILE_H][TILE_W][MCP_SIZE])
{
#pragma HLS INTERFACE m_axi     port=input_tile  depth=65536  offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi     port=weights     depth=4096   offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi     port=bn_bias     depth=16     offset=slave bundle=gmem2
#pragma HLS INTERFACE m_axi     port=tile_rom    depth=35     offset=slave bundle=gmem3
#pragma HLS INTERFACE m_axi     port=output_tile depth=4096   offset=slave bundle=gmem4
#pragma HLS INTERFACE s_axilite port=layer_idx
#pragma HLS INTERFACE s_axilite port=return

    // Validate the table index before any external-memory access.
    if (layer_idx >= 35) {
        clear_output(output_tile);
        return;
    }

    // The caller supplies a pre-packed layer descriptor table in external memory.
    tile_cfg_t cfg    = tile_rom[layer_idx];
    ap_uint<16> layer_type = cfg(15, 0);
    int in_ch = (int)cfg(47, 32);

    bool valid_input_channels = in_ch >= 1 && in_ch <= MAX_CHANNELS;
    bool valid_layer_type =
        layer_type == SPATIAL3x3_RESERVED ||
        layer_type == POINTWISE_PROJECTION ||
        layer_type == IDENTITY_RESIDUAL;
    if (!valid_input_channels || !valid_layer_type) {
        clear_output(output_tile);
        return;
    }

    // Internal MAC output buffer
    static int32_t_hw mac_out[TILE_H][TILE_W][MCP_SIZE];
#pragma HLS ARRAY_PARTITION variable=mac_out complete dim=3

    // Mode Decoder: routes data based on layer type
    if (layer_type == IDENTITY_RESIDUAL) {
        rap_store(input_tile, in_ch);
        parallel_mac_tile(input_tile, weights, bn_bias, mac_out, in_ch);
        residual_add(mac_out, output_tile, in_ch);
    } else {
        // Both non-residual IDs currently run a pointwise channel projection.
        // Spatial 3x3 windowing is an explicitly documented extension.
        parallel_mac_tile(input_tile, weights, bn_bias, mac_out, in_ch);
        direct_store(mac_out, output_tile);
    }
}
