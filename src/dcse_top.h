#ifndef DCSE_TOP_H
#define DCSE_TOP_H
#include <ap_int.h>
#include <hls_stream.h>
typedef ap_int<8>   int8_t_hw;
typedef ap_int<32>  int32_t_hw;
typedef ap_int<16>  int16_t_hw;
typedef ap_uint<64> tile_cfg_t;
#define MCP_SIZE     16
#define TILE_H       16
#define TILE_W       16
#define MAX_CHANNELS 256
#define BANK_C_DEPTH (16*16*256)
#define CONV3x3   0
#define CONV1x1   1
#define CSP_BLOCK 2
void dcse_top(
    int8_t_hw  input_tile [TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw  weights    [MCP_SIZE][MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bn_bias    [MCP_SIZE],
    tile_cfg_t tile_rom   [35],
    ap_uint<6> layer_idx,
    int32_t_hw output_tile[TILE_H][TILE_W][MCP_SIZE]
);
#endif
