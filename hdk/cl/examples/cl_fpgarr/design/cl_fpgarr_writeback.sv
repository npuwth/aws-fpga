module rr_packed2writeback_bus (
   input wire clk,
   input wire rstn,
   rr_packed_logging_bus_t.C in,
   rr_stream_bus_t.P out
);

// parameter check
generate
   if (in.LOGB_CHANNEL_CNT + in.LOGE_CHANNEL_CNT + in.FULL_WIDTH
       != out.FULL_WIDTH)
    $error("Writeback FULL_WIDTH mismatch: logb W%d, loge W%d, packed_logb_data W%d, writeback W%d\n",
      in.LOGB_CHANNEL_CNT, in.LOGE_CHANNEL_CNT, in.FULL_WIDTH, out.FULL_WIDTH);
endgenerate

// loge_valid_output is the signal outputting to the writeback_bus, it should be
// in-sync with out.valid
// Invariant description of loge_valid_output:
// 1. loge_valid_output[i] shows whether one (and can only be one) transaction
// has finished on channel[i] between now (some logb_valid are true, but
// excluding the loge_valid happens at the same cycle) and the last time some
// logb are valid.
// 2. In other words, when out.valid is asserted, loge_valid_output[i] together
// with all historical loge_valid_output values, represents the number of
// transactions finished in each channel (count the 1s) before the start of the
// logb_{valid, data} in the out.data.
// if logb_valid[i] && loge_valid[i], which only happen if the transaction
// really lasts for only one cycle (ready was asserted in advance)
logic [in.LOGE_CHANNEL_CNT-1:0] loge_valid_out;

assign out.valid = in.plogb.any_valid;
assign in.ready = out.ready;
assign out.len = out.valid?
   (in.plogb.len + out.OFFSET_WIDTH'(in.LOGB_CHANNEL_CNT + in.LOGE_CHANNEL_CNT))
   : 0;
// from LSB to MSB:
// logb_valid, loge_valid, packed_logb_data
assign out.data = {in.plogb.data, loge_valid_out, in.logb_valid};

// buf loge_valid if there is no valid logb to send
always @(posedge clk)
if (!rstn)
   loge_valid_out <= 0;
else
   for (int i=0; i < in.LOGE_CHANNEL_CNT; i=i+1)
      // loge_valid_out can only be updated when
      //   (out.valid && out.ready): loge_valid accumulated so far is recorded
      //   in the trace, I should restart the accumulation.
      //   (!out.valid): I cannot write to trace at this moment, any standalone
      //   loge_valid should be accumulated and wait for the next write to the
      //   trace.
      if (out.valid && out.ready)
         // the incoming loge_valid is not related to the happen-before of
         // the current logb_valid. That will be deferred to the next
         // transmission
         loge_valid_out[i] <= in.loge_valid[i];
      else if (!out.valid && in.loge_valid[i] && out.ready) begin
         // a standlone loge_valid comes
         loge_valid_out[i] <= 1;
         // there could only be at most 1 transaction finished between two
         // logging unit in the trace.
         no_loge_overwrite: assert(!loge_valid_out[i]);
      end
endmodule

////////////////////////////////////////////////////////////////////////////
// axi interconnect for sharing single shell pcim bus across the logging
// writeback module and the user pcim bus
////////////////////////////////////////////////////////////////////////////
module rr_storage_pcim_axi_interconnect (
   input wire clk,
   input wire rstn,
   rr_axi_bus_t.master logging_wb_bus,
   rr_axi_bus_t.master cl_pcim_bus,
   rr_axi_bus_t.slave sh_pcim_bus
);

// TODO: is this dont_touch necessary?
(* dont_touch = "true" *) rr_pcim_axi_interconnect pcim_interconnect_inst (
   .ACLK(clk),
   .ARESETN(rstn),
   /* the single output master bus connecting to the shell*/
   .M00_AXI_araddr(sh_pcim_bus.araddr),
   .M00_AXI_arburst(),
   .M00_AXI_arcache(),
   .M00_AXI_arid(sh_pcim_bus.arid),
   .M00_AXI_arlen(sh_pcim_bus.arlen),
   .M00_AXI_arlock(),
   .M00_AXI_arprot(),
   .M00_AXI_arqos(),
   .M00_AXI_arready(sh_pcim_bus.arready),
   .M00_AXI_arregion(),
   .M00_AXI_arsize(sh_pcim_bus.arsize),
   .M00_AXI_arvalid(sh_pcim_bus.arvalid),
   .M00_AXI_awaddr(sh_pcim_bus.awaddr),
   .M00_AXI_awburst(),
   .M00_AXI_awcache(),
   .M00_AXI_awid(sh_pcim_bus.awid),
   .M00_AXI_awlen(sh_pcim_bus.awlen),
   .M00_AXI_awlock(),
   .M00_AXI_awprot(),
   .M00_AXI_awqos(),
   .M00_AXI_awready(sh_pcim_bus.awready),
   .M00_AXI_awregion(),
   .M00_AXI_awsize(sh_pcim_bus.awsize),
   .M00_AXI_awvalid(sh_pcim_bus.awvalid),
   .M00_AXI_bid(sh_pcim_bus.bid),
   .M00_AXI_bready(sh_pcim_bus.bready),
   .M00_AXI_bresp(sh_pcim_bus.bresp),
   .M00_AXI_bvalid(sh_pcim_bus.bvalid),
   .M00_AXI_rdata(sh_pcim_bus.rdata),
   .M00_AXI_rid(sh_pcim_bus.rid),
   .M00_AXI_rlast(sh_pcim_bus.rlast),
   .M00_AXI_rready(sh_pcim_bus.rready),
   .M00_AXI_rresp(sh_pcim_bus.rresp),
   .M00_AXI_rvalid(sh_pcim_bus.rvalid),
   .M00_AXI_wdata(sh_pcim_bus.wdata),
   .M00_AXI_wlast(sh_pcim_bus.wlast),
   .M00_AXI_wready(sh_pcim_bus.wready),
   .M00_AXI_wstrb(sh_pcim_bus.wstrb),
   .M00_AXI_wvalid(sh_pcim_bus.wvalid),
   /* logging writeback bus (generated by rr) */
   .S00_AXI_araddr(logging_wb_bus.araddr),
   .S00_AXI_arburst(2'b1), // INCR
   .S00_AXI_arcache(4'b00),
   .S00_AXI_arid(logging_wb_bus.arid[14:0]),
   .S00_AXI_arlen(logging_wb_bus.arlen),
   .S00_AXI_arlock(1'b0),
   .S00_AXI_arprot(3'b00),
   .S00_AXI_arqos(4'b0),
   .S00_AXI_arready(logging_wb_bus.arready),
   .S00_AXI_arregion(4'b0),
   .S00_AXI_arsize(logging_wb_bus.arsize),
   .S00_AXI_arvalid(logging_wb_bus.arvalid),
   .S00_AXI_awaddr(logging_wb_bus.awaddr),
   .S00_AXI_awburst(2'b1),
   .S00_AXI_awcache(4'b00),
   .S00_AXI_awid(logging_wb_bus.awid[14:0]),
   .S00_AXI_awlen(logging_wb_bus.awlen),
   .S00_AXI_awlock(1'b0),
   .S00_AXI_awprot(3'b00),
   .S00_AXI_awqos(4'b0),
   .S00_AXI_awready(logging_wb_bus.awready),
   .S00_AXI_awregion(4'b0),
   .S00_AXI_awsize(logging_wb_bus.awsize),
   .S00_AXI_awvalid(logging_wb_bus.awvalid),
   .S00_AXI_bid(logging_wb_bus.bid[14:0]),
   .S00_AXI_bready(logging_wb_bus.bready),
   .S00_AXI_bresp(logging_wb_bus.bresp),
   .S00_AXI_bvalid(logging_wb_bus.bvalid),
   .S00_AXI_rdata(logging_wb_bus.rdata),
   .S00_AXI_rid(logging_wb_bus.rid[14:0]),
   .S00_AXI_rlast(logging_wb_bus.rlast),
   .S00_AXI_rready(logging_wb_bus.rready),
   .S00_AXI_rresp(logging_wb_bus.rresp),
   .S00_AXI_rvalid(logging_wb_bus.rvalid),
   .S00_AXI_wdata(logging_wb_bus.wdata),
   .S00_AXI_wlast(logging_wb_bus.wlast),
   .S00_AXI_wready(logging_wb_bus.wready),
   .S00_AXI_wstrb(logging_wb_bus.wstrb),
   .S00_AXI_wvalid(logging_wb_bus.wvalid),
   /* cl pcim bus (should be taken care of in rr) */
   .S01_AXI_araddr(cl_pcim_bus.araddr),
   .S01_AXI_arburst(2'b1), // INCR
   .S01_AXI_arcache(4'b00),
   .S01_AXI_arid(cl_pcim_bus.arid[14:0]),
   .S01_AXI_arlen(cl_pcim_bus.arlen),
   .S01_AXI_arlock(1'b0),
   .S01_AXI_arprot(3'b00),
   .S01_AXI_arqos(4'b0),
   .S01_AXI_arready(cl_pcim_bus.arready),
   .S01_AXI_arregion(4'b0),
   .S01_AXI_arsize(cl_pcim_bus.arsize),
   .S01_AXI_arvalid(cl_pcim_bus.arvalid),
   .S01_AXI_awaddr(cl_pcim_bus.awaddr),
   .S01_AXI_awburst(2'b1),
   .S01_AXI_awcache(4'b00),
   .S01_AXI_awid(cl_pcim_bus.awid[14:0]),
   .S01_AXI_awlen(cl_pcim_bus.awlen),
   .S01_AXI_awlock(1'b0),
   .S01_AXI_awprot(3'b00),
   .S01_AXI_awqos(4'b0),
   .S01_AXI_awready(cl_pcim_bus.awready),
   .S01_AXI_awregion(4'b0),
   .S01_AXI_awsize(cl_pcim_bus.awsize),
   .S01_AXI_awvalid(cl_pcim_bus.awvalid),
   .S01_AXI_bid(cl_pcim_bus.bid[14:0]),
   .S01_AXI_bready(cl_pcim_bus.bready),
   .S01_AXI_bresp(cl_pcim_bus.bresp),
   .S01_AXI_bvalid(cl_pcim_bus.bvalid),
   .S01_AXI_rdata(cl_pcim_bus.rdata),
   .S01_AXI_rid(cl_pcim_bus.rid[14:0]),
   .S01_AXI_rlast(cl_pcim_bus.rlast),
   .S01_AXI_rready(cl_pcim_bus.rready),
   .S01_AXI_rresp(cl_pcim_bus.rresp),
   .S01_AXI_rvalid(cl_pcim_bus.rvalid),
   .S01_AXI_wdata(cl_pcim_bus.wdata),
   .S01_AXI_wlast(cl_pcim_bus.wlast),
   .S01_AXI_wready(cl_pcim_bus.wready),
   .S01_AXI_wstrb(cl_pcim_bus.wstrb),
   .S01_AXI_wvalid(cl_pcim_bus.wvalid)
);
endmodule

/*
 * A better structure in my mind.
 * Summary of the requirement:
 * ===> Variable length input (0..WIDTH)
 *             Fixed 512 output (AXI_WIDTH) ===>
 * A [2*WIDTH-1:0] (shift register?) B
 * Four cases to consider:
 * B_next
 * B
 * 1. !in, !out B_next = B
 * 2. in, !out
 *    B_next[B_len +: WIDTH] = in
 * 3. !in, out
 *    B_next[0 +: WIDTH-AXI_WIDTH] = B[AXI_WIDTH +: WIDTH-AXI_WIDTH]
 *    out[AXI_WIDTH-1:0] = B[0 +: AXI_WIDTH]
 * 4. in, out
 *    B_next[0 +: WIDTH-AXI_WIDTH] = B[AXI_WIDTH +: WIDTH-AXI_WIDTH]
 *    B_next[B_len - AXI_WIDTH +: WIDTH] = in
 *    out[AXI_WIDTH-1:0] = B[0 +: AXI_WIDTH]
 */
module rr_writeback #(
    parameter WIDTH = 2500,
    parameter AXI_WIDTH = 512,
    parameter OFFSET_WIDTH = 32,
    parameter AXI_ADDR_WIDTH = 64,
    parameter int LOGB_CHANNEL_CNT = 25,
    parameter int LOGE_CHANNEL_CNT = 25,
    parameter bit [LOGB_CHANNEL_CNT-1:0]
      [RR_CHANNEL_WIDTH_BITS-1:0] CHANNEL_WIDTHS) (
    input clk,
    input sync_rst_n,
    // cfg_max_payload: see https://github.com/aws/aws-fpga/blob/master/hdk/docs/AWS_Shell_Interface_Specification.md#pcim-interface----axi-4-for-outbound-pcie-transactions-cl-is-master-shell-is-slave-512-bit
    input logic [1:0] cfg_max_payload,

    input logic record_din_valid,
    output logic record_din_ready,
    input logic record_finish,
    input logic [WIDTH-1:0] record_din,
    input logic [OFFSET_WIDTH-1:0] record_din_width,

    output logic replay_dout_valid,
    input logic replay_dout_ready,
    output logic [WIDTH-1:0] replay_dout,
    output logic [OFFSET_WIDTH-1:0] replay_dout_width,

    rr_axi_bus_t.slave axi_out,

    input logic [AXI_ADDR_WIDTH-1:0] write_buf_addr,
    input logic [AXI_ADDR_WIDTH-1:0] write_buf_size,
    input logic write_buf_update,

    input logic [AXI_ADDR_WIDTH-1:0] read_buf_addr,
    input logic [AXI_ADDR_WIDTH-1:0] read_buf_size,
    input logic read_buf_update,

    // When there's a buffer overflow, an interrupt will be triggerred
    output logic write_interrupt,
    output logic read_interrupt
);

    localparam NSTAGES = (WIDTH - 1) / AXI_WIDTH + 1;
    localparam EXT_WIDTH = NSTAGES * AXI_WIDTH;

    // To parse one logging unit at a time from the backend storage, here is an
    // helper function to tell how long a logging unit is.
    // This function decodes the valid bitmap of logb_valid and aims to finish
    // LOGB_CHANNEL_CNT constant additions in a cycle.
    function automatic [OFFSET_WIDTH-1:0] GET_LEN(logic [AXI_WIDTH-1:0] packed_data);
        logic [LOGB_CHANNEL_CNT-1:0] logb_bitmap;
        logb_bitmap = packed_data[LOGB_CHANNEL_CNT-1:0];
        GET_LEN = LOGB_CHANNEL_CNT + LOGE_CHANNEL_CNT;
        for (int i=0; i < LOGB_CHANNEL_CNT; i=i+1)
            if (logb_bitmap[i])
                GET_LEN += OFFSET_WIDTH'(CHANNEL_WIDTHS[i]);
    endfunction

    logic [WIDTH-1:0] record_in_fifo_out;
    logic [EXT_WIDTH-1:0] record_in_fifo_out_wrap;
    logic [OFFSET_WIDTH-1:0] record_in_fifo_out_width;
    logic record_in_fifo_rd_en;
    logic record_in_fifo_full, record_in_fifo_almfull, record_in_fifo_empty;

    assign record_in_fifo_out_wrap = EXT_WIDTH'(record_in_fifo_out);

    merged_fifo #(
        .WIDTH(WIDTH+OFFSET_WIDTH),
        .ALMFULL_THRESHOLD(12))
    mfifo_inst_record_in(
        .clk(clk),
        .rst(~sync_rst_n),
        .din({record_din,record_din_width}),
        .dout({record_in_fifo_out,record_in_fifo_out_width}),
        .wr_en(record_din_valid),
        .rd_en(record_in_fifo_rd_en),
        .full(record_in_fifo_full),
        .almfull(record_in_fifo_almfull),
        .empty(record_in_fifo_empty)
    );

    logic [AXI_WIDTH-1:0] record_out_fifo_out, record_out_fifo_in, record_out_fifo_in_q, record_out_fifo_in_qq;
    logic record_out_fifo_rd_en, record_out_fifo_wr_en, record_out_fifo_wr_en_q, record_out_fifo_wr_en_qq;
    logic record_out_fifo_full, record_out_fifo_almfull, record_out_fifo_empty;

    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            record_out_fifo_wr_en_q <= 0;
            record_out_fifo_wr_en_qq <= 0;
        end else begin
            record_out_fifo_in_q <= record_out_fifo_in;
            record_out_fifo_in_qq <= record_out_fifo_in_q;
            record_out_fifo_wr_en_q <= record_out_fifo_wr_en;
            record_out_fifo_wr_en_qq <= record_out_fifo_wr_en_q;
        end
    end

    merged_fifo #(
        .WIDTH(AXI_WIDTH),
        .ALMFULL_THRESHOLD(12))
    mfifo_inst_record_out(
        .clk(clk),
        .rst(~sync_rst_n),
        .din(record_out_fifo_in_qq),
        .dout(record_out_fifo_out),
        .wr_en(record_out_fifo_wr_en_qq),
        .rd_en(record_out_fifo_rd_en),
        .full(record_out_fifo_full),
        .almfull(record_out_fifo_almfull),
        .empty(record_out_fifo_empty)
    );

    logic [OFFSET_WIDTH-1:0] record_unhandled_size;
    logic [AXI_WIDTH-1:0] record_unhandled [NSTAGES-1:0];
    logic [AXI_WIDTH-1:0] current_record_unhandled;
    logic [OFFSET_WIDTH-1:0] current_record_unhandled_size;
    logic [AXI_WIDTH*2-1:0] record_leftover, record_leftover_next;
    logic [$clog2(AXI_WIDTH):0] record_leftover_size;
    logic [$clog2(NSTAGES):0] record_curr;
    logic do_record_finish;

    assign record_in_fifo_rd_en = ~record_in_fifo_empty && ~record_out_fifo_almfull && record_unhandled_size <= AXI_WIDTH;

    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            record_unhandled_size <= 0;
            record_leftover_size <= 0;
            record_curr <= NSTAGES;
            do_record_finish <= 0;
            record_out_fifo_in <= 0;
            record_out_fifo_wr_en <= 0;
            current_record_unhandled_size <= 0;
        end else begin
            if (record_finish) begin
                do_record_finish <= 1;
            end

            if (record_in_fifo_rd_en) begin
                record_curr <= 0;
                record_unhandled_size <= record_in_fifo_out_width;
                for (int i = 0; i < NSTAGES; i++) begin
                    record_unhandled[i] <= record_in_fifo_out_wrap[i*AXI_WIDTH+:AXI_WIDTH];
                end
            end else if (record_curr + 1 <= NSTAGES) begin
                record_curr <= record_curr + 1;
                if (record_unhandled_size >= AXI_WIDTH) begin
                    record_unhandled_size <= record_unhandled_size - AXI_WIDTH;
                end else begin
                    record_unhandled_size <= 0;
                end
            end

            if (record_unhandled_size >= AXI_WIDTH) begin
                current_record_unhandled_size <= AXI_WIDTH;
            end else begin
                current_record_unhandled_size <= record_unhandled_size;
            end
            current_record_unhandled <= record_unhandled[record_curr];

            record_leftover_next = record_leftover;
            record_leftover_next[record_leftover_size +: AXI_WIDTH] = current_record_unhandled;
            if (record_leftover_size + current_record_unhandled_size >= AXI_WIDTH) begin
                record_leftover[0 +: AXI_WIDTH] <= record_leftover_next[AXI_WIDTH +: AXI_WIDTH];
                record_leftover_size <= record_leftover_size + current_record_unhandled_size - AXI_WIDTH;
                record_out_fifo_in <= record_leftover_next[0 +: AXI_WIDTH];
                record_out_fifo_wr_en <= 1;
            end else if (do_record_finish && record_in_fifo_empty && ~record_din_valid) begin
                if (record_leftover_size > 0) begin
                    record_out_fifo_wr_en <= 1;
                    record_out_fifo_in <= record_leftover[0 +: AXI_WIDTH];
                    do_record_finish <= 0;
                    record_leftover_size <= 0;
                end
            end else begin
                record_leftover <= record_leftover_next;
                record_leftover_size <= record_leftover_size + current_record_unhandled_size;
                record_out_fifo_wr_en <= 0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            record_din_ready <= 0;
        end else begin
            record_din_ready <= ~record_in_fifo_almfull && ~record_out_fifo_almfull;
        end
    end

    logic [AXI_ADDR_WIDTH-1:0] write_buf_curr, write_buf_end;
    logic write_buf_write_en;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            write_buf_curr <= 0;
            write_buf_end <= 0;
        end else if (write_buf_update) begin
            write_buf_curr <= write_buf_addr;
            write_buf_end <= write_buf_addr + write_buf_size;
        end else if (write_buf_write_en) begin
            write_buf_curr <= write_buf_curr + AXI_WIDTH/8;
        end

        write_interrupt <= (write_buf_curr == write_buf_end);
    end

    logic axi_aw_transmitted, axi_w_transmitted, axi_write_transmitted;
    logic axi_aw_working, axi_w_working, axi_write_working;
    assign axi_aw_transmitted = axi_out.awready & axi_out.awvalid;
    assign axi_w_transmitted = axi_out.wready & axi_out.wvalid;
    assign axi_aw_working = axi_out.awvalid & ~axi_out.awready;
    assign axi_w_working = axi_out.wvalid & ~axi_out.wready;
    assign axi_write_working = axi_aw_working | axi_w_working;

    // Transaction control
    logic axi_aw_handled, axi_w_handled;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            axi_aw_handled <= 0;
            axi_w_handled <= 0;
        end else begin
            if (axi_aw_transmitted & axi_w_transmitted) begin
                axi_aw_handled <= 0;
            end else if (axi_aw_transmitted & ~axi_w_transmitted & ~axi_w_handled) begin
                axi_aw_handled <= 1;
            end else if (axi_aw_handled & axi_w_transmitted) begin
                axi_aw_handled <= 0;
            end

            if (axi_aw_transmitted & axi_w_transmitted) begin
                axi_w_handled <= 0;
            end else if (axi_w_transmitted & ~axi_aw_transmitted & ~axi_aw_handled) begin
                axi_w_handled <= 1;
            end else if (axi_w_handled & axi_aw_transmitted) begin
                axi_w_handled <= 0;
            end
        end
    end

    assign axi_write_transmitted = (axi_aw_transmitted | axi_aw_handled) & (axi_w_transmitted | axi_w_handled);
    assign write_buf_write_en = axi_write_transmitted;

    // Valid control
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            axi_out.awvalid <= 0;
            axi_out.wvalid <= 0;
        end else begin
            if (axi_aw_working) begin
                axi_out.awvalid <= 1;
            end else if (axi_w_working) begin
                axi_out.awvalid <= 0;
            end else begin
                axi_out.awvalid <= ~record_out_fifo_empty;
            end

            if (axi_w_working) begin
                axi_out.wvalid <= 1;
            end else if (axi_aw_working) begin
                axi_out.wvalid <= 0;
            end else begin
                axi_out.wvalid <= ~record_out_fifo_empty;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            axi_out.wdata <= 0;
        end else begin
            if (~axi_aw_working & ~axi_w_working & ~record_out_fifo_empty)
                axi_out.wdata <= record_out_fifo_out;
        end
    end
    assign record_out_fifo_rd_en = ~axi_aw_working & ~axi_w_working & ~record_out_fifo_empty;

    logic [15:0] tid;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            tid <= 0;
        end else begin
            if (axi_write_transmitted) begin
                tid <= tid + 1;
            end
        end
    end

    // AW extras
    assign axi_out.awid = tid;
    assign axi_out.awaddr = write_buf_curr;
    assign axi_out.awlen = 0;
    assign axi_out.awsize = 3'b110; // 3'b110 means 64 bytes

    assign axi_out.wid = tid;
    assign axi_out.wstrb = -1;
    assign axi_out.wlast = 1;

    assign axi_out.bready = 1;

`ifdef WRITEBACK_DEBUG
    // Debugging info for AXI write
    always_ff @(posedge clk) begin
        if (axi_out.awvalid & axi_out.awready)
            $display("[writeback]: axi write addr 0x%x", axi_out.awaddr);
        if (axi_out.wvalid & axi_out.wready)
            $display("[writeback]: axi write data 0x%x", axi_out.wdata);
    end

    always_ff @(posedge clk) begin
        if (axi_out.awvalid & axi_out.awready & (axi_out.awaddr == 0))
            $stop;
    end
`endif

    logic [AXI_WIDTH-1:0] replay_in_fifo_in, replay_in_fifo_out;
    logic replay_in_fifo_wr_en, replay_in_fifo_rd_en;
    logic replay_in_fifo_full, replay_in_fifo_almfull, replay_in_fifo_empty;

    merged_fifo #(
        .WIDTH(AXI_WIDTH),
        .ALMFULL_THRESHOLD(12))
    mfifo_inst_replay_in(
        .clk(clk),
        .rst(~sync_rst_n),
        .din(replay_in_fifo_in),
        .dout(replay_in_fifo_out),
        .wr_en(replay_in_fifo_wr_en),
        .rd_en(replay_in_fifo_rd_en),
        .full(replay_in_fifo_full),
        .almfull(replay_in_fifo_almfull),
        .empty(replay_in_fifo_empty)
    );

    logic [OFFSET_WIDTH+WIDTH-1:0] replay_out_fifo_in, replay_out_fifo_out;
    logic replay_out_fifo_wr_en, replay_out_fifo_rd_en;
    logic replay_out_fifo_full, replay_out_fifo_almfull, replay_out_fifo_empty;

    merged_fifo #(
        .WIDTH(WIDTH+OFFSET_WIDTH),
        .ALMFULL_THRESHOLD(12))
    mfifo_inst_replay_out(
        .clk(clk),
        .rst(~sync_rst_n),
        .din(replay_out_fifo_in),
        .dout(replay_out_fifo_out),
        .wr_en(replay_out_fifo_wr_en),
        .rd_en(replay_out_fifo_rd_en),
        .full(replay_out_fifo_full),
        .almfull(replay_out_fifo_almfull),
        .empty(replay_out_fifo_empty)
    );

    logic [7:0] read_balance;
    logic axi_ar_transmitted, axi_r_transmitted;
    logic axi_ar_working;
    assign axi_ar_transmitted = axi_out.arvalid & axi_out.arready;
    assign axi_r_transmitted = axi_out.rvalid & axi_out.rready;
    assign axi_ar_working = axi_out.arvalid & ~axi_out.arready;

    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            read_balance <= 0;
        end else begin
            if (axi_ar_transmitted && replay_in_fifo_rd_en) begin
                read_balance <= read_balance;
            end else if (axi_ar_transmitted) begin
                read_balance <= read_balance + 1;
            end else if (replay_in_fifo_rd_en) begin
                read_balance <= read_balance - 1;
            end
        end
    end

    logic [AXI_ADDR_WIDTH-1:0] read_buf_curr, read_buf_end;
    logic read_buf_read_en;
    assign read_buf_read_en = axi_out.arvalid & axi_out.arready;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            read_buf_curr <= 0;
            read_buf_end <= 0;
        end else if (read_buf_update) begin
            read_buf_curr <= read_buf_addr;
            read_buf_end <= read_buf_addr + read_buf_size;
        end else if (read_buf_read_en) begin
            read_buf_curr <= read_buf_curr + AXI_WIDTH/8;
        end

        read_interrupt <= (read_buf_curr == read_buf_end);
    end

`ifndef TEST_REPLAY
    // Read request
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            axi_out.arvalid <= 0;
        end else begin
            if (read_balance <= 120) begin
                axi_out.arvalid <= 1;
            end else begin
                axi_out.arvalid <= 0;
            end
        end
    end
`else
    assign axi_out.arvalid = 0;
`endif

    assign axi_out.araddr = read_buf_curr;
    assign axi_out.arlen = 0;
    assign axi_out.arid = 0;
    assign axi_out.arsize = 3'b110;
    assign axi_out.rready = 1;

    // Read response
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            replay_in_fifo_in <= 0;
            replay_in_fifo_wr_en <= 0;
        end else begin
`ifndef TEST_REPLAY
            replay_in_fifo_in <= axi_out.rdata;
            replay_in_fifo_wr_en <= axi_r_transmitted;
`else
            replay_in_fifo_in <= record_out_fifo_out;
            replay_in_fifo_wr_en <= record_out_fifo_rd_en;
`endif
        end
    end

    logic [AXI_WIDTH-1:0] replay_current_in;
    logic replay_current_in_valid;

    logic [AXI_WIDTH*2-1:0] replay_leftover;
    logic [AXI_WIDTH*3-1:0] replay_leftover_next_assigned, replay_leftover_next_unassigned;
    logic [OFFSET_WIDTH-1:0] replay_leftover_size;
    logic [OFFSET_WIDTH-1:0] replay_total_size, replay_total_size_tmp, replay_total_size_reg;
    logic [OFFSET_WIDTH-1:0] replay_left_size, replay_left_size_tmp, replay_left_size_reg;
    logic [OFFSET_WIDTH-1:0] replay_shift_size;
    logic replay_is_first_packet, replay_leftover_do_step;

    assign replay_current_in = replay_in_fifo_out;
    assign replay_current_in_valid = replay_in_fifo_rd_en;
    assign replay_in_fifo_rd_en = ~replay_in_fifo_empty && ~replay_out_fifo_almfull
                                  && replay_leftover_size - replay_shift_size <= AXI_WIDTH;

    // *replay_leftover* should pass output whenever the next output size is less than
    // the size of the current leftover buffer, i.e., there are enough stuff to output.
    always_comb begin
        if (replay_leftover_size > AXI_WIDTH) begin
            // If leftover size is larger than AXI_WIDTH, we can output anyway.
            replay_leftover_do_step = 1;
        end else if (replay_left_size <= replay_leftover_size && replay_leftover_size > 0) begin
            // If leftover size is larger than the size of the remaining bits of the current
            // transaction, we can always output.
            replay_leftover_do_step = 1;
        end else begin
            // Otherwise, we cannot output anyway. If the size of the remaining bits in the
            // current transaction is larger than what's remaining in the leftover buffer,
            // we must wait for more data to be inserted to the leftover buffer, because all
            // outputs other than the last one in a transaction should have AXI_WIDTH bits.
            replay_leftover_do_step = 0;
        end
    end

    // *replay_total_size* is the number of bits in the whole transaction. It's calculated when
    // the first few bits of a transaction is decoded, and used until the next transaction.
    assign replay_total_size_tmp = GET_LEN(replay_leftover[0 +: AXI_WIDTH]);
    assign replay_total_size = replay_is_first_packet ? replay_total_size_tmp : replay_total_size_reg;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            replay_total_size_reg <= 0;
        end else begin
            if (replay_is_first_packet) begin
                replay_total_size_reg <= replay_total_size_tmp;
            end
        end
    end

    // *replay_left_size* is the number of bits left in a transaction. When handling the first
    // packet of a transaction, it equals replay_total_size. Then it is decreased by AXI_WIDTH
    // until there's nothing left in the packet.
    assign replay_left_size_tmp = replay_total_size_tmp;
    assign replay_left_size = replay_is_first_packet ? replay_total_size_tmp : replay_left_size_reg;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            replay_left_size_reg <= 0;
        end else begin
            if (replay_leftover_do_step) begin
                if (replay_left_size <= AXI_WIDTH) begin
                    // In this case, replay_left_size_reg is not used, we assign it to 0 to ease
                    // debugging. We can remove the following line if there's a timing issue.
                    replay_left_size_reg <= 0;
                end else begin
                    replay_left_size_reg <= replay_left_size - AXI_WIDTH;
                end
            end
        end
    end

    // *replay_shift_size* is the size of the next valid output from *replay_leftover*. The
    // *replay_leftover* register will be shifted by *replay_shift_size* after/while outputing.
    // ~replay_leftover_do_step* ensures that there are enough bits to output in *replay_leftover*.
    always_comb begin
        if (replay_leftover_do_step) begin
            if (replay_left_size > AXI_WIDTH) begin
                replay_shift_size = AXI_WIDTH;
            end else begin
                replay_shift_size = replay_left_size;
            end
        end else begin
            // If there are not enough bits for output, we must set it to 0, because this variable
            // will be used when calculating the value of *replay_is_first_packet*, which is used to
            // determine whether a new transaction begins (and whether the previous one ends).
            replay_shift_size = 0;
        end
    end

    // *replay_is_first_packet* is determined under the following to facts:
    // 1. The previous packet is finishing in the current cycle, which means there are
    //    less than or equal to AXI_WIDTH bits left.
    // 2. There will be enough bits for width calculation, which means there are more than
    //    LOGB_CHANNEL_CNT + LOGE_CHANNEL_CNT bits in replay_leftover buffer in the next
    //    cycle.
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            replay_is_first_packet <= 0;
        end else begin
            if (replay_left_size <= AXI_WIDTH) begin
                if (replay_current_in_valid) begin
                    if (replay_leftover_size + AXI_WIDTH - replay_shift_size >= LOGB_CHANNEL_CNT + LOGE_CHANNEL_CNT) begin
                        replay_is_first_packet <= 1;
                    end else begin
                        replay_is_first_packet <= 0;
                    end
                end else begin
                    if (replay_leftover_size - replay_shift_size >= LOGB_CHANNEL_CNT + LOGE_CHANNEL_CNT) begin
                        replay_is_first_packet <= 1;
                    end else begin
                        replay_is_first_packet <= 0;
                    end
                end
            end else begin
                replay_is_first_packet <= 0;
            end
        end
    end

    always_comb begin
        replay_leftover_next_assigned = replay_leftover;
        replay_leftover_next_assigned[replay_leftover_size +: AXI_WIDTH] = replay_current_in;
        replay_leftover_next_unassigned = {AXI_WIDTH'(0), replay_leftover};
    end
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            replay_leftover_size <= 0;
        end else begin
            if (replay_leftover_do_step) begin
                if (replay_current_in_valid) begin
                    replay_leftover_size <= replay_leftover_size + AXI_WIDTH - replay_shift_size;
                    replay_leftover <= replay_leftover_next_assigned[replay_shift_size +: AXI_WIDTH*2];
                end else begin
                    replay_leftover_size <= replay_leftover_size - replay_shift_size;
                    replay_leftover <= replay_leftover_next_unassigned[replay_shift_size +: AXI_WIDTH*2];
                end
            end
        end
    end

    logic [AXI_WIDTH-1:0] replay_split_out;
    logic [OFFSET_WIDTH-1:0] replay_split_out_total_size, replay_split_out_total_size_q, replay_split_out_total_size_qq;
    logic [OFFSET_WIDTH-1:0] replay_split_out_curr_size, replay_split_out_cumulated_size;
    logic [$clog2(NSTAGES):0] replay_curr;
    logic replay_out_curr_valid, replay_out_total_valid;

    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            replay_split_out_total_size <= 0;
            replay_split_out_total_size_q <= 0;
            replay_split_out_total_size_qq <= 0;
            replay_split_out_curr_size <= 0;
            replay_split_out_cumulated_size <= 0;
            replay_curr <= 0;
            replay_out_curr_valid <= 0;
        end else begin
            if (replay_is_first_packet && replay_leftover_do_step) begin
                replay_split_out_total_size <= replay_total_size;
                replay_split_out_curr_size <= replay_shift_size;
                replay_split_out_cumulated_size <= 0;
                replay_curr <= 0;
            end else if (replay_leftover_do_step) begin
                replay_split_out_cumulated_size <= replay_split_out_cumulated_size + replay_shift_size;
                replay_split_out_curr_size <= replay_shift_size;
                replay_curr <= replay_curr + 1;
            end

            if (replay_leftover_do_step) begin
                replay_split_out <= replay_leftover[0 +: AXI_WIDTH];
                replay_out_curr_valid <= 1;
            end else begin
                replay_out_curr_valid <= 0;
            end

            replay_split_out_total_size_q <= replay_split_out_total_size;
            replay_split_out_total_size_qq <= replay_split_out_total_size_q;
        end
    end

    always_ff @(posedge clk) begin
        // *replay_split_out_cumulated_size is 1 cycle behind *replay_split_out*, which makes
        // *replay_out_total_valid* two cycles behind *replay_split_out*.
        if (replay_split_out_cumulated_size >= replay_split_out_total_size_q) begin
            replay_out_total_valid <= 1;
        end else begin
            replay_out_total_valid <= 0;
        end
    end
    assign replay_out_fifo_wr_en = replay_out_total_valid;

    logic [EXT_WIDTH-1:0] replay_out_fifo_in_wrap;
    logic [AXI_WIDTH-1:0] replay_handled [NSTAGES-1:0];

    // *replay_out_fifo_in* is 2 cycles behind *replay_split_out*;
    assign replay_out_fifo_in = {replay_split_out_total_size_qq, WIDTH'(replay_out_fifo_in_wrap)};
    always_ff @(posedge clk) begin
        for (int i = 0; i < NSTAGES; i++) begin
            replay_out_fifo_in_wrap[i*AXI_WIDTH +: AXI_WIDTH] <= replay_handled[i];
        end
    end

    // *replay_handled* is 1 cycle behind replay_split_out;
    always_ff @(posedge clk) begin
        if (~sync_rst_n) begin
            for (int i = 0; i < NSTAGES; i++) begin
                replay_handled[i] <= 0;
            end
        end else begin
            if (replay_out_curr_valid) begin
                replay_handled[replay_curr] <= replay_split_out;
            end
        end
    end

    always_comb begin
        replay_dout_valid = ~replay_out_fifo_empty;
        replay_dout = replay_out_fifo_out[0 +: WIDTH];
        replay_dout_width = replay_out_fifo_out[WIDTH +: OFFSET_WIDTH];
        replay_out_fifo_rd_en = replay_dout_valid & replay_dout_ready;
    end

endmodule
