#!/usr/bin/env python3
"""
tools/gen_coeffs.py

Generates audiodsp_pkg.vhd for the 8-band N=30 audio DSP system.

Crossover frequencies (Hz): 300, 1000, 2500, 4500, 8000, 11000, 13500
Bands:
  0: sub-bass   50-300 Hz
  1: bass       300-1000 Hz
  2: mid-bass   1000-2500 Hz
  3: upper-mid  2500-4500 Hz
  4: presence   4500-8000 Hz
  5: air-low    8000-11000 Hz
  6: air-mid    11000-13500 Hz
  7: air-high   13500-16000 Hz

LR4 crossover: 4th-order (2-section) Butterworth LP/HP at each crossover freq.
SS controllers (N=30) via cascade direct-form-II state-space from SOS:
  - Band 0: 30th-order LP Butterworth at 300 Hz
  - Bands 1-6: 15th-order BP Butterworth (=> 30 states) centered in each band
  - Band 7: 30th-order HP Butterworth at 13500 Hz

All coefficients quantised to Q22 (WL=24, FL=22).
A-matrix stored row-major to match ss_ctrl_fsm.vhd address indexing.

Usage:
  python tools/gen_coeffs.py [--out audiodsp_pkg.vhd] [--fs 48000] [--check-only]
"""

import argparse
import sys
from pathlib import Path
from datetime import datetime

import numpy as np
from scipy import signal

# ─── Design parameters ────────────────────────────────────────────────────────
FS_DEFAULT = 48_000
WL = 24          # word length (bits)
FL = 22          # fractional bits (Q22)
N_SS = 30        # SS controller order
Q_SCALE = 1 << FL  # 4_194_304
Q_MAX = (1 << (WL - 1)) - 1   #  8_388_607
Q_MIN = -(1 << (WL - 1))      # -8_388_608

XOVER_FREQS = [300, 1000, 2500]

# Outer band skirts. The thesis model bank is only validated over 50-4500 Hz, so
# band 0 is high-passed at 50 Hz and band 3 is low-passed at 4500 Hz. Without
# these the lowest/highest bands would extend to DC / Nyquist respectively.
BAND0_LOW_HZ = 50      # lower skirt of band 0 (thesis low band)
BAND3_HIGH_HZ = 4500   # upper skirt of band 3 (thesis validated-range limit)

# For each crossover frequency, emit LP and HP constant names in order
XOVER_PAIRS = [
    ("LP300_COEFFS", "HP300_COEFFS"),
    ("LP1000_COEFFS", "HP1000_COEFFS"),
    ("LP2500_COEFFS", "HP2500_COEFFS"),
]

BAND_LABELS = [
    "sub-bass (50-300 Hz)",
    "bass (300-1000 Hz)",
    "mid-bass (1000-2500 Hz)",
    "upper-mid (2500-4500 Hz)",
]

# Dummy PoC controller index (0..3). The selected band's K is emitted as K=C
# while all other bands keep K=0. Prefer band 1 or 2 for bring-up because band
# 0's very low cutoff can cause heavy Q22 clipping in the 30x30 A realization.
DUMMY_POC_BAND = 1


# ─── Filter design helpers ─────────────────────────────────────────────────────

def lr4_sos(fc_hz: float, btype: str, fs: float) -> np.ndarray:
    """2-section SOS for a 4th-order Linkwitz-Riley LP or HP at fc_hz."""
    nyq = fs / 2.0
    wn = fc_hz / nyq
    if wn <= 0.0 or wn >= 1.0:
        raise ValueError(f"Normalised frequency {wn:.4f} out of (0,1) range "
                         f"(fc={fc_hz} Hz, fs={fs} Hz)")
    sos = signal.butter(4, wn, btype=btype, output="sos")
    assert sos.shape[0] == 2, f"Expected 2 SOS sections, got {sos.shape[0]}"
    return sos


def design_ss_sos(band_idx: int, fs: float) -> np.ndarray:
    """
    Return SOS (nsec × 6) for SS controller of band `band_idx`.
    N_SS=30 states:
      Band 0: LP30 at 300 Hz
      Bands 1-2: BP15 at [low, high] (15th-order BP => 30 states after SOS→SS)
      Band 3: HP30 at 2500 Hz
    """
    nyq = fs / 2.0

    if band_idx == 0:
        # 30th-order LP at 300 Hz
        sos = signal.butter(N_SS, 300.0 / nyq, btype="low", output="sos")
    elif band_idx == 3:
        # 30th-order HP at 2500 Hz
        wn = 2500.0 / nyq
        if wn >= 1.0:
            raise ValueError(f"HP cutoff {2500} Hz >= Nyquist {nyq} Hz")
        sos = signal.butter(N_SS, wn, btype="high", output="sos")
    else:
        # 15th-order BP: band edges are xover freqs on each side
        edges = [XOVER_FREQS[band_idx - 1], XOVER_FREQS[band_idx]]
        wn = [f / nyq for f in edges]
        # butter(n, [w1,w2], 'bandpass') returns order=2n sections => 30 states
        sos = signal.butter(N_SS // 2, wn, btype="bandpass", output="sos")

    n_sec_expected = N_SS // 2  # 30th-order filter => 15 second-order sections
    assert sos.shape[0] == n_sec_expected, (
        f"Band {band_idx}: expected {n_sec_expected} SOS sections, got {sos.shape[0]}"
    )
    return sos


def cascade_sos_to_ss(sos: np.ndarray):
    """
    Build the combined (A, B, C, D) state-space for a cascade of biquad sections
    in direct-form-II (DF2) realisation.

    For section k with [b0,b1,b2,1,a1,a2]:
      State: [w[n-1], w[n-2]]
      A_k = [[-a1, -a2], [1, 0]]
      B_k = [[1], [0]]
      C_k = [[b1-b0*a1, b2-b0*a2]]
      D_k = b0

    Cascade interconnection: u_k = y_{k-1}.  Built incrementally so the final
    A is (2*nsec × 2*nsec) lower block-bidiagonal, B is (2*nsec,), C is (1, 2*nsec),
    D is scalar.

    The A matrix is returned in row-major order (row index changes slowest) to
    match ss_ctrl_fsm.vhd's memory addressing:
      address = SS_A_BASE + row * N + col
    """
    # Running combined system; start as identity (D=1, empty A/B/C)
    A = np.zeros((0, 0))
    B = np.zeros((0, 1))
    C = np.zeros((1, 0))
    D = np.array([[1.0]])

    for row_vec in sos:
        b0, b1, b2 = row_vec[0], row_vec[1], row_vec[2]
        # row_vec[3] == 1.0 (normalised denominator); a1,a2 with natural sign
        a1, a2 = row_vec[4], row_vec[5]

        Ak = np.array([[-a1, -a2], [1.0, 0.0]])
        Bk = np.array([[1.0], [0.0]])
        Ck = np.array([[b1 - b0 * a1, b2 - b0 * a2]])
        Dk = np.array([[b0]])

        n_prev = A.shape[0]
        A_new = np.block([
            [A,               np.zeros((n_prev, 2))],
            [Bk @ C,          Ak],
        ])
        B_new = np.vstack([B, Bk @ D])
        C_new = np.hstack([Dk @ C, Ck])
        D_new = Dk @ D

        A = A_new
        B = B_new
        C = C_new
        D = D_new

    return A, B.flatten(), C.flatten(), float(D[0, 0])


# ─── Quantisation ─────────────────────────────────────────────────────────────

def to_q22(val: float, name: str = "", warn_clip: bool = True) -> int:
    """Round a floating-point value to the nearest Q22 24-bit signed integer."""
    raw = int(round(val * Q_SCALE))
    if raw > Q_MAX or raw < Q_MIN:
        msg = f"Q22 overflow: {name} = {val:.6f} -> {raw} (range [{Q_MIN},{Q_MAX}])"
        if warn_clip:
            print(f"WARNING: {msg}", file=sys.stderr)
            raw = max(Q_MIN, min(Q_MAX, raw))
        else:
            raise OverflowError(msg)
    return raw


def check_stability(sos: np.ndarray, band_label: str) -> bool:
    """
    Check stability via per-section Jury criteria on each 2x2 diagonal block.

    For the cascade-SOS A matrix, eigenvalues equal the union of per-section
    pole pairs.  Computing eigenvalues of the full 30x30 combined matrix is
    numerically unreliable for high-order filters at very low frequencies
    (poles cluster near z=1), causing spurious |eig| > 1 results.  Per-section
    check on the 2x2 blocks (solved exactly) gives the correct answer.

    Jury criterion for z^2 + a1*z + a2: stable iff |a2| < 1 AND |a1| < 1 + a2.
    """
    max_mag = 0.0
    all_stable = True
    for k, row in enumerate(sos):
        a1, a2 = row[4], row[5]
        Ak = np.array([[-a1, -a2], [1.0, 0.0]])
        eigs = np.linalg.eigvals(Ak)
        mag = float(np.max(np.abs(eigs)))
        if mag >= 1.0:
            all_stable = False
            print(f"    section {k}: |eig|={mag:.6f} UNSTABLE (a1={a1:.6f} a2={a2:.6f})",
                  file=sys.stderr)
        max_mag = max(max_mag, mag)
    status = "stable" if all_stable else "UNSTABLE"
    print(f"  {band_label}: max section |eigenvalue| = {max_mag:.8f} ({status})")
    return all_stable


# ─── VHDL emission ────────────────────────────────────────────────────────────

def fmt_biquad(b0: int, b1: int, b2: int, a1: int, a2: int) -> str:
    return (f"    (to_signed({b0},{WL}), to_signed({b1},{WL}), "
            f"to_signed({b2},{WL}), to_signed({a1},{WL}), to_signed({a2},{WL}))")


def emit_lr4_constants(lines: list, sos: np.ndarray, name_lp: str, name_hp: str,
                        sos_hp: np.ndarray) -> None:
    """Append LP and HP LR4 constant declarations."""
    # LP
    lines.append(f"  -- {name_lp}: 2 biquad sections (LR4)")
    lines.append(f"  constant {name_lp} : sos_bank_t(0 to 1) := (")
    for k, row in enumerate(sos):
        sep = "," if k < len(sos) - 1 else ""
        b0 = to_q22(row[0], f"{name_lp}[{k}].b0")
        b1 = to_q22(row[1], f"{name_lp}[{k}].b1")
        b2 = to_q22(row[2], f"{name_lp}[{k}].b2")
        a1 = to_q22(row[4], f"{name_lp}[{k}].a1")
        a2 = to_q22(row[5], f"{name_lp}[{k}].a2")
        lines.append(fmt_biquad(b0, b1, b2, a1, a2) + sep)
    lines.append("  );")
    lines.append("")

    # HP
    lines.append(f"  -- {name_hp}: 2 biquad sections (LR4)")
    lines.append(f"  constant {name_hp} : sos_bank_t(0 to 1) := (")
    for k, row in enumerate(sos_hp):
        sep = "," if k < len(sos_hp) - 1 else ""
        b0 = to_q22(row[0], f"{name_hp}[{k}].b0")
        b1 = to_q22(row[1], f"{name_hp}[{k}].b1")
        b2 = to_q22(row[2], f"{name_hp}[{k}].b2")
        a1 = to_q22(row[4], f"{name_hp}[{k}].a1")
        a2 = to_q22(row[5], f"{name_hp}[{k}].a2")
        lines.append(fmt_biquad(b0, b1, b2, a1, a2) + sep)
    lines.append("  );")
    lines.append("")


def emit_single_lr4_constant(lines: list, sos: np.ndarray, name: str) -> None:
    """Append a single LR4 (2-section) constant declaration."""
    lines.append(f"  -- {name}: 2 biquad sections (LR4)")
    lines.append(f"  constant {name} : sos_bank_t(0 to 1) := (")
    for k, row in enumerate(sos):
        sep = "," if k < len(sos) - 1 else ""
        b0 = to_q22(row[0], f"{name}[{k}].b0")
        b1 = to_q22(row[1], f"{name}[{k}].b1")
        b2 = to_q22(row[2], f"{name}[{k}].b2")
        a1 = to_q22(row[4], f"{name}[{k}].a1")
        a2 = to_q22(row[5], f"{name}[{k}].a2")
        lines.append(fmt_biquad(b0, b1, b2, a1, a2) + sep)
    lines.append("  );")
    lines.append("")


def emit_ss_constant(lines: list, idx: int, A: np.ndarray,
                      B: np.ndarray, C: np.ndarray, D: float) -> None:
    """Append A, B, C, D, L, K VHDL constant declarations for one SS controller."""
    ctrl = idx + 1  # 1-based naming: A1..A8
    n = A.shape[0]
    assert n == N_SS
    assert B.shape == (N_SS,)
    assert C.shape == (N_SS,)

    # A matrix – row-major flat array (row * N + col)
    lines.append(f"  -- SS controller {ctrl} ({BAND_LABELS[idx]})")
    lines.append(f"  constant A{ctrl} : coeff_mat_t(0 to {n*n - 1}) := (")
    a_flat = A.flatten(order="C")  # row-major
    for i, v in enumerate(a_flat):
        qv = to_q22(v, f"A{ctrl}[{i}]")
        sep = "," if i < len(a_flat) - 1 else ""
        lines.append(f"    to_signed({qv},{WL}){sep}")
    lines.append("  );")
    lines.append("")

    # B vector
    lines.append(f"  constant B{ctrl} : coeff_vec_t(0 to {n - 1}) := (")
    for i, v in enumerate(B):
        qv = to_q22(v, f"B{ctrl}[{i}]")
        sep = "," if i < len(B) - 1 else ""
        lines.append(f"    to_signed({qv},{WL}){sep}")
    lines.append("  );")
    lines.append("")

    # C vector
    lines.append(f"  constant C{ctrl} : coeff_vec_t(0 to {n - 1}) := (")
    for i, v in enumerate(C):
        qv = to_q22(v, f"C{ctrl}[{i}]")
        sep = "," if i < len(C) - 1 else ""
        lines.append(f"    to_signed({qv},{WL}){sep}")
    lines.append("  );")
    lines.append("")

    # D scalar
    qd = to_q22(D, f"D{ctrl}")
    lines.append(f"  constant D{ctrl} : signed(WL-1 downto 0) := to_signed({qd},{WL});")
    lines.append("")

    # L vector (dummy 0 -- real observer gain comes with the validated export)
    lines.append(f"  constant L{ctrl} : coeff_vec_t(0 to {n - 1}) := (others => (others => '0'));")

    # K vector.
    # DUMMY single-band PoC: selected band uses K = C. Because D=0 for these
    # defaults, this gives u_c = -alpha*y_hat for that band. It exercises the
    # observer -> K -> sum datapath with a bounded, predictable effect; it is
    # NOT a designed feedback-suppression gain.
    if idx == DUMMY_POC_BAND:
        lines.append(f"  constant K{ctrl} : coeff_vec_t(0 to {n - 1}) := (")
        for i, v in enumerate(C):
            qv = to_q22(v, f"K{ctrl}[{i}]")
            sep = "," if i < len(C) - 1 else ""
            lines.append(f"    to_signed({qv},{WL}){sep}")
        lines.append("  );")
    else:
        lines.append(f"  constant K{ctrl} : coeff_vec_t(0 to {n - 1}) := (others => (others => '0'));")
    lines.append("")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="audiodsp_pkg.vhd",
                        help="Output VHDL file (default: audiodsp_pkg.vhd)")
    parser.add_argument("--fs", type=float, default=FS_DEFAULT,
                        help="Sample rate in Hz (default: 48000)")
    parser.add_argument("--check-only", action="store_true",
                        help="Design and validate without writing the output file")
    args = parser.parse_args()

    fs = args.fs
    print(f"gen_coeffs.py  fs={fs:.0f} Hz  N={N_SS}  WL={WL}  FL={FL}")
    print()

    # ── 1. Design LR4 crossover filters ───────────────────────────────────────
    print("Designing LR4 crossover filters...")
    xover_sos_pairs = []
    for fc in XOVER_FREQS:
        sos_lp = lr4_sos(fc, "low",  fs)
        sos_hp = lr4_sos(fc, "high", fs)
        xover_sos_pairs.append((sos_lp, sos_hp))
        print(f"  LR4 @ {fc:6d} Hz: LP a1={sos_lp[0,4]:.6f} a2={sos_lp[0,5]:.6f}")

    # Outer band skirts (band 0 high-pass at 50 Hz, band 3 low-pass at 4500 Hz)
    sos_hp50 = lr4_sos(BAND0_LOW_HZ, "high", fs)
    sos_lp4500 = lr4_sos(BAND3_HIGH_HZ, "low", fs)
    print(f"  LR4 @ {BAND0_LOW_HZ:6d} Hz: HP skirt for band 0 lower edge")
    print(f"  LR4 @ {BAND3_HIGH_HZ:6d} Hz: LP skirt for band 3 upper edge")
    print()

    # ── 2. Design SS controllers ───────────────────────────────────────────────
    print("Designing SS controllers (N=30)...")
    ss_list = []
    all_stable = True
    for band_idx in range(4):
        sos = design_ss_sos(band_idx, fs)
        A, B, C, D = cascade_sos_to_ss(sos)
        stable = check_stability(sos, BAND_LABELS[band_idx])
        if not stable:
            all_stable = False
        ss_list.append((A, B, C, D))

    print()
    if not all_stable:
        print("ERROR: One or more SS controllers are unstable!", file=sys.stderr)
        return 1

    if args.check_only:
        print("--check-only: skipping file write.")
        return 0

    # ── 3. Build VHDL ─────────────────────────────────────────────────────────
    lines = []
    lines.append(f"-- audiodsp_pkg.vhd  (AUTO-GENERATED by tools/gen_coeffs.py -- DO NOT EDIT)")
    lines.append(f"-- Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append(f"-- fs={fs:.0f} Hz  N_SS={N_SS}  WL={WL}  FL={FL}")
    lines.append(f"-- Bands: " + ", ".join(BAND_LABELS))
    lines.append("library ieee;")
    lines.append("use ieee.std_logic_1164.all;")
    lines.append("use ieee.numeric_std.all;")
    lines.append("")
    lines.append("package audiodsp_pkg is")
    lines.append("")
    lines.append(f"  constant WL : integer := {WL};")
    lines.append(f"  constant FL : integer := {FL};")
    lines.append(f"  constant N  : integer := {N_SS};  -- SS controller order")
    lines.append("")
    lines.append("  type coeff_vec_t  is array (natural range <>) of signed(WL-1 downto 0);")
    lines.append("  type coeff_mat_t  is array (natural range <>) of signed(WL-1 downto 0);")
    lines.append("  -- biquad: 5 coefficients per section [b0 b1 b2 a1 a2], no a0 (always 1)")
    lines.append("  type biquad_coeff_t is array (0 to 4) of signed(WL-1 downto 0);")
    lines.append("  type sos_bank_t     is array (natural range <>) of biquad_coeff_t;")
    lines.append("")

    # LR4 crossover constants
    for (sos_lp, sos_hp), (name_lp, name_hp) in zip(xover_sos_pairs, XOVER_PAIRS):
        emit_lr4_constants(lines, sos_lp, name_lp, name_hp, sos_hp)

    # Outer band-edge skirt constants
    emit_single_lr4_constant(lines, sos_hp50, "HP50_COEFFS")
    emit_single_lr4_constant(lines, sos_lp4500, "LP4500_COEFFS")

    # SS controller constants (A, B, C, D for each band)
    for idx, (A, B, C, D) in enumerate(ss_list):
        emit_ss_constant(lines, idx, A, B, C, D)

    lines.append("end package audiodsp_pkg;")
    lines.append("")

    # Write file
    out_path = Path(args.out)
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Written: {out_path}  ({out_path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
