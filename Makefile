.PHONY: test model-test rtl-test rtl-mac-test rtl-systolic-test \
	rtl-systolic-n16-test rtl-convolution-test rtl-apb-test \
	rtl-apb-systolic-demo-test software-test \
	synth-xc7 synth-systolic-xc7 synth-convolution-xc7 synth-apb-xc7 \
	hls-csim hls clean

BUILD_DIR := build
RTL_MAC_TEST := $(BUILD_DIR)/tb_int8_mac_tile_16x16.vvp
RTL_SYSTOLIC_TEST := $(BUILD_DIR)/tb_systolic_gemm.vvp
RTL_SYSTOLIC_N16_TEST := $(BUILD_DIR)/tb_systolic_gemm_n16.vvp
RTL_CONVOLUTION_TEST := $(BUILD_DIR)/tb_signed_int8_conv3x3.vvp
RTL_APB_TEST := $(BUILD_DIR)/tb_dcse_apb3_ctrl.vvp
RTL_APB_SYSTOLIC_DEMO_TEST := $(BUILD_DIR)/tb_dcse_apb_systolic_demo.vvp
SOFTWARE_TEST := $(BUILD_DIR)/test_dcse_apb3
PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
VITIS_RUN ?= vitis-run
YOSYS ?= yosys

test: model-test rtl-test software-test

model-test:
	$(PYTHON) -m unittest discover -s model/tests -v

rtl-test: rtl-mac-test rtl-systolic-test rtl-systolic-n16-test \
	rtl-convolution-test rtl-apb-test rtl-apb-systolic-demo-test

rtl-mac-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_int8_mac_tile_16x16 -o $(RTL_MAC_TEST) \
		rtl/int8_mac_tile_16x16.sv sim/tb_int8_mac_tile_16x16.sv
	$(VVP) $(RTL_MAC_TEST)

rtl-systolic-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_systolic_gemm -o $(RTL_SYSTOLIC_TEST) \
		rtl/systolic/systolic_gemm.sv sim/systolic/tb_systolic_gemm.sv
	$(VVP) $(RTL_SYSTOLIC_TEST)

rtl-systolic-n16-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_systolic_gemm_n16 \
		-o $(RTL_SYSTOLIC_N16_TEST) \
		rtl/systolic/systolic_gemm.sv \
		sim/systolic/tb_systolic_gemm_n16.sv
	$(VVP) $(RTL_SYSTOLIC_N16_TEST)

rtl-convolution-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_signed_int8_conv3x3 \
		-o $(RTL_CONVOLUTION_TEST) \
		rtl/convolution/signed_int8_conv3x3.sv \
		sim/convolution/tb_signed_int8_conv3x3.sv
	$(VVP) $(RTL_CONVOLUTION_TEST)

rtl-apb-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_dcse_apb3_ctrl -o $(RTL_APB_TEST) \
		rtl/integration/dcse_apb3_ctrl.sv \
		sim/integration/tb_dcse_apb3_ctrl.sv
	$(VVP) $(RTL_APB_TEST)

rtl-apb-systolic-demo-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_dcse_apb_systolic_demo \
		-o $(RTL_APB_SYSTOLIC_DEMO_TEST) \
		rtl/integration/dcse_apb3_ctrl.sv \
		rtl/systolic/systolic_gemm.sv \
		rtl/integration/dcse_apb_systolic_demo.sv \
		sim/integration/tb_dcse_apb_systolic_demo.sv
	$(VVP) $(RTL_APB_SYSTOLIC_DEMO_TEST)

software-test:
	mkdir -p $(BUILD_DIR)
	$(CC) -std=c11 -pedantic -Wall -Wextra -Werror -Isoftware \
		software/dcse_apb3.c tests/software/test_dcse_apb3.c \
		-o $(SOFTWARE_TEST)
	$(SOFTWARE_TEST)

synth-xc7: synth-systolic-xc7 synth-convolution-xc7 synth-apb-xc7

synth-systolic-xc7:
	mkdir -p $(BUILD_DIR)/yosys
	$(YOSYS) -q -s scripts/yosys/systolic_xc7.ys \
		-l $(BUILD_DIR)/yosys/systolic_n16.log

synth-convolution-xc7:
	mkdir -p $(BUILD_DIR)/yosys
	$(YOSYS) -q -s scripts/yosys/convolution_xc7.ys \
		-l $(BUILD_DIR)/yosys/convolution.log

synth-apb-xc7:
	mkdir -p $(BUILD_DIR)/yosys
	$(YOSYS) -q -s scripts/yosys/apb3_ctrl_xc7.ys \
		-l $(BUILD_DIR)/yosys/apb3_ctrl.log

hls-csim:
	command -v $(VITIS_RUN) >/dev/null
	HLS_CSIM_ONLY=1 $(VITIS_RUN) --mode hls --tcl run_hls.tcl

hls:
	command -v $(VITIS_RUN) >/dev/null
	$(VITIS_RUN) --mode hls --tcl run_hls.tcl

clean:
	$(RM) -r $(BUILD_DIR) model/__pycache__ model/tests/__pycache__
