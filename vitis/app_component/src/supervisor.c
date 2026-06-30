/*
 * supervisor.c - online supervisory layer for the position-consistent
 * controller bank. See supervisor.h and thesis Chapter 5.8.
 *
 * Responsibilities:
 *   1. Observer gate  g[b]   = sat01( w_l*c_l + w_e*c_e + w_r*c_r )   (eq. 5.7-5.8)
 *   2. Feedback risk  R_b    = sat01( a_m*M_b + a_e*E_b + a_s*S_b )   (eq. 5.62-5.63)
 *   3. Preset map     m_b    = f_preset(R_b)                          (eq. 5.64, Table 5.3)
 *   4. Position pick  p*     = argmin_p J_p  (+ hysteresis + dwell)   (eq. 5.60-5.61)
 *   5. Fade-through-zero switching of controller banks                (eq. 5.65-5.66)
 *
 * All gate / risk arithmetic is in Q22 (sfix24_En22). Multiplying two Q22
 * values needs a >>22 renormalization, done with 64-bit intermediates.
 */

#include "supervisor.h"
#include "xil_io.h"

/* ----------------------------------------------------------------------- *
 *  Fixed-point format
 * ----------------------------------------------------------------------- */
#define Q22_ONE        4194304          /* 1.0 in sfix24_En22 */
#define Q22_FRAC_BITS  22

/* ----------------------------------------------------------------------- *
 *  AXI register map of ss_coeff_axi_ctrl (offsets from the peripheral base)
 * ----------------------------------------------------------------------- */
#define SUP_REG_CONTROL        0x00U
#define SUP_REG_SHADOW_PENDING 0x10U
#define SUP_REG_G_BASE         0x24U   /* g[b]     = 0x24 + 8*b */
#define SUP_REG_ALPHA_BASE     0x28U   /* alpha[b] = 0x28 + 8*b */

#define SUP_CMD_COMMIT         0x00000004U
#define SUP_COMMIT_SHIFT       8U

#define SS_BANK_SEL_W          3U      /* 8 banks per controller */
#define SS_BANK_COUNT          8U

/* ----------------------------------------------------------------------- *
 *  Tunable supervisor constants (compile-time; recompile to change).
 *
 *  Gate weights (eq. 5.8) should sum to ~1.0. Risk weights (eq. 5.63) should
 *  sum to ~1.0 so that R_b stays in [0,1]. Thresholds map R_b to a preset
 *  level per Table 5.3.
 * ----------------------------------------------------------------------- */
#define W_L   (Q22_ONE / 3)             /* gate weight: lead-lag consistency */
#define W_E   (Q22_ONE / 3)             /* gate weight: modal-energy consist. */
#define W_R   (Q22_ONE / 3)             /* gate weight: residual consistency  */

#define A_M   (Q22_ONE / 3)             /* risk weight: modal energy M_b      */
#define A_E   (Q22_ONE / 3)             /* risk weight: band energy  E_b      */
#define A_S   (Q22_ONE / 3)             /* risk weight: loop margin  S_b      */

/* Risk -> preset level thresholds (Q22). R_b < TH1 -> level 0 (no action). */
#define RISK_TH1  (Q22_ONE / 4)         /* 0.25 -> level 1 (mild)     */
#define RISK_TH2  (Q22_ONE / 2)         /* 0.50 -> level 2 (strong)   */
#define RISK_TH3  ((3 * Q22_ONE) / 4)   /* 0.75 -> level 3 (combined) */

/* Constrained switching (eq. 5.66): max per-step change of alpha. */
#define ALPHA_MAX_JUMP   (Q22_ONE / 10) /* 0.1 per update */

/* Position selection hysteresis + dwell (eq. 5.61). */
#define POS_HYST_MARGIN  1024U          /* score units the new position must win by */
#define POS_DWELL_COUNT  8U             /* consecutive updates before a switch     */

/* Hold time (updates) at alpha=0 before committing a position bank set. */
#define POS_HOLD_COUNT   4U

/*
 * Physical controller-bank assignment.
 *   g_bank_map[position][preset_level] -> physical bank index (0..7) that
 *   holds the {A,B,C,D,L,K} coefficients for that (position, preset) for every
 *   band's controller.
 *
 *   The default below maps each position to a distinct bank and lets all preset
 *   levels of a position share that bank (only one preset uploaded per position).
 *   EDIT THIS TABLE to match the banks you actually upload with
 *   tools/ss_coeff_uploader.py. Values are clamped to [0, SS_BANK_COUNT-1].
 */
static const u8 g_bank_map[NUM_POSITIONS][NUM_PRESET_LEVELS] = {
    /*            none mild strong combined */
    /* P0 */    {  0,   0,    0,      0 },
    /* P1 */    {  1,   1,    1,      1 },
    /* P2 */    {  2,   2,    2,      2 },
    /* P3 */    {  3,   3,    3,      3 },
    /* P4 */    {  4,   4,    4,      4 },
};

/*
 * Offline per-bank pole-risk constants (S_b, loop-margin term of eq. 5.63).
 * The modal pole-risk (5.3.3) is a design-time property of each bank's A-matrix
 * and the loop-gain margin (5.3.4) comes from offline testing, so they are not
 * computed in the PL. Fill this table (Q22 in [0,1]) from the offline analysis
 * for the banks you upload. Zeros disable the margin contribution to the risk.
 */
static const s32 g_pole_risk[SS_BANK_COUNT] = {
    0, 0, 0, 0, 0, 0, 0, 0
};


/* ----------------------------------------------------------------------- *
 *  Internal state
 * ----------------------------------------------------------------------- */
typedef enum {
    SUP_RUN = 0,        /* normal operation */
    SUP_FADE_DOWN,      /* fading all bands to zero for a position switch */
    SUP_HOLD            /* held at zero, waiting before committing */
} sup_state_t;

static u32 s_axi_base = 0;

static s32 s_gate[NUM_BANDS];           /* g[b], Q22 */
static s32 s_alpha_cur[NUM_BANDS];      /* current alpha[b], Q22 */
static s32 s_alpha_tgt[NUM_BANDS];      /* target  alpha[b], Q22 */
static u8  s_preset_level[NUM_BANDS];   /* selected preset per band */
static u8  s_committed_bank[NUM_BANDS]; /* physical bank currently live per band */
static u8  s_bank_change[NUM_BANDS];    /* per-band bank-change pending flag */

static u8  s_position;                  /* current active position p*        */
static u8  s_pos_candidate;             /* best position last seen           */
static u32 s_pos_candidate_count;       /* dwell counter for the candidate   */

static sup_state_t s_state;
static u8  s_pos_pending;               /* position to switch to once at zero */
static u32 s_hold_count;                /* hold timer in SUP_HOLD             */

static u32 s_shadow_pending;            /* SW mirror of REG_SHADOW_PENDING    */

/* ----------------------------------------------------------------------- *
 *  Helpers
 * ----------------------------------------------------------------------- */
static inline void reg_write(u32 offset, u32 value) {
    Xil_Out32(s_axi_base + offset, value);
}

/* Saturate to [0, Q22_ONE]. */
static inline s32 sat01(s32 v) {
    if (v < 0)       return 0;
    if (v > Q22_ONE) return Q22_ONE;
    return v;
}

/* Q22 multiply: (a * b) >> 22, with a,b assumed in [0,1] Q22. */
static inline s32 q22_mul(s32 a, s32 b) {
    s64 p = (s64)a * (s64)b;
    return (s32)(p >> Q22_FRAC_BITS);
}

static inline u8 clamp_bank(u8 bank) {
    return (bank >= SS_BANK_COUNT) ? (u8)(SS_BANK_COUNT - 1) : bank;
}

/* Map a risk value (Q22) to a preset level per Table 5.3. */
static u8 preset_for_risk(s32 risk) {
    if (risk >= RISK_TH3) return 3;     /* combined */
    if (risk >= RISK_TH2) return 2;     /* strong   */
    if (risk >= RISK_TH1) return 1;     /* mild     */
    return 0;                           /* none     */
}

/* Desired physical bank for a band given current position and its preset. */
static inline u8 desired_bank(int band) {
    return clamp_bank(g_bank_map[s_position][s_preset_level[band]]);
}

/* Write g[b] and alpha[b] to hardware. */
static void push_gate_alpha(void) {
    for (int b = 0; b < NUM_BANDS; b++) {
        reg_write(SUP_REG_G_BASE     + (u32)(8 * b), (u32)s_gate[b]);
        reg_write(SUP_REG_ALPHA_BASE + (u32)(8 * b), (u32)s_alpha_cur[b]);
    }
}

/* Commit a new physical bank for one controller (glitchless, HW double-buffered). */
static void commit_bank(int band, u8 bank) {
    u32 shift = (u32)band * SS_BANK_SEL_W;
    u32 field = (u32)(bank & ((1U << SS_BANK_SEL_W) - 1U));
    s_shadow_pending &= ~(((1U << SS_BANK_SEL_W) - 1U) << shift);
    s_shadow_pending |= field << shift;
    reg_write(SUP_REG_SHADOW_PENDING, s_shadow_pending);
    reg_write(SUP_REG_CONTROL, SUP_CMD_COMMIT | (1U << (SUP_COMMIT_SHIFT + band)));
    s_committed_bank[band] = bank;
}

/* Commit all four controllers to the banks of the current position. */
static void commit_all_banks(void) {
    u32 mask = 0;
    for (int b = 0; b < NUM_BANDS; b++) {
        u8 bank = desired_bank(b);
        u32 shift = (u32)b * SS_BANK_SEL_W;
        s_shadow_pending &= ~(((1U << SS_BANK_SEL_W) - 1U) << shift);
        s_shadow_pending |= (u32)(bank & ((1U << SS_BANK_SEL_W) - 1U)) << shift;
        s_committed_bank[b] = bank;
        s_bank_change[b] = 0;
        mask |= 1U << b;
    }
    reg_write(SUP_REG_SHADOW_PENDING, s_shadow_pending);
    reg_write(SUP_REG_CONTROL, SUP_CMD_COMMIT | (mask << SUP_COMMIT_SHIFT));
}

/* Rate-limited move of current alpha toward its target (eq. 5.66). */
static void slew_alpha(void) {
    for (int b = 0; b < NUM_BANDS; b++) {
        s32 diff = s_alpha_tgt[b] - s_alpha_cur[b];
        if (diff > ALPHA_MAX_JUMP)        s_alpha_cur[b] += ALPHA_MAX_JUMP;
        else if (diff < -ALPHA_MAX_JUMP)  s_alpha_cur[b] -= ALPHA_MAX_JUMP;
        else                              s_alpha_cur[b]  = s_alpha_tgt[b];
        s_alpha_cur[b] = sat01(s_alpha_cur[b]);
    }
}

static int all_alpha_zero(void) {
    for (int b = 0; b < NUM_BANDS; b++) {
        if (s_alpha_cur[b] != 0) return 0;
    }
    return 1;
}

/* ----------------------------------------------------------------------- *
 *  Public API
 * ----------------------------------------------------------------------- */
void supervisor_default_features(sup_features_t *f) {
    if (f == 0) return;
    for (int b = 0; b < NUM_BANDS; b++) {
        f->c_l[b] = 0;  f->c_e[b] = 0;  f->c_r[b] = 0;
        f->risk_modal[b] = 0; f->risk_energy[b] = 0; f->risk_margin[b] = 0;
    }
    for (int p = 0; p < NUM_POSITIONS; p++) {
        f->pos_score[p] = 0;
    }
}

void supervisor_init(u32 axi_base) {
    s_axi_base = axi_base;

    for (int b = 0; b < NUM_BANDS; b++) {
        s_gate[b]          = Q22_ONE;   /* gate open by default (eq. 5.7) */
        s_alpha_cur[b]     = 0;         /* no intervention until risk rises */
        s_alpha_tgt[b]     = 0;
        s_preset_level[b]  = 0;
        s_bank_change[b]   = 0;
    }

    s_position            = 0;          /* start at P0 */
    s_pos_candidate       = 0;
    s_pos_candidate_count = 0;
    s_state               = SUP_RUN;
    s_pos_pending         = 0;
    s_hold_count          = 0;
    s_shadow_pending      = 0;

    commit_all_banks();                 /* select P0 / low-risk banks */
    push_gate_alpha();                  /* g=1.0, alpha=0.0 */
}

void supervisor_update(const sup_features_t *features) {
    if (features == 0 || s_axi_base == 0) return;

    /* ---- 1. Observer gate g[b] (eq. 5.7-5.8) ------------------------- */
    for (int b = 0; b < NUM_BANDS; b++) {
        s32 g = q22_mul(W_L, features->c_l[b])
              + q22_mul(W_E, features->c_e[b])
              + q22_mul(W_R, features->c_r[b]);
        s_gate[b] = sat01(g);
    }

    /* ---- 2/3. Risk R_b and preset selection (eq. 5.62-5.64) ---------- */
    for (int b = 0; b < NUM_BANDS; b++) {
        /* Loop-margin term: use the supplied feature if present, else fall
         * back to the offline pole-risk constant of the band's live bank. */
        s32 margin = features->risk_margin[b];
        if (margin == 0) {
            margin = g_pole_risk[clamp_bank(s_committed_bank[b])];
        }
        s32 r = q22_mul(A_M, features->risk_modal[b])
              + q22_mul(A_E, features->risk_energy[b])
              + q22_mul(A_S, margin);
        r = sat01(r);
        s_preset_level[b] = preset_for_risk(r);
    }

    /* ---- 4. Position selection with hysteresis + dwell (eq. 5.60-61) - */
    {
        u8  best = 0;
        u32 best_score = features->pos_score[0];
        for (int p = 1; p < NUM_POSITIONS; p++) {
            if (features->pos_score[p] < best_score) {
                best_score = features->pos_score[p];
                best = (u8)p;
            }
        }

        if (best == s_position) {
            s_pos_candidate       = s_position;
            s_pos_candidate_count = 0;
        } else {
            u32 cur_score = features->pos_score[s_position];
            /* require a clear margin over the current position (eq. 5.61) */
            int wins = (cur_score >= best_score) &&
                       (cur_score - best_score >= POS_HYST_MARGIN);
            if (wins && best == s_pos_candidate) {
                s_pos_candidate_count++;
            } else {
                s_pos_candidate       = best;
                s_pos_candidate_count = wins ? 1 : 0;
            }

            if (s_state == SUP_RUN && s_pos_candidate_count >= POS_DWELL_COUNT) {
                /* trigger constrained fade-through-zero switch (eq. 5.65) */
                s_pos_pending = best;
                s_state       = SUP_FADE_DOWN;
            }
        }
    }

    /* ---- 5. Fade-through-zero switching FSM (eq. 5.65) --------------- */
    switch (s_state) {
    case SUP_FADE_DOWN:
        /* force every band to zero; position consistency requires all banks
         * to switch together, so override risk-driven targets here. */
        for (int b = 0; b < NUM_BANDS; b++) s_alpha_tgt[b] = 0;
        if (all_alpha_zero()) {
            s_position   = s_pos_pending;
            s_hold_count = 0;
            s_state      = SUP_HOLD;
        }
        break;

    case SUP_HOLD:
        for (int b = 0; b < NUM_BANDS; b++) s_alpha_tgt[b] = 0;
        if (++s_hold_count >= POS_HOLD_COUNT) {
            commit_all_banks();         /* swap in the new position's banks */
            s_pos_candidate       = s_position;
            s_pos_candidate_count = 0;
            s_state               = SUP_RUN;
        }
        break;

    case SUP_RUN:
    default:
        /* normal targets from risk; handle per-band preset bank changes by
         * fading the affected band through zero before committing it. */
        for (int b = 0; b < NUM_BANDS; b++) {
            u8 want = desired_bank(b);
            if (want != s_committed_bank[b]) s_bank_change[b] = 1;

            if (s_bank_change[b]) {
                s_alpha_tgt[b] = 0;                 /* fade this band out */
                if (s_alpha_cur[b] == 0) {
                    commit_bank(b, want);           /* glitchless swap at zero */
                    s_bank_change[b] = 0;
                }
            } else {
                s_alpha_tgt[b] = (s_preset_level[b] == 0) ? 0 : Q22_ONE;
            }
        }
        break;
    }

    /* ---- 6. Rate-limited slew + push to hardware (eq. 5.66) ---------- */
    slew_alpha();
    push_gate_alpha();
}

void supervisor_force_band(int band, s32 g_q22, s32 alpha_q22) {
    if (s_axi_base == 0) return;
    if (band < 0 || band >= NUM_BANDS) return;

    s_gate[band]      = sat01(g_q22);
    s_alpha_cur[band] = sat01(alpha_q22);
    s_alpha_tgt[band] = s_alpha_cur[band];

    reg_write(SUP_REG_G_BASE     + (u32)(8 * band), (u32)s_gate[band]);
    reg_write(SUP_REG_ALPHA_BASE + (u32)(8 * band), (u32)s_alpha_cur[band]);
}