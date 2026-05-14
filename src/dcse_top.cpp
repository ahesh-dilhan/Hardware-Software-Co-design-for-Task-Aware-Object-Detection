#include "dcse_top.h"

// Bank C for RAP (Residual Accumulation Path) - holds identity tensor during CSP blocks
static int8_t_hw bank_c[BANK_C_DEPTH];

// ─────────────────────────────────────────────────────────────────────────────
// MCP: 16×16 output-stationary systolic array (INT8 MAC, bias pre-added)
// ─────────────────────────────────────────────────────────────────────────────
static void mcp_systolic(
    int8_t_hw  in  [TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw  w   [MCP_SIZE][MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bias[MCP_SIZE],
    int32_t_hw out [TILE_H][TILE_W][MCP_SIZE],
    int in_ch)
{
#pragma HLS INLINE off
#pragma HLS ARRAY_PARTITION variable=w    complete dim=1
#pragma HLS ARRAY_PARTITION variable=w    complete dim=2
#pragma HLS ARRAY_PARTITION variable=out  complete dim=3
#pragma HLS ARRAY_PARTITION variable=bias complete dim=1

    ROWS: for (int r = 0; r < TILE_H; r++) {
        COLS: for (int c = 0; c < TILE_W; c++) {
#pragma HLS PIPELINE II=1
            OC: for (int oc = 0; oc < MCP_SIZE; oc++) {
                // BN-bias packed into pre-adder stage (N2 novelty)
                int32_t_hw acc = (int32_t_hw)bias[oc];
                IC: for (int ic = 0; ic < MAX_CHANNELS; ic++) {
#pragma HLS UNROLL factor=16
                    if (ic < in_ch)
                        acc += (int32_t_hw)in[r][c][ic] * (int32_t_hw)w[oc][0][ic];
                }
                out[r][c][oc] = acc;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RAP: Write input tile into Bank C simultaneously with MCP feed (CSP identity)
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
// Adder tree: MCP output + RAP identity → zero stall cycles (N1 novelty)
// ─────────────────────────────────────────────────────────────────────────────
static void adder_tree(
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
// CONV path (no residual addition)
// ─────────────────────────────────────────────────────────────────────────────
static void conv_path(
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

// ─────────────────────────────────────────────────────────────────────────────
// TOP-LEVEL: Mode Decoder + Tile ROM + DCSE dataflow
// ─────────────────────────────────────────────────────────────────────────────
void dcse_top(
    int8_t_hw  input_tile [TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw  weights    [MCP_SIZE][MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bn_bias    [MCP_SIZE],
    tile_cfg_t tile_rom   [35],
    ap_uint<6> layer_idx,
    int32_t_hw output_tile[TILE_H][TILE_W][MCP_SIZE])
{
#pragma HLS INTERFACE m_axi     port=input_tile  depth=65536  offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi     port=weights     depth=65536  offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi     port=bn_bias     depth=16     offset=slave bundle=gmem2
#pragma HLS INTERFACE m_axi     port=tile_rom    depth=35     offset=slave bundle=gmem3
#pragma HLS INTERFACE m_axi     port=output_tile depth=65536  offset=slave bundle=gmem4
#pragma HLS INTERFACE s_axilite port=layer_idx
#pragma HLS INTERFACE s_axilite port=return

#pragma HLS RESOURCE variable=bank_c core=RAM_2P_BRAM

    // N3: Read tile config from ROM in ONE clock cycle — zero runtime arithmetic
    tile_cfg_t cfg    = tile_rom[layer_idx];
    ap_uint<16> layer_type = cfg(15, 0);
    int in_ch = (int)cfg(47, 32);

    // Internal MCP output buffer
    static int32_t_hw mcp_out[TILE_H][TILE_W][MCP_SIZE];
#pragma HLS ARRAY_PARTITION variable=mcp_out complete dim=3

    // Mode Decoder: routes data based on layer type
    if (layer_type == CSP_BLOCK) {
        // RAP stores identity simultaneously with MCP execution (N1 novelty)
#pragma HLS DATAFLOW
        rap_store(input_tile, in_ch);
        mcp_systolic(input_tile, weights, bn_bias, mcp_out, in_ch);
        adder_tree(mcp_out, output_tile, in_ch);
    } else {
        // CONV3x3 or CONV1x1 — no residual
        mcp_systolic(input_tile, weights, bn_bias, mcp_out, in_ch);
        conv_path(mcp_out, output_tile);
    }
}
