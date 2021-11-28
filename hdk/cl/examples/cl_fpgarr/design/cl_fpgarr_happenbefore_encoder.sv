`include "cl_fpgarr_defs.svh"
`include "cl_fpgarr_types.svh"
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
   rr_stream_bus_t.P out,
   output logic fifo_overflow,
   output logic fifo_underflow,
   output logic fifo_almful_hi,
   output logic fifo_almful_lo,
   output rr_packed2wb_dbg_csr_t dbg_csr
);
// High level description of how almful thresholds are calculated:
// Here is a spectrum representing how the fifo capacity is allocated/reserved,
// | empty <----------> almful_lo <--[2]---> almful_hi <---[1]---> full |
//
// In the following code, the safe space [1] is maintained by
//     RR_LOGB_FIFO_ALMFUL_THRESHOLD
// The safe space [2] is maintained by RR_NON_PCIM_W_FIFO_ALMFUL_THRESHOLD
// In brief, [1] should have enough capacity to consume all potential logging
// units generated by pcimW after the almful_hi is asserted in this module.
// [2] should have enough capacity to consume all potential logging units
// generated on all channels except pcimW after almful_lo is asserted in this
// module.
//
// RR_LOGB_FIFO_ALMFUL_THRESHOLD:
// The almful_hi should be asserted if the remaining capacity in the fifo is
// lower than RR_LOGB_FIFO_ALMFUL_THRESHOLD
// This is the hard limit, which applies to PCIM W, and transparently applies to
// all other channels with the help of almful_lo (see below).
//
// The `RECORDER_PIPE_DEPTH` is the delay of propogating signal between this
// module to the axi(l) master/slave endpoints.
// The `MERGE_TREE_HEIGHT - 1 + MERGETREE_OUT_QUEUE_NSTAGES` is the delay
// 8 is the max number of W can be sent given an AW has been transmitted.
// Reference: https://github.com/aws/aws-fpga/blob/master/hdk/docs/AWS_Shell_Interface_Specification.md#pcim_interface
// Note that sh_cl_cfg_max_payload[1:0] is at most 512 Bytes and each W is 512
// bits, so at most 8 W can be transmitted following each AW.
// This is to reserve some space in the FIFO to consume all upcoming W without
// being blocked by logging writeback.
//
// 4 is random value chosen to overprovision some resource and avoid
// calculating the accurate almful threshold
localparam int RR_LOGB_FIFO_ALMFUL_THRESHOLD =
   2*RECORDER_PIPE_DEPTH +
   2*(MERGE_TREE_HEIGHT - 1 + MERGETREE_OUT_QUEUE_NSTAGES) +
   8+
   4;

// RR_NON_PCIM_W_FIFO_ALMFUL_THRESHOLD:
// The almful_lo should be asserted if the remaining capacity in the fifo is
// lower than RR_NON_PCIM_W_FIFO_ALMFUL_THRESHOLD
// This is the hard limit to all channels except PCIM W. For PCIM W, I should
// worry than blocking a on-going CL PCIM W transaction could cause a deadlock
// among CL, PCIM interconnect and writeback modules.
//
// in.LOGE_CHANNEL_CNT is to absorb the loge, which are not controled by almful
// directly but can follow any logb with an arbitrary delay
//
// 4 is a random number chosen for peace of mind.
localparam int RR_NON_PCIM_W_FIFO_ALMFUL_THRESHOLD =
   RR_LOGB_FIFO_ALMFUL_THRESHOLD +
   2*RECORDER_PIPE_DEPTH +
   2*(MERGE_TREE_HEIGHT - 1 + MERGETREE_OUT_QUEUE_NSTAGES) +
   in.LOGE_CHANNEL_CNT +
   4;
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
   $info("LOGB FIFO config: in total %d entries, threshold for almful_hi is %d entries left, threshold for almful_lo is %d entries left\n",
      RECORD_FIFO_DEPTH, RR_LOGB_FIFO_ALMFUL_THRESHOLD,
      RR_NON_PCIM_W_FIFO_ALMFUL_THRESHOLD);
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

xpm_fifo_sync_wrapper #(
   .WIDTH(out.FULL_WIDTH + out.OFFSET_WIDTH),
   .DEPTH(RECORD_FIFO_DEPTH),
   .ALMFUL_HI_THRESHOLD(RECORD_FIFO_DEPTH - RR_LOGB_FIFO_ALMFUL_THRESHOLD),
   .ALMFUL_LO_THRESHOLD(RECORD_FIFO_DEPTH - RR_NON_PCIM_W_FIFO_ALMFUL_THRESHOLD)
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
   .almful_hi(fifo_almful_hi),
   .almful_lo(fifo_almful_lo),
   .dout_valid(out.valid),
   .empty(fifo_empty),
   .overflow(fifo_overflow),
   .underflow(fifo_underflow)
);

assign in.logb_almful_hi = fifo_almful_hi;
assign in.logb_almful_lo = fifo_almful_lo;

`ifdef SIMULATION_AVOID_X
   logic [2*out.FULL_WIDTH-1:0] check_data;
   always_ff @(posedge clk)
      if (rstn && fifo_pop) begin
         check_data[0 +: out.FULL_WIDTH] = out.data;
         check_data[out.len +: out.FULL_WIDTH] = 0;
         nox: assert(!$isunknown(check_data[0 +: out.FULL_WIDTH]));
      end
`endif

// for debugging packet loss for wb_record_inst
if (in.LOGB_CHANNEL_CNT == 14) begin
   logic [63:0] bits_non_aligned;
   logic [31:0] fifo_wr_cnt;
   always_ff @(posedge clk)
      if (!rstn) begin
         bits_non_aligned <= 0;
         fifo_wr_cnt <= 0;
      end
      else if (fifo_push) begin
         bits_non_aligned <= bits_non_aligned +
            out.OFFSET_WIDTH'(in.plogb.len + in.LOGB_CHANNEL_CNT + in.LOGE_CHANNEL_CNT);
         fifo_wr_cnt <= fifo_wr_cnt + 1;
      end
   logic [31:0] chpkt_cnt [in.LOGB_CHANNEL_CNT-1:0];
   for (genvar i = 0; i < in.LOGB_CHANNEL_CNT; i=i+1) begin
      always_ff @(posedge clk)
         if (!rstn)
            chpkt_cnt[i] <= 0;
         else if (fifo_push) begin
            chpkt_cnt[i] <= chpkt_cnt[i] + in.logb_valid[i];
         end
   end
   assign dbg_csr.fifo_wr_dbg.bits_non_aligned = bits_non_aligned;
   assign dbg_csr.fifo_wr_dbg.fifo_wr_cnt = fifo_wr_cnt;
   assign dbg_csr.chpkt_cnt.pcim_R = chpkt_cnt[0];
   assign dbg_csr.chpkt_cnt.sda_AW = chpkt_cnt[1];
   assign dbg_csr.chpkt_cnt.bar1_W = chpkt_cnt[2];
   assign dbg_csr.chpkt_cnt.ocl_AR = chpkt_cnt[3];
   assign dbg_csr.chpkt_cnt.pcis_AW = chpkt_cnt[4];
   assign dbg_csr.chpkt_cnt.ocl_AW = chpkt_cnt[5];
   assign dbg_csr.chpkt_cnt.ocl_W = chpkt_cnt[6];
   assign dbg_csr.chpkt_cnt.bar1_AW = chpkt_cnt[7];
   assign dbg_csr.chpkt_cnt.pcis_W = chpkt_cnt[8];
   assign dbg_csr.chpkt_cnt.pcis_B = chpkt_cnt[9];
   assign dbg_csr.chpkt_cnt.pcis_AR = chpkt_cnt[10];
   assign dbg_csr.chpkt_cnt.sda_AR = chpkt_cnt[11];
   assign dbg_csr.chpkt_cnt.sda_W = chpkt_cnt[12];
   assign dbg_csr.chpkt_cnt.bar1_AR = chpkt_cnt[13];
end
endmodule
