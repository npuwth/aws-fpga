#ifndef CL_FPGARR_H
#define CL_FPGARR_H
#define CL_FPGARR_CSR_BASE 0x100000
#include <stdint.h>

#define RR_CSR_VERSION_INT 20211128
typedef enum {
  BUF_ADDR_HI = 0,           // 0
  BUF_ADDR_LO,               // 1
  BUF_SIZE_HI,               // 2
  BUF_SIZE_LO,               // 3
  RECORD_BUF_UPDATE,         // 4
  REPLAY_BUF_UPDATE,         // 5
  RECORD_FORCE_FINISH,       // 6
  REPLAY_START,              // 7, currently not used
  RR_MODE,                   // 8
  RR_STATE,                  // 9
  RECORD_BITS_HI,            // 10
  RECORD_BITS_LO,            // 11
  REPLAY_BITS_HI,            // 12
  REPLAY_BITS_LO,            // 13
  VALIDATE_BUF_UPDATE,       // 14
  RR_RSVD_2,                 // 15
  VALIDATE_BITS_HI,          // 16
  VALIDATE_BITS_LO,          // 17
  RT_REPLAY_BITS_HI,         // 18
  RT_REPLAY_BITS_LO,         // 19
  RR_TRACE_FIFO_ASSERT,      // 20
  RR_CSR_VERSION,            // 21
  // gefei dbg_csr
  RR_WB_RECORD_DBG_BITS_NON_ALIGNED_HI,
  RR_WB_RECORD_DBG_BITS_NON_ALIGNED_LO,
  RR_WB_RECORD_DBG_BITS_FIFO_WR_CNT,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_pcim_R,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_sda_AW,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_bar1_W,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_ocl_AR,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_pcis_AW,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_ocl_AW,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_ocl_W,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_bar1_AW,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_pcis_W,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_pcis_B,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_pcis_AR,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_sda_AR,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_sda_W,
  RR_WB_RECORD_DBG_BITS_CHPKT_CNT_bar1_AR,
} rr_csr_enum;

#define RR_CSR_ADDR(idx) (CL_FPGARR_CSR_BASE + 0x4 * idx)
#define UINT64_HI32(x) ((((uint64_t) x) >> 32) & 0xffffffff)
#define UINT64_LO32(x) ( ((uint64_t) x) & 0xffffffff)
#define UINT64_FROM32(hi, lo) ((((uint64_t) hi) << 32) | ((uint64_t) lo))

#ifdef SV_TEST
// 128 MB
#define DEFAULT_BUFFER_SIZE (0x8000000)
#define POLLING_INTERVAL 1
#else
#define DEFAULT_BUFFER_SIZE (1ULL << 30)
#define POLLING_INTERVAL 5
#endif
#define BUFFER_ALIGNMENT 4096
#define TRACE_LEN_BYTES 8

// MACRO configuration
#undef DUMP_TRACE_TXT

extern int init_rr(int slot_id);
extern void do_pre_rr();
extern void do_post_rr();

extern uint8_t is_record();
extern uint8_t is_replay();
extern uint8_t is_validate();

#endif // CL_FPGARR_H
