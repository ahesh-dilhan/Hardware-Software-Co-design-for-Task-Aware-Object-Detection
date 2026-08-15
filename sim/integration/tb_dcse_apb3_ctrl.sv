`timescale 1ns/1ps
`default_nettype none

module tb_dcse_apb3_ctrl;

    localparam logic [7:0] REG_ID              = 8'h00;
    localparam logic [7:0] REG_VERSION         = 8'h04;
    localparam logic [7:0] REG_CONTROL         = 8'h08;
    localparam logic [7:0] REG_STATUS          = 8'h0c;
    localparam logic [7:0] REG_IRQ_ENABLE      = 8'h10;
    localparam logic [7:0] REG_IRQ_STATUS      = 8'h14;
    localparam logic [7:0] REG_LAYER_INDEX     = 8'h18;
    localparam logic [7:0] REG_ERROR_CODE      = 8'h1c;
    localparam logic [7:0] REG_INPUT_ADDR_LO   = 8'h20;
    localparam logic [7:0] REG_INPUT_ADDR_HI   = 8'h24;
    localparam logic [7:0] REG_WEIGHTS_ADDR_LO = 8'h28;
    localparam logic [7:0] REG_WEIGHTS_ADDR_HI = 8'h2c;
    localparam logic [7:0] REG_BIAS_ADDR_LO    = 8'h30;
    localparam logic [7:0] REG_BIAS_ADDR_HI    = 8'h34;
    localparam logic [7:0] REG_DESC_ADDR_LO    = 8'h38;
    localparam logic [7:0] REG_DESC_ADDR_HI    = 8'h3c;
    localparam logic [7:0] REG_OUTPUT_ADDR_LO  = 8'h40;
    localparam logic [7:0] REG_OUTPUT_ADDR_HI  = 8'h44;
    localparam logic [7:0] REG_START_COUNT     = 8'h48;
    localparam logic [7:0] REG_COMPLETE_COUNT  = 8'h4c;

    logic        PCLK;
    logic        PRESETn;
    logic        PSEL;
    logic        PENABLE;
    logic        PWRITE;
    logic [7:0]  PADDR;
    logic [31:0] PWDATA;
    logic [31:0] PRDATA;
    logic        PREADY;
    logic        PSLVERR;

    logic [63:0] cfg_input_addr;
    logic [63:0] cfg_weights_addr;
    logic [63:0] cfg_bias_addr;
    logic [63:0] cfg_descriptor_addr;
    logic [63:0] cfg_output_addr;
    logic [5:0]  cfg_layer_idx;
    logic        job_start;
    logic        job_busy;
    logic        irq;
    logic        accel_idle;
    logic        accel_done;
    logic        accel_error;
    logic [7:0]  accel_error_code;

    integer checks;
    integer failures;
    logic [31:0] read_data;

    dcse_apb3_ctrl dut (
        .PCLK                (PCLK),
        .PRESETn             (PRESETn),
        .PSEL                (PSEL),
        .PENABLE             (PENABLE),
        .PWRITE              (PWRITE),
        .PADDR               (PADDR),
        .PWDATA              (PWDATA),
        .PRDATA              (PRDATA),
        .PREADY              (PREADY),
        .PSLVERR             (PSLVERR),
        .cfg_input_addr      (cfg_input_addr),
        .cfg_weights_addr    (cfg_weights_addr),
        .cfg_bias_addr       (cfg_bias_addr),
        .cfg_descriptor_addr (cfg_descriptor_addr),
        .cfg_output_addr     (cfg_output_addr),
        .cfg_layer_idx       (cfg_layer_idx),
        .job_start           (job_start),
        .job_busy            (job_busy),
        .irq                 (irq),
        .accel_idle          (accel_idle),
        .accel_done          (accel_done),
        .accel_error         (accel_error),
        .accel_error_code    (accel_error_code)
    );

    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic apb_write(
        input logic [7:0] address,
        input logic [31:0] data,
        input logic expected_error
    );
        begin
            // Setup phase.
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b1;
            PADDR   = address;
            PWDATA  = data;
            #1;
            check(PSLVERR === 1'b0,
                  "PSLVERR must be low during APB setup phase");

            // Access phase.  This slave is zero-wait-state.
            @(negedge PCLK);
            PENABLE = 1'b1;
            #1;
            check(PREADY === 1'b1, "PREADY must be high");
            check(PSLVERR === expected_error,
                  "write PSLVERR did not match expectation");

            // State changes at this rising edge if the access was accepted.
            @(posedge PCLK);
            #1;
            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = '0;
            PWDATA  = '0;
        end
    endtask

    task automatic apb_read(
        input  logic [7:0] address,
        input  logic expected_error,
        output logic [31:0] data
    );
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = address;
            PWDATA  = 32'h0;
            #1;
            check(PSLVERR === 1'b0,
                  "PSLVERR must be low during APB setup phase");

            @(negedge PCLK);
            PENABLE = 1'b1;
            #1;
            check(PREADY === 1'b1, "PREADY must be high");
            check(PSLVERR === expected_error,
                  "read PSLVERR did not match expectation");
            data = PRDATA;

            @(posedge PCLK);
            #1;
            @(negedge PCLK);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PADDR   = '0;
        end
    endtask

    task automatic pulse_done;
        begin
            @(negedge PCLK);
            accel_idle = 1'b1;
            accel_done = 1'b1;
            @(posedge PCLK);
            #1;
            @(negedge PCLK);
            accel_done = 1'b0;
        end
    endtask

    task automatic pulse_error(input logic [7:0] code);
        begin
            @(negedge PCLK);
            accel_idle       = 1'b1;
            accel_error_code = code;
            accel_error      = 1'b1;
            // Co-assert done to prove that error has defined priority.
            accel_done       = 1'b1;
            @(posedge PCLK);
            #1;
            @(negedge PCLK);
            accel_error      = 1'b0;
            accel_done       = 1'b0;
        end
    endtask

    initial begin
        checks           = 0;
        failures         = 0;
        PRESETn          = 1'b0;
        PSEL             = 1'b0;
        PENABLE          = 1'b0;
        PWRITE           = 1'b0;
        PADDR            = '0;
        PWDATA           = '0;
        accel_idle       = 1'b1;
        accel_done       = 1'b0;
        accel_error      = 1'b0;
        accel_error_code = 8'h00;

        repeat (3) @(posedge PCLK);
        #1;
        check(job_busy === 1'b0, "busy reset value");
        check(job_start === 1'b0, "start reset value");
        check(irq === 1'b0, "irq reset value");
        check(cfg_layer_idx == 6'd0, "layer index reset value");
        check(cfg_input_addr == 64'h0, "input address reset value");

        @(negedge PCLK);
        PRESETn = 1'b1;

        // Identification and reset-state register reads.
        apb_read(REG_ID, 1'b0, read_data);
        check(read_data == 32'h4443_5345, "ID register");
        apb_read(REG_VERSION, 1'b0, read_data);
        check(read_data == 32'h0001_0000, "version register");
        apb_read(REG_STATUS, 1'b0, read_data);
        check(read_data[4:0] == 5'b0_1000, "idle reset status");

        // Program and read back the complete 64-bit job descriptor.
        apb_write(REG_INPUT_ADDR_LO,   32'h1000_0000, 1'b0);
        apb_write(REG_INPUT_ADDR_HI,   32'h0000_0001, 1'b0);
        apb_write(REG_WEIGHTS_ADDR_LO, 32'h2000_0000, 1'b0);
        apb_write(REG_WEIGHTS_ADDR_HI, 32'h0000_0002, 1'b0);
        apb_write(REG_BIAS_ADDR_LO,    32'h3000_0000, 1'b0);
        apb_write(REG_BIAS_ADDR_HI,    32'h0000_0003, 1'b0);
        apb_write(REG_DESC_ADDR_LO,    32'h4000_0000, 1'b0);
        apb_write(REG_DESC_ADDR_HI,    32'h0000_0004, 1'b0);
        apb_write(REG_OUTPUT_ADDR_LO,  32'h5000_0000, 1'b0);
        apb_write(REG_OUTPUT_ADDR_HI,  32'h0000_0005, 1'b0);
        apb_write(REG_LAYER_INDEX,     32'd34,        1'b0);

        check(cfg_input_addr == 64'h0000_0001_1000_0000,
              "input address programmed");
        check(cfg_weights_addr == 64'h0000_0002_2000_0000,
              "weights address programmed");
        check(cfg_bias_addr == 64'h0000_0003_3000_0000,
              "bias address programmed");
        check(cfg_descriptor_addr == 64'h0000_0004_4000_0000,
              "descriptor address programmed");
        check(cfg_output_addr == 64'h0000_0005_5000_0000,
              "output address programmed");
        check(cfg_layer_idx == 6'd34, "highest legal layer index");

        apb_read(REG_OUTPUT_ADDR_HI, 1'b0, read_data);
        check(read_data == 32'h0000_0005, "address readback");

        // Invalid accesses must return PSLVERR without changing state.
        apb_write(REG_LAYER_INDEX, 32'd35, 1'b1);
        check(cfg_layer_idx == 6'd34, "invalid layer index rejected");
        apb_write(REG_LAYER_INDEX, 32'h0000_0040, 1'b1);
        check(cfg_layer_idx == 6'd34, "reserved layer bits rejected");
        apb_write(REG_ID, 32'hdead_beef, 1'b1);
        apb_write(8'h21, 32'h0123_4567, 1'b1);
        check(cfg_input_addr == 64'h0000_0001_1000_0000,
              "misaligned write rejected");
        apb_read(8'h80, 1'b1, read_data);
        check(read_data == 32'h0, "unmapped read returns zero data");
        apb_write(REG_CONTROL, 32'h0000_0002, 1'b1);
        check(job_start === 1'b0, "reserved control bits rejected");

        // Enable both completion causes, then launch the first job.
        apb_write(REG_IRQ_ENABLE, 32'h0000_0003, 1'b0);
        apb_write(REG_CONTROL, 32'h0000_0001, 1'b0);
        check(job_start === 1'b1, "accepted START generates pulse");
        check(job_busy === 1'b1, "accepted START sets busy");
        accel_idle = 1'b0;
        @(posedge PCLK);
        #1;
        check(job_start === 1'b0, "START pulse is one clock wide");

        apb_read(REG_START_COUNT, 1'b0, read_data);
        check(read_data == 32'd1, "first accepted START counted");

        // Configuration is immutable while a job is active.
        apb_write(REG_INPUT_ADDR_LO, 32'hffff_ffff, 1'b1);
        check(cfg_input_addr == 64'h0000_0001_1000_0000,
              "busy configuration write rejected");
        apb_write(REG_CONTROL, 32'h0000_0001, 1'b1);
        check(job_start === 1'b0, "busy START rejected");
        apb_read(REG_START_COUNT, 1'b0, read_data);
        check(read_data == 32'd1, "rejected START not counted");

        // Successful completion sets a sticky cause and interrupt.
        pulse_done();
        check(job_busy === 1'b0, "done clears busy");
        check(irq === 1'b1, "done raises enabled interrupt");
        apb_read(REG_STATUS, 1'b0, read_data);
        check(read_data[4:0] == 5'b1_1010,
              "done/idle/irq status bits");
        apb_read(REG_IRQ_STATUS, 1'b0, read_data);
        check(read_data[1:0] == 2'b01, "done cause is sticky");
        apb_write(REG_IRQ_STATUS, 32'hffff_ffff, 1'b0);
        check(irq === 1'b0, "W1C clears done interrupt");

        // Second job ends in error.  Error wins if done is also asserted.
        apb_write(REG_CONTROL, 32'h0000_0001, 1'b0);
        check(job_start === 1'b1, "second START pulse");
        accel_idle = 1'b0;
        @(posedge PCLK);
        #1;
        pulse_error(8'ha5);
        check(job_busy === 1'b0, "error clears busy");
        check(irq === 1'b1, "error raises enabled interrupt");
        apb_read(REG_STATUS, 1'b0, read_data);
        check(read_data[4:0] == 5'b1_1100,
              "error/idle/irq status bits");
        apb_read(REG_IRQ_STATUS, 1'b0, read_data);
        check(read_data[1:0] == 2'b10,
              "error priority over co-asserted done");
        apb_read(REG_ERROR_CODE, 1'b0, read_data);
        check(read_data == 32'h0000_00a5, "error code captured");
        apb_read(REG_START_COUNT, 1'b0, read_data);
        check(read_data == 32'd2, "two accepted STARTs counted");
        apb_read(REG_COMPLETE_COUNT, 1'b0, read_data);
        check(read_data == 32'd2, "two terminal events counted");
        apb_write(REG_IRQ_STATUS, 32'h0000_0002, 1'b0);
        check(irq === 1'b0, "W1C clears error interrupt");
        apb_read(REG_ERROR_CODE, 1'b0, read_data);
        check(read_data == 32'h0, "clearing error also clears error code");

        // Even with internal busy clear, START needs downstream idle.
        accel_idle = 1'b0;
        apb_write(REG_CONTROL, 32'h0000_0001, 1'b1);
        check(job_start === 1'b0, "START rejected while accelerator not idle");
        apb_read(REG_START_COUNT, 1'b0, read_data);
        check(read_data == 32'd2, "not-idle START not counted");

        // Asynchronous reset restores all externally visible state.
        #2 PRESETn = 1'b0;
        #1;
        check(job_busy === 1'b0, "asynchronous reset clears busy");
        check(irq === 1'b0, "asynchronous reset clears irq");
        check(cfg_output_addr == 64'h0,
              "asynchronous reset clears configuration");

        if (failures == 0) begin
            $display("PASS: dcse_apb3_ctrl completed %0d checks", checks);
            $finish;
        end

        $fatal(1, "FAIL: %0d of %0d checks failed", failures, checks);
    end

    initial begin
        #10000;
        $fatal(1, "FAIL: testbench timeout");
    end

endmodule

`default_nettype wire
