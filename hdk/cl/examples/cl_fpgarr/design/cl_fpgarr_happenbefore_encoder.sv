`include "cl_fpgarr_defs.svh"
`include "cl_fpgarr_packing_cfg.svh"
// This module encodes the happen-before information from a packed logging bus
// in a even more compact format.
// i.e. buffer standalong transaction ends (loge_valid) and encode them to
// transaction begins (logb_valid, logb_data)
//
// About almful:
// The almful is only meant for logb, but remember that:
// 1. loge_valid cannot be stalled and can be sent after any logb_valid even
// though the logb_almful is asserted.
// 2. For channels whose logb_valid is tracked by the input packed_logging_bus,
// their corresponding loge_valid are guaranteed to not be overwritten. i.e. any
// loge_valid can be buffered in this module (in loge_valid_out) and be
// piggybacked to next logb_valid. This is because these loge_valid can be
// paired with the corresponding logb_valid and there will not be transaction
// ends if there is not transaction starts.
// 3. However, for channels whose logb_valid is not tracked by the input
// packed_logging_bus, their corresponding loge_valid can be overwritten. i.e.
// a loge_valid got buffered is not be piggybacked to any logb_valid before next
// loge_valid comes. e.g. the input packed_logging_bus tracks the logb of AR,
// loge of R but the logb of R is not tracked. For burst reads, there will be
// one AR transaction followed by multiple R transactions. The stop of these
// R transactions may overlapping each other and be overwritten.
// 4. The curernt solution is to allow loge_valid to generate new logging unit
// even if there is no logb_valid.
// CONCLUSION: So we need to take loge_valid into consideration when calc the
// almful threshold.
//
// The almful is generated from the fifo here and propogate all the way to the
// individual channel loggers.
// The in.logb_almful should be asserted if the remaining capacity in the fifo
// greater or equal to the maximum number of logging units may be generated in
// the future, which consists of
// 1. on-the-fly logb_related data
// 2. the pipelined propogation delay of the logb_almful itself
// 3.
// The optimal resource utilization is achieved if the logb_almful is asserted
// when remaining capacity "equal to" all potential future packets.
// At this moment, the almful is affected by:
// 1. 2*RECORDER_PIPE_DEPTH, the pipeline from individual channel logger to the
//     logb packing module. almful is also pipelined
// 2. 2*(MERGE_TREE_HEIGHT - 1 + MERGETREE_OUT_QUEUE_NSTAGES), the pipeline
//     stages in the merge tree. almful is also pipelined.
// 3. in.LOGE_CHANNEL_CNT, the maximum number of logging units could be
//     generated by standalong loge_valid to avoid loge_valid_out overwrite when
//     there is no logb_valid.
module rr_packed2writeback_bus #(
   parameter int MERGE_TREE_HEIGHT
) (
   input wire clk,
   input wire rstn,
   rr_packed_logging_bus_t.C in,
   rr_stream_bus_t.P out
);
// RR_LOGB_FIFO_ALMFUL_THRESHOLD:
// 8 is random value chosen to overprovision some resource and avoid
// calculating the accurate almful threshold
localparam int RR_LOGB_FIFO_ALMFUL_THRESHOLD =
   2*RECORDER_PIPE_DEPTH +
   2*(MERGE_TREE_HEIGHT - 1 + MERGETREE_OUT_QUEUE_NSTAGES) +
   in.LOGE_CHANNEL_CNT +
   8;

// parameter check
generate
   if (in.LOGB_CHANNEL_CNT + in.LOGE_CHANNEL_CNT + in.LOGB_DATA_WIDTH
       != out.FULL_WIDTH)
    $error("Writeback FULL_WIDTH mismatch: logb W%d, loge W%d, packed_logb_data W%d, writeback W%d\n",
      in.LOGB_CHANNEL_CNT, in.LOGE_CHANNEL_CNT, in.LOGB_DATA_WIDTH,
      out.FULL_WIDTH);
   if (RR_LOGB_FIFO_ALMFUL_THRESHOLD >= RECORD_FIFO_DEPTH)
      $error("Invalid RR_LOGB_FIFO config: ALMFUL_THRESHOLD %d, RECORD_FIFO_DEPTH %d\n",
         RR_LOGB_FIFO_ALMFUL_THRESHOLD, RECORD_FIFO_DEPTH);
   $info("LOGB FIFO config: in total %d entries, threshold is %d entries left\n",
      RECORD_FIFO_DEPTH, RR_LOGB_FIFO_ALMFUL_THRESHOLD);
endgenerate
// forward declare logb_fifo control signals
logic fifo_push;
logic fifo_pop;

// loge_valid_output is the signal outputting to the writeback_bus, it should be
// in-sync with out.valid
// Invariant description of loge_valid_output:
//
// 1. loge_valid_output[i] shows whether one (and can only be one) transaction
// has finished on channel[i] between now (the cycle some logb_valid are true,
// or some loge_valid is going to be overwritten, but excluding the loge_valid
// happens at the same cycle) and the last time generating some logging units.
// e.g. if logb_valid[i] && loge_valid[i], which only happen if the transaction
// really lasts for only one cycle (ready was asserted in advance),
// logb_valid[i] is packed with loge_valid_out[i] and loge_valid[i] will be used
// to update loge_valid_out[i] at the next cycle.
//
// 2. In other words, when out.valid is asserted, loge_valid_output[i] together
// with all historical loge_valid_output values, represents the number of
// transactions finished in each channel (count the 1s) before the start of the
// logb_{valid, data} in the out.data.
logic [in.LOGE_CHANNEL_CNT-1:0] loge_valid_out;
// loge_valid_overwrite is asserted if the incoming loge_valid will overwrite
// loge_valid_out, so we need to generate a new logging unit
logic [in.LOGE_CHANNEL_CNT-1:0] loge_valid_overwrite;
logic new_pkt_for_loge;

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
      if (fifo_push)
         // the incoming loge_valid is not related to the happen-before of
         // the current logb_valid. That will be deferred to the next
         // transmission
         loge_valid_out[i] <= in.loge_valid[i];
      else if (in.loge_valid[i]) begin
         // a standlone loge_valid comes
         loge_valid_out[i] <= 1;
         // there could only be at most 1 transaction finished between two
         // logging unit in the trace.
         no_loge_overwrite: assert(!loge_valid_out[i]);
      end

assign loge_valid_overwrite = in.loge_valid & loge_valid_out;
assign new_pkt_for_loge = |loge_valid_overwrite;
// sanity check for loge_valid_overwrite
always_ff @(posedge clk)
   if (rstn && !in.plogb.any_valid)
      assert(in.logb_valid == 0);


// The FIFO to handle almful
// MSB to LSB: out.data, out.len
logic fifo_full;
logic fifo_empty;
assign fifo_push =
   in.plogb.any_valid || // generate new packet for logb
   new_pkt_for_loge;     // generate new packet for loge
assign fifo_pop = out.valid && out.ready;
`define USE_XPM_FIFO_SYNC
`ifndef USE_XPM_FIFO_SYNC
// merged_fifo (xilinx fifo_generator)
merged_fifo #(
   .WIDTH(out.FULL_WIDTH + out.OFFSET_WIDTH),
   .ALMFULL_THRESHOLD(RR_LOGB_FIFO_ALMFUL_THRESHOLD)
) logb_fifo (
   .clk(clk),
   .rst(!rstn),
   .din({
      in.plogb.data,      // -
      loge_valid_out,     //  |-> These become out.data
      in.logb_valid,      // -
      out.OFFSET_WIDTH'(
         in.plogb.len + in.LOGB_CHANNEL_CNT + in.LOGE_CHANNEL_CNT
      ) // this is the out.len
   }),
   .wr_en(fifo_push),
   .dout({out.data, out.len}),
   .rd_en(fifo_pop),
   .full(fifo_full),
   .almfull(in.logb_almful),
   .empty(fifo_empty)
);
assign out.valid = !fifo_empty;
`else
// test xpm_fifo_sync
xpm_fifo_sync_wrapper #(
   .WIDTH(out.FULL_WIDTH + out.OFFSET_WIDTH),
   .DEPTH(RECORD_FIFO_DEPTH),
   .ALMFUL_THRESHOLD(RECORD_FIFO_DEPTH - RR_LOGB_FIFO_ALMFUL_THRESHOLD)
) xpm_inst (
   .clk(clk), .rst(!rstn),
   .din({
      in.plogb.data,      // -
      loge_valid_out,     //  |-> These become out.data
      in.logb_valid,      // -
      out.OFFSET_WIDTH'(
         in.plogb.len + in.LOGB_CHANNEL_CNT + in.LOGE_CHANNEL_CNT
      ) // this is the out.len
   }),
   .wr_en(fifo_push),
   .dout({out.data, out.len}),
   .rd_en(fifo_pop),
   .full(fifo_full),
   .almful(in.logb_almful),
   .dout_valid(out.valid),
   .empty(fifo_empty)
);
// end of test xpm_fifo_sync
`endif

`ifdef TEST_RECORD_FIFO_ALMFUL
logic [1:0] cnt;
always_ff @(posedge clk)
   if (!rstn)
      cnt <= 0;
   else
      cnt <= cnt + 1;
assign in.logb_almful = cnt[1];
`endif
endmodule
