#include <iostream>
#include <cstdlib>
#include "dcse_top.h"

static tile_cfg_t make_entry(int oc, int ic, int ks, int lt) {
    tile_cfg_t e = 0;
    e(63,48)=(ap_uint<16>)oc; e(47,32)=(ap_uint<16>)ic;
    e(31,16)=(ap_uint<16>)ks; e(15, 0)=(ap_uint<16>)lt;
    return e;
}

static void golden_csp(
    int8_t_hw in[TILE_H][TILE_W][MAX_CHANNELS],
    int8_t_hw w [MCP_SIZE][MCP_SIZE][MAX_CHANNELS],
    int16_t_hw bias[MCP_SIZE],
    int32_t_hw ref[TILE_H][TILE_W][MCP_SIZE], int in_ch)
{
    for(int r=0;r<TILE_H;r++) for(int c=0;c<TILE_W;c++) for(int oc=0;oc<MCP_SIZE;oc++){
        int32_t acc=(int32_t)bias[oc];
        for(int ic=0;ic<in_ch;ic++) acc+=(int32_t)in[r][c][ic]*(int32_t)w[oc][0][ic];
        acc+=(int32_t)in[r][c][oc<in_ch?oc:0];
        ref[r][c][oc]=(int32_t_hw)acc;
    }
}

int main(){
    std::cout<<"=== DCSE CSP Testbench ==="<<std::endl;
    static int8_t_hw  input_tile [TILE_H][TILE_W][MAX_CHANNELS];
    static int8_t_hw  weights    [MCP_SIZE][MCP_SIZE][MAX_CHANNELS];
    static int16_t_hw bn_bias    [MCP_SIZE];
    static tile_cfg_t tile_rom   [35];
    static int32_t_hw output_tile[TILE_H][TILE_W][MCP_SIZE];
    static int32_t_hw reference  [TILE_H][TILE_W][MCP_SIZE];

    srand(42);
    for(int r=0;r<TILE_H;r++) for(int c=0;c<TILE_W;c++) for(int ic=0;ic<MAX_CHANNELS;ic++)
        input_tile[r][c][ic]=(int8_t_hw)((rand()%255)-128);
    for(int oc=0;oc<MCP_SIZE;oc++){
        for(int r=0;r<MCP_SIZE;r++) for(int ic=0;ic<MAX_CHANNELS;ic++)
            weights[oc][r][ic]=(int8_t_hw)((rand()%255)-128);
        bn_bias[oc]=(int16_t_hw)((rand()%511)-256);
    }
    const int TEST_IN_CH=16;
    tile_rom[0]=make_entry(MCP_SIZE,TEST_IN_CH,3,CSP_BLOCK);
    for(int i=1;i<35;i++) tile_rom[i]=make_entry(MCP_SIZE,TEST_IN_CH,3,CONV3x3);

    golden_csp(input_tile,weights,bn_bias,reference,TEST_IN_CH);
    dcse_top(input_tile,weights,bn_bias,tile_rom,(ap_uint<6>)0,output_tile);

    int mis=0;
    for(int r=0;r<TILE_H;r++) for(int c=0;c<TILE_W;c++) for(int oc=0;oc<MCP_SIZE;oc++)
        if(output_tile[r][c][oc]!=reference[r][c][oc]){
            mis++;
            if(mis<=3) std::cout<<"  MISMATCH ["<<r<<"]["<<c<<"]["<<oc<<"]: HLS="
                <<output_tile[r][c][oc]<<" REF="<<reference[r][c][oc]<<std::endl;
        }

    if(mis==0){
        std::cout<<"  PASS: "<<TILE_H*TILE_W*MCP_SIZE<<" values bit-exact."<<std::endl;
        std::cout<<"  Run cosim_design to confirm <=170 cycle count."<<std::endl;
        return 0;
    }
    std::cout<<"  FAIL: "<<mis<<" mismatches."<<std::endl;
    return 1;
}
