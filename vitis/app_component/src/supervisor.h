#ifndef SUPERVISOR_H
#define SUPERVISOR_H

#include "xil_types.h"

/*
 * Supervisor for the position-consistent controller bank.
 *
 * Implements the online supervisory layer described in the thesis,
 * Chapter 5.8 ("Supervisor logic"):
 *   - gated-observer confidence signal  g[k]   (eq. 5.7)
 *   - bandwise feedback-risk indicator  R_b[k] (eq. 5.62)
 *   - risk -> preset mapping            m_b    (eq. 5.64, Table 5.3)
 *   - position-bank selection           p*     (eq. 5.60-5.61)
 *   - constrained fade-through-zero switching  (eq. 5.65-5.66)
 *
 * The supervisor only SELECTS among prevalidated controller banks and drives
 * the observer gate g and intervention factor alpha. It never redesigns the
 * controller gains online.
 *
 * NOTE ON INPUTS:
 *   The real-time feature extraction (modal energy, ringdown, loop margin,
 *   observer-consistency indicators, position template matching) is not yet
 *   implemented in the PL. Until it exists, supervisor_update() is fed a
 *   sup_features_t whose fields are placeholders (see supervisor_default_features).
 *   With all-zero features the supervisor keeps every band inactive (alpha = 0),
 *   which is the safe state. Wire the struct fields to the HW feature registers
 *   when the extraction blocks are added (search for "TODO: from HW").
 */

#define NUM_BANDS         4   /* one state-space controller per frequency band */
#define NUM_POSITIONS     5   /* P0..P4 measured microphone positions          */
#define NUM_PRESET_LEVELS 4   /* none / mild / strong / combined (Table 5.3)   */

/*
 * Feature interface consumed by the supervisor every update.
 * All consistency / risk fields are normalized to [0,1] in Q22 (sfix24_En22),
 * i.e. 0 .. 4194304. Position scores J are unsigned distances (lower = better).
 */
typedef struct {
    /* Gate consistency indicators, eq. (5.7), per band, Q22 in [0,1] */
    s32 c_l[NUM_BANDS];   /* temporal / lead-lag consistency          (TODO: from HW) */
    s32 c_e[NUM_BANDS];   /* monitor-related modal-energy consistency (TODO: from HW) */
    s32 c_r[NUM_BANDS];   /* innovation / residual consistency        (TODO: from HW) */

    /* Bandwise feedback-risk indicators, eq. (5.62), per band, Q22 in [0,1] */
    s32 risk_modal[NUM_BANDS];   /* M_b normalized modal energy       (TODO: from HW) */
    s32 risk_energy[NUM_BANDS];  /* E_b band energy / ringdown        (TODO: from HW) */
    s32 risk_margin[NUM_BANDS];  /* S_b loop-margin / sensitivity     (TODO: from HW) */

    /* Position template-match scores, eq. (5.60); lower = closer match */
    u32 pos_score[NUM_POSITIONS]; /* J_p                              (TODO: from HW) */
} sup_features_t;

/*
 * Initialize the supervisor.
 *   axi_base : base address of the ss_coeff_axi_ctrl peripheral
 *              (e.g. XPAR_COEFF_CTRL_BASEADDR).
 * Sets all gates to 1.0, all intervention factors to 0.0, selects position P0
 * and commits the P0 / low-risk controller banks.
 */
void supervisor_init(u32 axi_base);

/* Fill f with safe default features (all zero -> no intervention). */
void supervisor_default_features(sup_features_t *f);

/*
 * Run one supervisor step:
 *   - update observer gate g[b]
 *   - evaluate risk R_b and select presets
 *   - run the position-bank selection + fade-through-zero state machine
 *   - push g, alpha and any committed bank changes to the hardware.
 * Call periodically (e.g. from the idle loop).
 */
void supervisor_update(const sup_features_t *features);

/*
 * PoC / bring-up override: drive one band's observer gate and intervention
 * factor directly to the hardware, bypassing ALL risk/position/switching
 * logic. Intended for single-band manual A/B testing (alpha = 0 vs full).
 *   band      : controller slot 0..NUM_BANDS-1
 *   g_q22     : observer gate   in Q22 [0,1] (use Q22 1.0 = 4194304 to open)
 *   alpha_q22 : intervention    in Q22 [0,1] (0 = off, 4194304 = full)
 * Values are saturated to [0,1]. Does not run the supervisor FSM.
 */
void supervisor_force_band(int band, s32 g_q22, s32 alpha_q22);

#endif /* SUPERVISOR_H */