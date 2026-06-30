#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sleep.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xiic.h"
#include "xuartps_hw.h"
#include "supervisor.h"

#define IIC_BASEADDR         XPAR_XIIC_0_BASEADDR

#if defined(XPAR_COEFF_CTRL_BASEADDR)
#define COEFF_CTRL_BASEADDR  XPAR_COEFF_CTRL_BASEADDR
#elif defined(XPAR_COEFF_CTRL_0_BASEADDR)
#define COEFF_CTRL_BASEADDR  XPAR_COEFF_CTRL_0_BASEADDR
#elif defined(XPAR_COEFF_CTRL_0_S_AXI_BASEADDR)
#define COEFF_CTRL_BASEADDR  XPAR_COEFF_CTRL_0_S_AXI_BASEADDR
#else
#define COEFF_CTRL_BASEADDR  0x43C00000U
#endif

#define I2C_CODEC_ADDR       0x3B 

#define COEFF_REG_CONTROL         0x00U
#define COEFF_REG_TARGET          0x04U
#define COEFF_REG_WDATA           0x08U
#define COEFF_REG_RDATA           0x0CU
#define COEFF_REG_SHADOW_PENDING  0x10U
#define COEFF_REG_LIVE_ACTIVE     0x14U
#define COEFF_REG_LIVE_PENDING    0x18U
#define COEFF_REG_STATUS          0x1CU
#define COEFF_REG_VERSION         0x20U

/* Read-only feedback-risk feature registers (ss_coeff_axi_ctrl). */
#define COEFF_REG_FEAT_INNOV_BASE 0x44U   /* E_innov[b] = base + 4*b */
#define COEFF_REG_FEAT_BAND_BASE  0x54U   /* E_band[b]  = base + 4*b */
#define COEFF_REG_FEAT_MODAL_BASE 0x64U   /* E_modal[b] = base + 4*b */

#define COEFF_CTRL_CMD_WRITE      0x00000001U
#define COEFF_CTRL_CMD_READ       0x00000002U
#define COEFF_STATUS_READBACK_VLD 0x00000100U

#define UART_SYNC0                0x55U
#define UART_SYNC1                0xAAU
#define UART_RESP_BIT             0x80U
#define UART_ERROR_CMD            0x7FU

/*
 * UART is provisioning- and telemetry-only. Active-bank selection is owned
 * exclusively by the supervisor (thesis 5.8): once running, the system is
 * hands-off. The legacy manual SET_PENDING_BANK/COMMIT_BANKS commands were
 * removed so there is no second writer racing the supervisor for the
 * SHADOW_PENDING/commit registers. WRITE_BLOCK still loads bank *contents*
 * (a commissioning activity); the supervisor decides when a bank goes live.
 */
#define UART_CMD_WRITE_BLOCK      0x01U
#define UART_CMD_READ_BLOCK       0x02U
#define UART_CMD_GET_STATUS       0x05U

/* ----------------------------------------------------------------------- *
 *  Single-band PoC bring-up hook (TEMPORARY).
 *  When POC_SINGLE_BAND is 1, the idle loop bypasses the supervisor's
 *  risk/position/switching logic and drives ONE controller slot directly:
 *  gate held open (g = 1.0) and alpha toggled between 0 and full over UART.
 *  This is a manual A/B harness for gain-before-feedback measurement, NOT the
 *  production supervisor path. Set POC_SINGLE_BAND to 0 to restore normal
 *  supervisor-driven control.
 * ----------------------------------------------------------------------- */
#define POC_SINGLE_BAND   1
#define POC_BAND          1      /* controller slot under test (1 = 300-1000 Hz) */

#if POC_SINGLE_BAND
#define UART_CMD_POC_SET_ALPHA    0x10U   /* payload: 1 byte, 0..255 -> alpha 0..1 */
#endif

#define UART_STATUS_OK            0x00U
#define UART_STATUS_BAD_CHECKSUM  0x01U
#define UART_STATUS_BAD_LENGTH    0x02U
#define UART_STATUS_BAD_COMMAND   0x03U
#define UART_STATUS_BAD_ARGS      0x04U
#define UART_STATUS_RANGE         0x05U
#define UART_STATUS_HW_TIMEOUT    0x06U

#define UART_MAX_PAYLOAD          2048U
#define SS_CTRL_COUNT             4U
#define SS_BANK_COUNT             8U
#define SS_COEFFS_PER_BANK        1024U
#define SS_BANK_FIELD_MASK        0x7U
#define SS_CTRL_FIELD_MASK        0x3U
#define SS_COEFF_INDEX_MASK       0x7FFU
#define SS_COEFF_MIN              (-8388608)
#define SS_COEFF_MAX              (8388607)

typedef struct {
    uint8_t cmd;
    uint8_t seq;
    uint16_t length;
    uint8_t payload[UART_MAX_PAYLOAD];
} uart_frame_t;

XIic iic;

#if POC_SINGLE_BAND
/* PoC test alpha for POC_BAND, in Q22 (0 = controller off, Q22_FULL = full).
 * Set live via UART_CMD_POC_SET_ALPHA byte payload in [0,255], mapped linearly
 * to Q22 alpha. Starts off so the baseline is the uncontrolled monitor path. */
static volatile s32 g_poc_alpha = 0;
#endif

int iic_write_reg(u16 reg_addr, u8 val) {
    u8 buf[3] = {reg_addr >> 8, reg_addr & 0xFF, val};
    return (XIic_Send(IIC_BASEADDR, I2C_CODEC_ADDR, buf, 3, XIIC_STOP) == 3) ? XST_SUCCESS : XST_FAILURE;
}

int iic_write_pll(u8 *data) {
    u8 buf[8];
    buf[0] = 0x40; buf[1] = 0x02; 
    memcpy(&buf[2], data, 6);     
    return (XIic_Send(IIC_BASEADDR, I2C_CODEC_ADDR, buf, 8, XIIC_STOP) == 8) ? XST_SUCCESS : XST_FAILURE;
}

int iic_read_reg(u16 reg_addr, u8 *data, int bytes) {
    u8 buf[2] = {reg_addr >> 8, reg_addr & 0xFF};
    int sent_bytes = XIic_Send(IIC_BASEADDR, I2C_CODEC_ADDR, buf, 2, XIIC_REPEATED_START);
    if (sent_bytes != 2) return XST_FAILURE;
    int recv_bytes = XIic_Recv(IIC_BASEADDR, I2C_CODEC_ADDR, data, bytes, XIIC_STOP);
    return (recv_bytes == bytes) ? XST_SUCCESS : XST_FAILURE;
}

static void codec_write_checked(u16 reg_addr, u8 value, const char *label) {
    u8 rb = 0xFF;
    int wstat = iic_write_reg(reg_addr, value);
    int rstat = iic_read_reg(reg_addr, &rb, 1);
    xil_printf(
        "%s reg 0x%04X <= 0x%02X (wr:%s rd:%s rb:0x%02X)\n",
        label,
        (unsigned int)reg_addr,
        (unsigned int)value,
        (wstat == XST_SUCCESS) ? "ok" : "err",
        (rstat == XST_SUCCESS) ? "ok" : "err",
        (unsigned int)rb
    );
}

void codec_init_sequence() {
    u8 val[8];
    u8 pll_config[6] = {0x00, 0xFD, 0x00, 0x0C, 0x20, 0x01}; 
    xil_printf("Waking up ADAU1761: LAUX -> FPGA -> LHP...\n");

    // 1. Clock Control (PLL Off)
    iic_write_reg(0x4000, 0x0E);

    // 2. PLL Setup (12.288MHz -> 48kHz)
    iic_write_pll(pll_config);
    while(1) {
        iic_read_reg(0x4002, val, 6);
        if(val[5] & 0x02) { xil_printf("PLL Locked!\n"); break; }
        usleep(1000);
    }

    // 3. Core On, Set as I2S Main (drives BCLK and LRCLK from PLL)
    iic_write_reg(0x4000, 0x0F);
    iic_write_reg(0x4015, 0x01);  // R15 SPCR0: MS=1 → ADAU1761 generates BCLK/LRCLK
    {
        u8 r15 = 0xFF;
        iic_read_reg(0x4015, &r15, 1);
        xil_printf("R15 readback: 0x%02X (expect 0x01)\n", r15);
    }

    // 4. ROUTE INPUT: LAUX/RAUX (Blue Jack) -> ADCs
    iic_write_reg(0x400A, 0x01); // Mixer 1 (Left Record) Enable
    iic_write_reg(0x400B, 0x05); // LAUX to Mixer 1
    iic_write_reg(0x400C, 0x01); // Mixer 2 (Right Record) Enable
    iic_write_reg(0x400D, 0x05); // RAUX to Mixer 2

    // 5. ROUTE OUTPUT: DACs -> LHP/RHP (Black Jack)
    codec_write_checked(0x401C, 0x21, "PB_MIX_L"); // Playback Mixer L: Unmute DAC L
    codec_write_checked(0x401E, 0x41, "PB_MIX_R"); // Playback Mixer R: Unmute DAC R
    codec_write_checked(0x4023, 0xE7, "HP_VOL_L"); // Line Out L: Max Vol (+6dB), Unmute
    codec_write_checked(0x4024, 0xE7, "HP_VOL_R"); // Line Out R: Max Vol (+6dB), Unmute

    codec_write_checked(0x4020, 0x03, "PLBK_L");
    codec_write_checked(0x4021, 0x09, "PLBK_R");
    codec_write_checked(0x4025, 0xFF, "LO_VOL_L");
    codec_write_checked(0x4026, 0xFF, "LO_VOL_R");
    
    // 6. Power Up Converters
    iic_write_reg(0x4019, 0x03); // ADC On
    iic_write_reg(0x4029, 0x03); // DAC Power On
    iic_write_reg(0x402A, 0x03); // DAC On

    // 7. Serial Data Routing
    iic_write_reg(0x40F2, 0x01); // Serial In [L0, R0] -> DACs
    iic_write_reg(0x40F3, 0x01); // ADCs [L, R] -> Serial Out [L0, R0]
    
    iic_write_reg(0x40F9, 0x7F); // Clocks On
    iic_write_reg(0x40FA, 0x03); 
    xil_printf("Codec Routing Complete.\n");
}

static inline void coeff_write_reg(uint32_t offset, uint32_t value) {
    Xil_Out32(COEFF_CTRL_BASEADDR + offset, value);
}

static inline uint32_t coeff_read_reg(uint32_t offset) {
    return Xil_In32(COEFF_CTRL_BASEADDR + offset);
}

static inline void uart_send_byte(uint8_t value) {
    XUartPs_SendByte(STDOUT_BASEADDRESS, value);
}

static inline uint8_t uart_has_data(void) {
    return XUartPs_IsReceiveData(STDIN_BASEADDRESS);
}

static inline uint8_t uart_recv_byte(void) {
    return XUartPs_RecvByte(STDIN_BASEADDRESS);
}

static uint16_t read_le16(const uint8_t *data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static int32_t read_le32s(const uint8_t *data) {
    return (int32_t)((uint32_t)data[0]
                   | ((uint32_t)data[1] << 8)
                   | ((uint32_t)data[2] << 16)
                   | ((uint32_t)data[3] << 24));
}

static void write_le16(uint8_t *data, uint16_t value) {
    data[0] = (uint8_t)(value & 0xFFU);
    data[1] = (uint8_t)((value >> 8) & 0xFFU);
}

static void write_le32(uint8_t *data, uint32_t value) {
    data[0] = (uint8_t)(value & 0xFFU);
    data[1] = (uint8_t)((value >> 8) & 0xFFU);
    data[2] = (uint8_t)((value >> 16) & 0xFFU);
    data[3] = (uint8_t)((value >> 24) & 0xFFU);
}

static uint8_t frame_checksum(uint8_t cmd, uint8_t seq, uint16_t length, const uint8_t *payload) {
    uint8_t checksum = 0U;
    uint16_t idx;

    checksum ^= cmd;
    checksum ^= seq;
    checksum ^= (uint8_t)(length & 0xFFU);
    checksum ^= (uint8_t)((length >> 8) & 0xFFU);

    for (idx = 0U; idx < length; ++idx) {
        checksum ^= payload[idx];
    }

    return checksum;
}

static void uart_send_frame(uint8_t cmd, uint8_t seq, const uint8_t *payload, uint16_t length) {
    uint16_t idx;
    uint8_t checksum = frame_checksum(cmd, seq, length, payload);

    uart_send_byte(UART_SYNC0);
    uart_send_byte(UART_SYNC1);
    uart_send_byte(cmd);
    uart_send_byte(seq);
    uart_send_byte((uint8_t)(length & 0xFFU));
    uart_send_byte((uint8_t)((length >> 8) & 0xFFU));
    for (idx = 0U; idx < length; ++idx) {
        uart_send_byte(payload[idx]);
    }
    uart_send_byte(checksum);
}

static int uart_recv_frame(uart_frame_t *frame) {
    uint16_t idx;
    uint8_t checksum;

    while (1) {
        if (uart_recv_byte() != UART_SYNC0) {
            continue;
        }

        if (uart_recv_byte() == UART_SYNC1) {
            break;
        }
    }

    frame->cmd = uart_recv_byte();
    frame->seq = uart_recv_byte();
    frame->length = (uint16_t)uart_recv_byte();
    frame->length |= (uint16_t)uart_recv_byte() << 8;

    if (frame->length > UART_MAX_PAYLOAD) {
        return UART_STATUS_BAD_LENGTH;
    }

    for (idx = 0U; idx < frame->length; ++idx) {
        frame->payload[idx] = uart_recv_byte();
    }

    checksum = uart_recv_byte();
    if (checksum != frame_checksum(frame->cmd, frame->seq, frame->length, frame->payload)) {
        return UART_STATUS_BAD_CHECKSUM;
    }

    return UART_STATUS_OK;
}

static int coeff_validate_target(uint8_t ctrl, uint8_t bank, uint16_t index, uint16_t count) {
    if (ctrl >= SS_CTRL_COUNT || bank >= SS_BANK_COUNT) {
        return XST_FAILURE;
    }

    if (count == 0U || index >= SS_COEFFS_PER_BANK || (uint32_t)index + count > SS_COEFFS_PER_BANK) {
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

static void coeff_set_target(uint8_t ctrl, uint8_t bank, uint16_t index) {
    uint32_t target = ((uint32_t)(ctrl & SS_CTRL_FIELD_MASK))
                    | ((uint32_t)(bank & SS_BANK_FIELD_MASK) << 4)
                    | ((uint32_t)(index & SS_COEFF_INDEX_MASK) << 12);
    coeff_write_reg(COEFF_REG_TARGET, target);
}

static int coeff_write_word(uint8_t ctrl, uint8_t bank, uint16_t index, int32_t coeff_word) {
    if (coeff_word < SS_COEFF_MIN || coeff_word > SS_COEFF_MAX) {
        return XST_FAILURE;
    }

    coeff_set_target(ctrl, bank, index);
    coeff_write_reg(COEFF_REG_WDATA, (uint32_t)coeff_word);
    coeff_write_reg(COEFF_REG_CONTROL, COEFF_CTRL_CMD_WRITE);
    return XST_SUCCESS;
}

static int coeff_read_word(uint8_t ctrl, uint8_t bank, uint16_t index, int32_t *coeff_word) {
    uint32_t tries;

    coeff_set_target(ctrl, bank, index);
    coeff_write_reg(COEFF_REG_CONTROL, COEFF_CTRL_CMD_READ);

    for (tries = 0U; tries < 1000000U; ++tries) {
        if ((coeff_read_reg(COEFF_REG_STATUS) & COEFF_STATUS_READBACK_VLD) != 0U) {
            *coeff_word = (int32_t)coeff_read_reg(COEFF_REG_RDATA);
            return XST_SUCCESS;
        }
    }

    return XST_FAILURE;
}

static uint32_t coeff_shadow_pending_read(void) {
    return coeff_read_reg(COEFF_REG_SHADOW_PENDING);
}

static uint8_t handle_write_block(const uart_frame_t *frame, uint8_t *response, uint16_t *response_len) {
    uint8_t ctrl;
    uint8_t bank;
    uint16_t index;
    uint16_t count;
    uint16_t coeff_idx;

    if (frame->length < 6U) {
        return UART_STATUS_BAD_LENGTH;
    }

    ctrl = frame->payload[0];
    bank = frame->payload[1];
    index = read_le16(&frame->payload[2]);
    count = read_le16(&frame->payload[4]);

    if (frame->length != (uint16_t)(6U + (count * 4U))) {
        return UART_STATUS_BAD_LENGTH;
    }

    if (coeff_validate_target(ctrl, bank, index, count) != XST_SUCCESS) {
        return UART_STATUS_BAD_ARGS;
    }

    for (coeff_idx = 0U; coeff_idx < count; ++coeff_idx) {
        int32_t coeff_word = read_le32s(&frame->payload[6U + (coeff_idx * 4U)]);
        if (coeff_write_word(ctrl, bank, (uint16_t)(index + coeff_idx), coeff_word) != XST_SUCCESS) {
            return UART_STATUS_RANGE;
        }
    }

    response[0] = UART_STATUS_OK;
    write_le16(&response[1], count);
    *response_len = 3U;
    return UART_STATUS_OK;
}

static uint8_t handle_read_block(const uart_frame_t *frame, uint8_t *response, uint16_t *response_len) {
    uint8_t ctrl;
    uint8_t bank;
    uint16_t index;
    uint16_t count;
    uint16_t coeff_idx;

    if (frame->length != 6U) {
        return UART_STATUS_BAD_LENGTH;
    }

    ctrl = frame->payload[0];
    bank = frame->payload[1];
    index = read_le16(&frame->payload[2]);
    count = read_le16(&frame->payload[4]);

    if (coeff_validate_target(ctrl, bank, index, count) != XST_SUCCESS) {
        return UART_STATUS_BAD_ARGS;
    }

    response[0] = UART_STATUS_OK;
    write_le16(&response[1], count);

    for (coeff_idx = 0U; coeff_idx < count; ++coeff_idx) {
        int32_t coeff_word;
        if (coeff_read_word(ctrl, bank, (uint16_t)(index + coeff_idx), &coeff_word) != XST_SUCCESS) {
            return UART_STATUS_HW_TIMEOUT;
        }
        write_le32(&response[3U + (coeff_idx * 4U)], (uint32_t)coeff_word);
    }

    *response_len = (uint16_t)(3U + (count * 4U));
    return UART_STATUS_OK;
}

static uint8_t handle_get_status(uint8_t *response, uint16_t *response_len) {
    uint32_t shadow_pending  = coeff_shadow_pending_read();
    uint32_t live_active     = coeff_read_reg(COEFF_REG_LIVE_ACTIVE);
    uint32_t live_pending    = coeff_read_reg(COEFF_REG_LIVE_PENDING);
    uint32_t status          = coeff_read_reg(COEFF_REG_STATUS);

    response[0] = UART_STATUS_OK;
    write_le32(&response[1],  shadow_pending & 0x00FFFFFFU);
    write_le32(&response[5],  live_active    & 0x00FFFFFFU);
    write_le32(&response[9],  live_pending   & 0x00FFFFFFU);
    response[13] = (uint8_t)(status & 0xFFU);
    *response_len = 14U;
    return UART_STATUS_OK;
}

/* ----------------------------------------------------------------------- *
 *  Real-time feature acquisition for the supervisor.
 *
 *  The PL exposes per-band smoothed energies (32-bit, >= 0):
 *    E_innov[b] : observer innovation |y - y_hat|
 *    E_band[b]  : crossover band signal magnitude
 *    E_modal[b] : observer modal energy  sum|x_hat|
 *
 *  These raw energies are normalized to Q22 [0,1] and mapped onto the
 *  supervisor feature struct. The shift constants below are calibration
 *  tunables (recompile to retune):
 *    - shift maps a raw energy to ~1.0 at the level that should read "full".
 *  Position scoring uses band-energy template signatures per measured
 *  microphone position P0..P4.
 * ----------------------------------------------------------------------- */
#define Q22_FULL                4194304            /* 1.0 in sfix24_En22 */
#define FEAT_INNOV_SHIFT        1U                 /* 24-bit mag -> [0,1] */
#define FEAT_BAND_SHIFT         1U
#define FEAT_MODAL_SHIFT        6U                 /* sum of 30 states     */

/* Band-energy templates per position (normalized Q22). Lower match distance
 * wins. EDIT to the measured per-position band-energy signatures; zeros make
 * every position score equally (supervisor then holds P0). */
static const s32 g_pos_template[NUM_POSITIONS][NUM_BANDS] = {
    /*           low     low-mid  high-mid  high  */
    /* P0 */ {     0,        0,        0,       0 },
    /* P1 */ {     0,        0,        0,       0 },
    /* P2 */ {     0,        0,        0,       0 },
    /* P3 */ {     0,        0,        0,       0 },
    /* P4 */ {     0,        0,        0,       0 },
};

static inline s32 feat_norm(uint32_t raw, uint32_t shift) {
    uint32_t v = raw >> shift;
    return (v > (uint32_t)Q22_FULL) ? Q22_FULL : (s32)v;
}

static inline s32 feat_abs(s32 v) {
    return (v < 0) ? -v : v;
}

/* Read the PL feature registers and fill the supervisor feature struct. */
static void populate_features(sup_features_t *f) {
    s32 band_norm[NUM_BANDS];

    if (f == 0) return;

    for (int b = 0; b < NUM_BANDS; b++) {
        uint32_t e_innov = coeff_read_reg(COEFF_REG_FEAT_INNOV_BASE + 4U * (uint32_t)b);
        uint32_t e_band  = coeff_read_reg(COEFF_REG_FEAT_BAND_BASE  + 4U * (uint32_t)b);
        uint32_t e_modal = coeff_read_reg(COEFF_REG_FEAT_MODAL_BASE + 4U * (uint32_t)b);

        s32 innov_n = feat_norm(e_innov, FEAT_INNOV_SHIFT);
        band_norm[b]  = feat_norm(e_band,  FEAT_BAND_SHIFT);

        /* Innovation consistency: high when the residual is small (eq. 5.7). */
        f->c_r[b] = Q22_FULL - innov_n;
        /* Lead-lag and modal-energy consistency are not yet measured in PL;
         * assume nominal-consistent so they do not drag the gate down. */
        f->c_l[b] = Q22_FULL;
        f->c_e[b] = Q22_FULL;

        f->risk_modal[b]  = feat_norm(e_modal, FEAT_MODAL_SHIFT);
        f->risk_energy[b] = band_norm[b];
        /* Loop-margin term comes from the offline per-bank pole-risk table
         * inside the supervisor; leave 0 here. */
        f->risk_margin[b] = 0;
    }

    /* Position template matching: J_p = sum_b |E_band[b] - template[p][b]|. */
    for (int p = 0; p < NUM_POSITIONS; p++) {
        u32 score = 0;
        for (int b = 0; b < NUM_BANDS; b++) {
            score += (u32)feat_abs(band_norm[b] - g_pos_template[p][b]);
        }
        f->pos_score[p] = score;
    }
}

#if POC_SINGLE_BAND
/* PoC test hook: set the single-band intervention factor live.
 * Payload: 1 byte in [0,255]. 0 -> alpha=0, 255 -> alpha=1.0 (Q22), linear in
 * between. Response[1] echoes the quantized 0..255 level currently applied. */
static uint8_t handle_poc_set_alpha(const uart_frame_t *frame, uint8_t *response, uint16_t *response_len) {
    if (frame->length != 1U) {
        return UART_STATUS_BAD_LENGTH;
    }
    {
        uint32_t level = (uint32_t)frame->payload[0];
        uint32_t alpha = (level * (uint32_t)Q22_FULL + 127U) / 255U;
        if (alpha > (uint32_t)Q22_FULL) {
            alpha = (uint32_t)Q22_FULL;
        }
        g_poc_alpha = (s32)alpha;
    }
    response[0] = UART_STATUS_OK;
    response[1] = frame->payload[0];
    *response_len = 2U;
    return UART_STATUS_OK;
}
#endif

static void uart_command_loop(void) {
    uart_frame_t frame;
    uint8_t response[UART_MAX_PAYLOAD];

    while (1) {
        int rx_status;
        uint16_t response_len = 0U;
        uint8_t cmd_status = UART_STATUS_OK;
        uint8_t response_cmd;

        // Run supervisor periodically when idle, fed by the PL feature
        // registers (innovation, band and modal energy per band).
        while (!uart_has_data()) {
#if POC_SINGLE_BAND
            /* PoC bring-up: bypass risk/position/switch logic. Hold the gate
             * open for the band under test and drive alpha from g_poc_alpha;
             * keep every other band inactive. */
            for (int b = 0; b < NUM_BANDS; b++) {
                s32 a = (b == POC_BAND) ? g_poc_alpha : 0;
                supervisor_force_band(b, (s32)Q22_FULL, a);
            }
#else
            sup_features_t sup_feat;
            populate_features(&sup_feat);
            supervisor_update(&sup_feat);
#endif
            usleep(100); 
        }

        rx_status = uart_recv_frame(&frame);
        if (rx_status != UART_STATUS_OK) {
            response[0] = (uint8_t)rx_status;
            uart_send_frame(UART_ERROR_CMD, frame.seq, response, 1U);
            continue;
        }

        response_cmd = (uint8_t)(frame.cmd | UART_RESP_BIT);

        switch (frame.cmd) {
            case UART_CMD_WRITE_BLOCK:
                cmd_status = handle_write_block(&frame, response, &response_len);
                break;

            case UART_CMD_READ_BLOCK:
                cmd_status = handle_read_block(&frame, response, &response_len);
                break;

            case UART_CMD_GET_STATUS:
                if (frame.length != 0U) {
                    cmd_status = UART_STATUS_BAD_LENGTH;
                } else {
                    cmd_status = handle_get_status(response, &response_len);
                }
                break;

#if POC_SINGLE_BAND
            case UART_CMD_POC_SET_ALPHA:
                cmd_status = handle_poc_set_alpha(&frame, response, &response_len);
                break;
#endif

            default:
                cmd_status = UART_STATUS_BAD_COMMAND;
                break;
        }

        if (cmd_status != UART_STATUS_OK) {
            response[0] = cmd_status;
            response_len = 1U;
        }

        uart_send_frame(response_cmd, frame.seq, response, response_len);
    }
}

int main() {
    
    init_platform();
    xil_printf("\n--- Thesis Audio Pipeline Starting ---\n");

    XIic_Config *iic_cfg = XIic_LookupConfig(IIC_BASEADDR);
    XIic_CfgInitialize(&iic, iic_cfg, iic_cfg->BaseAddress);

    codec_init_sequence();

    xil_printf("Custom PL I2S path selected; no Xilinx I2S registers to configure.\n");
    xil_printf("Coefficient control base: 0x%08X\n", (uint32_t)COEFF_CTRL_BASEADDR);
    xil_printf("UART coefficient protocol ready.\n");

    supervisor_init(COEFF_CTRL_BASEADDR);

    uart_command_loop();
    
    cleanup_platform();
    return 0;
}