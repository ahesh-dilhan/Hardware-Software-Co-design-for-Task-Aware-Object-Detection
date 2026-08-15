.PHONY: test model-test rtl-test hls-csim hls clean

BUILD_DIR := build
RTL_TEST := $(BUILD_DIR)/tb_int8_mac_tile_16x16.vvp
PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
VITIS_RUN ?= vitis-run

test: model-test rtl-test

model-test:
	$(PYTHON) -m unittest discover -s model/tests -v

rtl-test:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_int8_mac_tile_16x16 -o $(RTL_TEST) \
		rtl/int8_mac_tile_16x16.sv sim/tb_int8_mac_tile_16x16.sv
	$(VVP) $(RTL_TEST)

hls-csim:
	command -v $(VITIS_RUN) >/dev/null
	HLS_CSIM_ONLY=1 $(VITIS_RUN) --mode hls --tcl run_hls.tcl

hls:
	command -v $(VITIS_RUN) >/dev/null
	$(VITIS_RUN) --mode hls --tcl run_hls.tcl

clean:
	$(RM) -r $(BUILD_DIR) model/__pycache__ model/tests/__pycache__
