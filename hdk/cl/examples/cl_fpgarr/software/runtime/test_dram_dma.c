/*
 * Amazon FPGA Hardware Development Kit
 *
 * Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Amazon Software License (the "License"). You may not use
 * this file except in compliance with the License. A copy of the License is
 * located at
 *
 *    http://aws.amazon.com/asl/
 *
 * or in the "license" file accompanying this file. This file is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
 * implied. See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <poll.h>
#include <assert.h>

#include "fpga_hugealloc.h"
#include "fpga_pci.h"
#include "fpga_mgmt.h"
#include "fpga_dma.h"
#include "utils/lcd.h"

#include "test_dram_dma_common.h"
#include "cl_fpgarr.h"

#define	MEM_16G              (1ULL << 34)
#define USER_INTERRUPTS_MAX  (15)

/* use the standard out logger */
static const struct logger *logger = &logger_stdout;

void usage(const char* program_name);
int dma_example(int slot_id, size_t buffer_size);

void rand_string(char *str, size_t size);
int interrupt_example(int slot_id, int interrupt_number);
int axi_mstr_example(int slot_id);
int axi_mstr_ddr_access(int slot_id, pci_bar_handle_t pci_bar_handle, uint32_t ddr_hi_addr, uint32_t ddr_lo_addr, uint32_t  ddr_data);
int pcim_example(int slot_id, size_t buffer_size);

// 1ULL << 26 // 64MB
// 1ULL << 24 // 16MB
const size_t buffer_size = 1ULL << 26; // 64MB

int main(int argc, char **argv) {
    int rc;
    int slot_id = 0;
    int interrupt_n;

    switch (argc) {
    case 1:
        break;
    case 3:
        sscanf(argv[2], "%x", &slot_id);
        break;
    default:
        usage(argv[0]);
        return 1;
    }

    /* setup logging to print to stdout */
    rc = log_init("test_dram_dma");
    fail_on(rc, out, "Unable to initialize the log.");
    rc = log_attach(logger, NULL, 0);
    fail_on(rc, out, "%s", "Unable to attach to the log.");

    /* initialize the fpga_plat library */
    rc = fpga_mgmt_init();
    fail_on(rc, out, "Unable to initialize the fpga_mgmt library");

    /* check that the AFI is loaded */
    log_info("Checking to see if the right AFI is loaded...");
#ifndef SV_TEST
    rc = check_slot_config(slot_id);
    fail_on(rc, out, "slot config is not correct");
#endif
    
    rc = init_rr(slot_id);
    do_pre_rr();
    fail_on(is_replay(), out, "Skip application code, replaying");
    /* run the dma test example */
    rc = dma_example(slot_id, buffer_size);
    fail_on(rc, out, "DMA example failed");

    /* run interrupt examples */
    for (interrupt_n = 0; interrupt_n < USER_INTERRUPTS_MAX; interrupt_n++) {
        rc = 0; //interrupt_example(slot_id, interrupt_n);
        fail_on(rc, out, "Interrupt example failed");
    }

    /* run axi master example */
    rc = axi_mstr_example(slot_id);
    fail_on(rc, out, "AXI Master example failed");

    /* run pcim example */
    rc = pcim_example(slot_id, buffer_size);
    fail_on(rc, out, "PCIM example failed");

out:
    log_info("TEST %s", (rc == 0) ? "PASSED" : "FAILED");
    do_post_rr();
    return rc;
}

void usage(const char* program_name) {
    printf("usage: %s [--slot <slot>]\n", program_name);
}

/**
 * This example fills a buffer with random data and then uses DMA to copy that
 * buffer into each of the 4 DDR DIMMS.
 */
int dma_example(int slot_id, size_t buffer_size) {
    int write_fd, read_fd, dimm, rc;

    write_fd = -1;
    read_fd = -1;

    uint8_t *write_buffer = malloc(buffer_size);
    uint8_t *read_buffer = malloc(buffer_size);
    if (write_buffer == NULL || read_buffer == NULL) {
        rc = -ENOMEM;
        goto out;
    }

    read_fd = fpga_dma_open_queue(FPGA_DMA_XDMA, slot_id,
        /*channel*/ 0, /*is_read*/ true);
    fail_on((rc = (read_fd < 0) ? -1 : 0), out, "unable to open read dma queue");

    write_fd = fpga_dma_open_queue(FPGA_DMA_XDMA, slot_id,
        /*channel*/ 0, /*is_read*/ false);
    fail_on((rc = (write_fd < 0) ? -1 : 0), out, "unable to open write dma queue");

    rc = fill_buffer_urandom(write_buffer, buffer_size);
    fail_on(rc, out, "unabled to initialize buffer");

    for (dimm = 0; dimm < 4; dimm++) {
        rc = fpga_dma_burst_write(write_fd, write_buffer, buffer_size,
            dimm * MEM_16G);
        fail_on(rc, out, "DMA write failed on DIMM: %d", dimm);
    }

    bool passed = true;
    for (dimm = 0; dimm < 4; dimm++) {
        rc = fpga_dma_burst_read(read_fd, read_buffer, buffer_size,
            dimm * MEM_16G);
        fail_on(rc, out, "DMA read failed on DIMM: %d", dimm);

        uint64_t differ = buffer_compare(read_buffer, write_buffer, buffer_size);
        if (differ != 0) {
            log_error("DIMM %d failed with %lu bytes which differ", dimm, differ);
            passed = false;
        } else {
            log_info("DIMM %d passed!", dimm);
        }
    }
    rc = (passed) ? 0 : 1;

out:
    if (write_buffer != NULL) {
        free(write_buffer);
    }
    if (read_buffer != NULL) {
        free(read_buffer);
    }
    if (write_fd >= 0) {
        close(write_fd);
    }
    if (read_fd >= 0) {
        close(read_fd);
    }
    /* if there is an error code, exit with status 1 */
    return (rc != 0 ? 1 : 0);
}

int interrupt_example(int slot_id, int interrupt_number) {
    pci_bar_handle_t pci_bar_handle = PCI_BAR_HANDLE_INIT;
    struct pollfd fds[1];
    uint32_t fd, rd,  read_data;
    char event_file_name[256];
    int rc = 0;
    int poll_timeout = 1000;
    int num_fds = 1;
    int pf_id = 0;
    int bar_id = 0;
    int fpga_attach_flags = 0;
    int poll_limit = 20;
    uint32_t interrupt_reg_offset = 0xd00;

    int device_num = 0;
    rc = fpga_pci_get_dma_device_num(FPGA_DMA_XDMA, slot_id, &device_num);
    fail_on((rc = (rc != 0)? 1:0), out, "Unable to get xdma device number.");
  
    rc = sprintf(event_file_name, "/dev/xdma%i_events_%i", device_num, interrupt_number);
    fail_on((rc = (rc < 0)? 1:0), out, "Unable to format event file name.");

    log_info("Starting MSI-X Interrupt test");
    rc = fpga_pci_attach(slot_id, pf_id, bar_id, fpga_attach_flags, &pci_bar_handle);
    fail_on(rc, out, "Unable to attach to the AFI on slot id %d", slot_id);

    log_info("Polling device file: %s for interrupt events", event_file_name);
    if((fd = open(event_file_name, O_RDONLY)) == -1) {
        log_error("Error - invalid device\n");
        fail_on((rc = 1), out, "Unable to open event device");
    }
    fds[0].fd = fd;
    fds[0].events = POLLIN;

    log_info("Triggering MSI-X Interrupt %d", interrupt_number);
    rc = fpga_pci_poke(pci_bar_handle, interrupt_reg_offset , 1 << interrupt_number);
    fail_on(rc, out, "Unable to write to the fpga !");

    // Poll checks whether an interrupt was generated. 
    rd = poll(fds, num_fds, poll_timeout);
    if((rd > 0) && (fds[0].revents & POLLIN)) {
        uint32_t events_user;

        // Check how many interrupts were generated, and clear the interrupt so we can detect
        // future interrupts.
        rc = pread(fd, &events_user, sizeof(events_user), 0);
        fail_on((rc = (rc < 0)? 1:0), out, "call to pread failed.");

        log_info("Interrupt present for Interrupt %i, events %i. It worked!",
               interrupt_number, events_user);

        //Clear the interrupt register
        rc = fpga_pci_poke(pci_bar_handle, interrupt_reg_offset , 0x1 << (16 + interrupt_number) );
        fail_on(rc, out, "Unable to write to the fpga !");
    }
    else{
        log_error("No interrupt generated- something went wrong.");
        fail_on((rc = 1), out, "Interrupt generation failed");
    }
    close(fd);

    //Clear the interrupt register
    do{
        // In this CL, a successful interrupt is indicated by the CL setting bit <interrupt_number + 16>
        // of the interrupt register. Here we check that bit is set and write 1 to it to clear.
        rc = fpga_pci_peek(pci_bar_handle, interrupt_reg_offset, &read_data);
        fail_on(rc, out, "Unable to read from the fpga !");
        read_data = read_data & (1 << (interrupt_number + 16));

        rc = fpga_pci_poke(pci_bar_handle, interrupt_reg_offset , read_data );
        fail_on(rc, out, "Unable to write to the fpga !");

        poll_limit--;
    } while (!read_data && poll_limit > 0);

out:
    if(fd){
        close(fd);
    }
    return rc;
}

int axi_mstr_example(int slot_id) {
    int rc;
    pci_bar_handle_t pci_bar_handle = PCI_BAR_HANDLE_INIT;
    int pf_id = 0;
    int bar_id = 0;
    int fpga_attach_flags = 0;
    uint32_t ddr_hi_addr, ddr_lo_addr, ddr_data;

    rc = fpga_pci_attach(slot_id, pf_id, bar_id, fpga_attach_flags, &pci_bar_handle);
    fail_on(rc, out, "Unable to attach to the AFI on slot id %d", slot_id);

    log_info("Starting AXI Master to DDR test");

    /* DDR A Access */
    ddr_hi_addr = 0x00000001;
    ddr_lo_addr = 0xA021F700;
    ddr_data    = 0xA5A61A2A;

    rc = axi_mstr_ddr_access(slot_id, pci_bar_handle, ddr_hi_addr, ddr_lo_addr, ddr_data);
    fail_on(rc, out, "Unable to access DDR A.");

    /* DDR B Access */
    ddr_hi_addr = 0x00000004;
    ddr_lo_addr = 0x529C8400;
    ddr_data    = 0x1B80C948;

    rc = axi_mstr_ddr_access(slot_id, pci_bar_handle, ddr_hi_addr, ddr_lo_addr, ddr_data);
    fail_on(rc, out, "Unable to access DDR B.");

    /* DDR C Access */
    ddr_hi_addr = 0x00000008;
    ddr_lo_addr = 0x2078BC00;
    ddr_data    = 0x8BD18801;

    rc = axi_mstr_ddr_access(slot_id, pci_bar_handle, ddr_hi_addr, ddr_lo_addr, ddr_data);
    fail_on(rc, out, "Unable to access DDR C.");

    /* DDR D Access */
    ddr_hi_addr = 0x0000000C;
    ddr_lo_addr = 0xD0167700;
    ddr_data    = 0xCA02183D;

    rc = axi_mstr_ddr_access(slot_id, pci_bar_handle, ddr_hi_addr, ddr_lo_addr, ddr_data);
    fail_on(rc, out, "Unable to access DDR D.");

out:
    return rc;
}

/* Helper function for accessing DDR controllers via AXI Master block */
int axi_mstr_ddr_access(int slot_id, pci_bar_handle_t pci_bar_handle, uint32_t ddr_hi_addr, uint32_t ddr_lo_addr, uint32_t  ddr_data) {
    int rc;
    static uint32_t ccr_offset  = 0x500;
    static uint32_t cahr_offset = 0x504;
    static uint32_t calr_offset = 0x508;
    static uint32_t cwdr_offset = 0x50C;
    static uint32_t crdr_offset = 0x510;
    uint32_t read_data;
    int poll_limit = 20;

    /* Issue AXI Master Write Command */
    rc = fpga_pci_poke(pci_bar_handle, cahr_offset, ddr_hi_addr);
    fail_on(rc, out, "Unable to write to AXI Master CAHR register!");
    rc = fpga_pci_poke(pci_bar_handle, calr_offset, ddr_lo_addr);
    fail_on(rc, out, "Unable to write to AXI Master CALR register!");
    rc = fpga_pci_poke(pci_bar_handle, cwdr_offset, ddr_data);
    fail_on(rc, out, "Unable to write to AXI Master CWDR register!");
    rc = fpga_pci_poke(pci_bar_handle, ccr_offset, 0x1);
    fail_on(rc, out, "Unable to write to AXI Master CCR register!");

    /* Poll for done */
    do{
        // Read the CCR until the done bit is set
        rc = fpga_pci_peek(pci_bar_handle, ccr_offset, &read_data);
        fail_on(rc, out, "Unable to read AXI Master CCR from the fpga !");
        read_data = read_data & (0x2);
        poll_limit--;
    } while (!read_data && poll_limit > 0);
    fail_on((rc = !read_data), out, "AXI Master write to DDR did not complete. Done bit not set in CCR.");

    /* Issue AXI Master Read Command */
    rc = fpga_pci_poke(pci_bar_handle, ccr_offset, 0x5);
    fail_on(rc, out, "Unable to write to AXI Master CCR register!");

    /* Poll for done */
    poll_limit = 20;
    do{
        // Read the CCR until the done bit is set
        rc = fpga_pci_peek(pci_bar_handle, ccr_offset, &read_data);
        fail_on(rc, out, "Unable to read AXI Master CCR from the fpga !");
        read_data = read_data & (0x2);
        poll_limit--;
    } while (!read_data && poll_limit > 0);
    fail_on((rc = !read_data), out, "AXI Master read from DDR did not complete. Done bit not set in CCR.");

    /* Compare Read/Write Data */
    // Read the CRDR for read data
    rc = fpga_pci_peek(pci_bar_handle, crdr_offset, &read_data);
    fail_on(rc, out, "Unable to read AXI Master CRDR from the fpga !");
    if(read_data == ddr_data) {
        rc = 0;
        log_info("Resulting value at address 0x%x%x matched expected value 0x%x. It worked!", ddr_hi_addr, ddr_lo_addr, ddr_data);
    }
    else{
        rc = 1;
        fail_on(rc, out, "Resulting value, 0x%x did not match expected value 0x%x at address 0x%x%x. Something didn't work.\n", read_data, ddr_data, ddr_hi_addr, ddr_lo_addr);
    }

out:
    return rc;
}

int pcim_example(int slot_id, size_t buffer_size) {
    int rc;
    pci_bar_handle_t ocl_bar_handle = PCI_BAR_HANDLE_INIT;
    rc = fpga_pci_attach(slot_id, /*pf_id*/ 0, /*bar_id*/ 0, /*flags*/ 0,
                         &ocl_bar_handle);
    fail_on(rc, out, "Unable to attach to the OCL bar");

    void *va;
    uint64_t pa;
    uint64_t sizeB;
    rc = fpga_hugealloc_get(&va, &pa, &sizeB);
    fail_on(rc, out, "Unable to alloc hugepage");

    // {{{ setup test for pcim
    // I suppose this is to write 16 x 512 bits
    log_info("PCIM example, host_mem: va %p, pa %p, buffer size %ld", va,
             (void *)(pa), sizeB);
    fail_on((buffer_size > sizeB), free_huge, "HugePageAlloc Too small");
    memset(va, 0, buffer_size);
    // 0x30: A value of 0 will drive PCIS/XDMA transactions to DDR.
    rc = fpga_pci_poke(ocl_bar_handle, 0x030, 0);
    fail_on(rc, free_huge, "Unable to poke 0x030");
    //Offset 0x10:
    //     15:0 - Write Num Inst - Number of write instructions
    //     31:16 - Read Num inst - Number of read instructions
    rc = fpga_pci_poke(ocl_bar_handle, 0x010, 1);
    fail_on(rc, free_huge, "Unable to poke 0x010");
    // Offset 0x1c: Write Index  - Write instruction Index
    rc = fpga_pci_poke(ocl_bar_handle, 0x01c, 0);
    fail_on(rc, free_huge, "Unable to poke 0x01c");
    // Offset 0x20: Write address low - Write instruction address
    rc = fpga_pci_poke(ocl_bar_handle, 0x020, pa & 0xffffffff);
    fail_on(rc, free_huge, "Unable to poke 0x020");
    // Offset 0x24: Write address high - Write instruction address
    rc = fpga_pci_poke(ocl_bar_handle, 0x024, (pa >> 32) & 0xffffffff);
    fail_on(rc, free_huge, "Unable to poke 0x024");
    // Offset 0x28: Write data - Write instruction start data.  All other data will be incrementing or PRBS
    rc = fpga_pci_poke(ocl_bar_handle, 0x028, 0x1234);
    fail_on(rc, free_huge, "Unable to poke 0x028");
    // Offset 0x2c: Write length/User - Write instruction length (number of data phases.  note there are no partial data phases)
    //     7:0 - Length -- this is the number of AXI data phases.   Lower address bits define first data offset
    //     15:8 - Last data adj -- Number of DW to adj last data phase (0 means all DW are valid, 1 means all but 1DW valid, etc...)
    //     31:16 - User
    uint32_t wr_burst = 8; // max is 8
    uint32_t sizeB_burst = wr_burst*64;
    uint8_t wraddr_inc_shift = 9;
    assert((1 << wraddr_inc_shift) == sizeB_burst);
    if (pa & ((1 << wraddr_inc_shift)-1)) {
        printf("Warning, pa is %#lx, shift mask is %#x, overlapping.\n",
                pa, ((1 << wraddr_inc_shift)-1));
    }
    uint32_t Nloop = buffer_size / sizeB_burst;
    rc = fpga_pci_poke(ocl_bar_handle, 0x02c, wr_burst - 1);
    fail_on(rc, free_huge, "Unable to poke 0x02c");
    // Offset 0x00, check test_dram_dma_common.h for details
    pcim_tst_cfg_t tstcfg = {
        .continuous = 1,
        .incLoopData = 1,
        .PRBS = 0,
        .readCompEn = 0,
        .syncEn = 0,
        .iterMode = 1,
        .loopHiAddrEn = 1,
        .userIDMode = 0,
        .wrAddrLoopShift = wraddr_inc_shift,
        .rdAddrLoopShift = 0,
        .rsvd = 0,
        .incIDMode = 0,
        .constData = 0,
        .unused = 0
    };
    rc = fpga_pci_poke(ocl_bar_handle, 0x00, tstcfg.val);
    fail_on(rc, free_huge, "Unable to poke 0x00");
    //Offset 0xc0: Write Loop count low - In loop mode number of times loop
    //Offset 0xc4: Write Loop count high
    rc = fpga_pci_poke(ocl_bar_handle, 0xc0, Nloop);
    fail_on(rc, free_huge, "Unable to poke 0xc0");
    rc = fpga_pci_poke(ocl_bar_handle, 0xc4, 0x00);
    fail_on(rc, free_huge, "Unable to poke 0xc4");
    //Offset 0x08:
    //     0 - Write Go (read back write in progress) - Write this bit to start executing the write instructions.  Reads back '1' while write instructions are in progress.
    //     1 - Read Go (read back write in progress) - Write this bit to start executing the read instructions.  Reads back '1' while read instructions are in progress.
    //     2 - Read response pending (read only).  REad only, reads back '1' while read responses are pending.
    rc = fpga_pci_poke(ocl_bar_handle, 0x008, 0x1);
    fail_on(rc, free_huge, "Unable to poke 0x008");
    uint32_t *va_u32 = (uint32_t*)va;
    for (size_t i = 0; i < wr_burst * 512 / 8 / sizeof(*va_u32); ++i) {
        log_info("PCIM example addr[%ld] = %x", i, va_u32[i]);
    }
    // }}} end of set for pcim
free_huge:
    fpga_hugealloc_put(va);
out:
    return rc;
}
