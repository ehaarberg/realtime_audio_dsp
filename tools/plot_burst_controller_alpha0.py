from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


DEFAULT_FS = 48_000.0
DEFAULT_FREQ_HZ = 500.0
DEFAULT_CYCLES = 10
DEFAULT_AMPLITUDE = 0.8
DEFAULT_PRE_MS = 10.0
DEFAULT_POST_MS = 40.0
Q22_SCALE = float(1 << 22)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot the response of a 500 Hz burst (10 cycles) through the state-space "
            "controller with alpha=0 (controller contribution disabled)."
        )
    )
    parser.add_argument(
        "--input-json",
        type=Path,
        default=Path("tools/coeffs/t01/t01_ctrl0_bank1_q22.json"),
        help="Path to uploader bank JSON with q22 coefficients.",
    )
    parser.add_argument("--fs", type=float, default=DEFAULT_FS, help="Sample rate in Hz.")
    parser.add_argument("--freq", type=float, default=DEFAULT_FREQ_HZ, help="Burst frequency in Hz.")
    parser.add_argument("--cycles", type=int, default=DEFAULT_CYCLES, help="Burst length in cycles.")
    parser.add_argument(
        "--waveform",
        choices=("sine", "square"),
        default="sine",
        help="Burst waveform shape.",
    )
    parser.add_argument(
        "--amplitude",
        type=float,
        default=DEFAULT_AMPLITUDE,
        help="Burst sine amplitude in full-scale units [-1, 1].",
    )
    parser.add_argument(
        "--g",
        type=float,
        default=1.0,
        help="Observer gate factor g (0..1).",
    )
    parser.add_argument(
        "--alpha",
        type=float,
        default=0.0,
        help="Controller intervention alpha (0..1). Default is 0 for bypass behavior.",
    )
    parser.add_argument(
        "--pre-ms",
        type=float,
        default=DEFAULT_PRE_MS,
        help="Silence before burst in milliseconds.",
    )
    parser.add_argument(
        "--post-ms",
        type=float,
        default=DEFAULT_POST_MS,
        help="Silence after burst in milliseconds.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("analysis/plots/burst_500hz_alpha0.png"),
        help="Output plot path.",
    )
    parser.add_argument(
        "--pkg",
        type=Path,
        default=Path("audiodsp_pkg.vhd"),
        help="Path to audiodsp_pkg.vhd for crossover coefficient extraction.",
    )
    parser.add_argument(
        "--path",
        choices=("direct", "crossover"),
        default="crossover",
        help="Prediction path: direct bypass or crossover band-sum path.",
    )
    parser.add_argument(
        "--response-delay-ms",
        type=float,
        default=0.0,
        help="Extra delay applied to output trace in milliseconds.",
    )
    return parser.parse_args()


def infer_state_count(coeff_count: int) -> int:
    # Controller payload is packed as A(NxN), B(N), C(N), D(1), L(N), K(N): N^2 + 4N + 1 words.
    # Some files may contain padded tail words; choose largest feasible N.
    best_n = -1
    for n in range(1, 256):
        used = n * n + 4 * n + 1
        if used <= coeff_count:
            best_n = n
        else:
            break
    if best_n < 1:
        raise ValueError(f"Could not infer state count from {coeff_count} coefficients.")
    return best_n


def load_bank_q22(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray, float, np.ndarray, np.ndarray]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    coeffs_i = payload.get("coefficients")
    if not isinstance(coeffs_i, list) or not coeffs_i:
        raise ValueError("JSON does not contain a non-empty 'coefficients' array.")

    coeffs = np.asarray(coeffs_i, dtype=np.float64) / Q22_SCALE
    n = infer_state_count(int(coeffs.size))
    used = n * n + 4 * n + 1
    coeffs = coeffs[:used]

    idx = 0
    a = coeffs[idx : idx + n * n].reshape((n, n))
    idx += n * n
    b = coeffs[idx : idx + n]
    idx += n
    c = coeffs[idx : idx + n]
    idx += n
    d = float(coeffs[idx])
    idx += 1
    l = coeffs[idx : idx + n]
    idx += n
    k = coeffs[idx : idx + n]

    return a, b, c, d, l, k


def make_burst(fs: float, freq: float, cycles: int, amp: float, pre_ms: float, post_ms: float) -> np.ndarray:
    pre_n = int(round(pre_ms * 1e-3 * fs))
    post_n = int(round(post_ms * 1e-3 * fs))
    burst_n = int(round(cycles * fs / freq))

    sig = np.zeros(pre_n + burst_n + post_n, dtype=np.float64)
    t_burst = np.arange(burst_n, dtype=np.float64) / fs
    sig[pre_n : pre_n + burst_n] = amp * np.sin(2.0 * math.pi * freq * t_burst)
    return sig


def make_square_burst(fs: float, freq: float, cycles: int, amp: float, pre_ms: float, post_ms: float) -> np.ndarray:
    pre_n = int(round(pre_ms * 1e-3 * fs))
    post_n = int(round(post_ms * 1e-3 * fs))
    burst_n = int(round(cycles * fs / freq))

    sig = np.zeros(pre_n + burst_n + post_n, dtype=np.float64)
    t_burst = np.arange(burst_n, dtype=np.float64) / fs
    sq = np.sign(np.sin(2.0 * math.pi * freq * t_burst))
    sq[sq == 0.0] = 1.0
    sig[pre_n : pre_n + burst_n] = amp * sq
    return sig


def parse_constant_body(text: str, name: str) -> str:
    match = re.search(
        rf"constant\s+{re.escape(name)}\s*:\s*.*?\s*:=\s*\((.*?)\)\s*;",
        text,
        re.S,
    )
    if not match:
        raise ValueError(f"Could not locate constant body for {name}.")
    return match.group(1)


def parse_sos_bank_from_pkg(text: str, name: str) -> list[tuple[float, float, float, float, float]]:
    body = parse_constant_body(text, name)
    values = [int(v) / Q22_SCALE for v in re.findall(r"to_signed\((-?\d+),\s*24\)", body)]
    if len(values) % 5 != 0:
        raise ValueError(f"{name} does not contain whole biquad sections.")
    return [tuple(values[i : i + 5]) for i in range(0, len(values), 5)]


def apply_biquad_sos(x: np.ndarray, sos: list[tuple[float, float, float, float, float]]) -> np.ndarray:
    y = x.astype(np.float64, copy=True)
    for b0, b1, b2, a1, a2 in sos:
        stage_out = np.zeros_like(y)
        x1 = 0.0
        x2 = 0.0
        y1 = 0.0
        y2 = 0.0
        for n, xn in enumerate(y):
            yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            stage_out[n] = yn
            x2 = x1
            x1 = xn
            y2 = y1
            y1 = yn
        y = stage_out
    return y


def apply_crossover_sum(u: np.ndarray, pkg_path: Path) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    text = pkg_path.read_text(encoding="utf-8", errors="replace")

    lp300 = parse_sos_bank_from_pkg(text, "LP300_COEFFS")
    hp300 = parse_sos_bank_from_pkg(text, "HP300_COEFFS")
    lp1000 = parse_sos_bank_from_pkg(text, "LP1000_COEFFS")
    hp1000 = parse_sos_bank_from_pkg(text, "HP1000_COEFFS")
    lp2500 = parse_sos_bank_from_pkg(text, "LP2500_COEFFS")
    hp2500 = parse_sos_bank_from_pkg(text, "HP2500_COEFFS")
    hp50 = parse_sos_bank_from_pkg(text, "HP50_COEFFS")
    lp4500 = parse_sos_bank_from_pkg(text, "LP4500_COEFFS")

    lp300_b = apply_biquad_sos(u, lp300)
    hp300_b = apply_biquad_sos(u, hp300)
    band0 = apply_biquad_sos(lp300_b, hp50)
    band1 = apply_biquad_sos(hp300_b, lp1000)
    hp1000_b = apply_biquad_sos(hp300_b, hp1000)
    band2 = apply_biquad_sos(hp1000_b, lp2500)
    hp2500_b = apply_biquad_sos(hp1000_b, hp2500)
    band3 = apply_biquad_sos(hp2500_b, lp4500)

    y_prog = band0 + band1 + band2 + band3
    y_prog = np.clip(y_prog, -1.0, 1.0)
    bands = {"band0": band0, "band1": band1, "band2": band2, "band3": band3}
    return y_prog, bands


def delay_signal(x: np.ndarray, fs: float, delay_ms: float) -> np.ndarray:
    if delay_ms <= 0.0:
        return x.copy()
    delay_samples = int(round(delay_ms * 1e-3 * fs))
    if delay_samples <= 0:
        return x.copy()
    y = np.zeros_like(x)
    if delay_samples < x.size:
        y[delay_samples:] = x[:-delay_samples]
    return y


def simulate_controller(
    u: np.ndarray,
    y: np.ndarray,
    a: np.ndarray,
    b: np.ndarray,
    c: np.ndarray,
    d: float,
    l: np.ndarray,
    k: np.ndarray,
    g: float,
    alpha: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    n = b.size
    x = np.zeros(n, dtype=np.float64)
    y_hat = np.zeros_like(u)
    e = np.zeros_like(u)
    u_raw = np.zeros_like(u)
    u_ctrl = np.zeros_like(u)

    for i in range(u.size):
        y_hat_i = d * u[i] + float(c @ x)
        e_i = y[i] - y_hat_i
        u_raw_i = float(k @ x)
        u_ctrl_i = -alpha * u_raw_i

        x = a @ x + b * u[i] + (g * e_i) * l

        y_hat[i] = y_hat_i
        e[i] = e_i
        u_raw[i] = u_raw_i
        u_ctrl[i] = u_ctrl_i

    y_out = u + u_ctrl
    return y_hat, e, u_raw, u_ctrl, y_out


def main() -> None:
    args = parse_args()

    if args.fs <= 0 or args.freq <= 0:
        raise ValueError("fs and freq must be > 0.")
    if args.cycles <= 0:
        raise ValueError("cycles must be > 0.")
    if not (-1.0 <= args.amplitude <= 1.0):
        raise ValueError("amplitude must be in [-1, 1].")
    if not (0.0 <= args.g <= 1.0):
        raise ValueError("g must be in [0, 1].")
    if not (0.0 <= args.alpha <= 1.0):
        raise ValueError("alpha must be in [0, 1].")

    a = b = c = d = l = k = None
    if args.alpha > 0.0:
        a, b, c, d, l, k = load_bank_q22(args.input_json)

    if args.waveform == "square":
        u = make_square_burst(
            fs=args.fs,
            freq=args.freq,
            cycles=args.cycles,
            amp=args.amplitude,
            pre_ms=args.pre_ms,
            post_ms=args.post_ms,
        )
    else:
        u = make_burst(
            fs=args.fs,
            freq=args.freq,
            cycles=args.cycles,
            amp=args.amplitude,
            pre_ms=args.pre_ms,
            post_ms=args.post_ms,
        )

    # In this bench-style simulation, y is either direct monitor or crossover-band sum.
    if args.path == "crossover":
        y_prog, _ = apply_crossover_sum(u, args.pkg)
        y = y_prog
    else:
        y = u.copy()

    if math.isclose(args.alpha, 0.0, abs_tol=1e-15):
        # Exact prediction for alpha=0: controller contribution is identically zero,
        # so output equals the selected program path (direct or crossover sum).
        y_hat = np.zeros_like(u)
        innov = np.zeros_like(u)
        u_raw = np.zeros_like(u)
        u_ctrl = np.zeros_like(u)
        y_out = y.copy()
    else:
        y_hat, innov, u_raw, u_ctrl, y_out = simulate_controller(
            u=u,
            y=y,
            a=a,
            b=b,
            c=c,
            d=d,
            l=l,
            k=k,
            g=args.g,
            alpha=args.alpha,
        )

    y_out = delay_signal(y_out, args.fs, args.response_delay_ms)

    t_ms = 1e3 * np.arange(u.size, dtype=np.float64) / args.fs
    args.out.parent.mkdir(parents=True, exist_ok=True)

    fig, ax0 = plt.subplots(1, 1, figsize=(11, 4.8), sharex=True)

    ax0.plot(t_ms, u, label="input burst u[n]", linewidth=1.8)
    # ax0.plot(t_ms, y, label=f"program path y[n] ({args.path})", linewidth=1.4, alpha=0.9)
    ax0.plot(t_ms, y_out, label="output y[n] + u_ctrl[n]", linewidth=1.6, alpha=0.85)
    ax0.set_ylabel("Amplitude (FS)")
    ax0.set_title(
        f"{args.freq:.1f} Hz {args.waveform} burst ({args.cycles} cycles), alpha={args.alpha:.3f}, g={args.g:.3f}, path={args.path}, delay={args.response_delay_ms:.3f} ms"
    )
    ax0.grid(True, alpha=0.3)
    ax0.legend(loc="upper right")

    ax0.set_xlabel("Time (ms)")

    fig.tight_layout()
    fig.savefig(args.out, dpi=150)

    print(f"Loaded: {args.input_json}")
    if b is not None:
        print(f"States N: {b.size}")
    print(f"Saved plot: {args.out}")
    print(f"Peak |u_ctrl|: {np.max(np.abs(u_ctrl)):.6f}")
    print(f"Peak |u_raw|:  {np.max(np.abs(u_raw)):.6f}")
    print(f"Peak |y_out-y|: {np.max(np.abs(y_out - y)):.6e}")


if __name__ == "__main__":
    main()
