from __future__ import annotations

import argparse
import cmath
import csv
import math
import re
from dataclasses import dataclass
from pathlib import Path


DEFAULT_FS = 48_000.0
DEFAULT_POINTS = 1200
DEFAULT_FMIN = 10.0
DEFAULT_FMAX = 23_990.0


@dataclass(frozen=True)
class SosSection:
    b0: float
    b1: float
    b2: float
    a1: float
    a2: float


@dataclass(frozen=True)
class StateSpaceController:
    name: str
    a: list[list[float]]
    b: list[float]
    c: list[float]
    d: float


@dataclass(frozen=True)
class Series:
    label: str
    color: str
    samples: list[complex]
    stroke_width: float = 2.0
    dash_pattern: str | None = None


@dataclass(frozen=True)
class DspPackage:
    wl: int
    fl: int
    n: int
    sos: dict[str, list[SosSection]]
    controllers: list[StateSpaceController]


@dataclass(frozen=True)
class BandDefinition:
    label: str
    sos_names: tuple[str, ...]
    extra_delay: int = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate bode plots for the SS controllers and the full "
            "crossover-plus-SS response from audiodsp_pkg.vhd."
        )
    )
    parser.add_argument(
        "--pkg",
        type=Path,
        default=Path("audiodsp_pkg.vhd"),
        help="Path to audiodsp_pkg.vhd",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("analysis") / "plots",
        help="Directory for generated plots and CSV data",
    )
    parser.add_argument(
        "--fs",
        type=float,
        default=DEFAULT_FS,
        help="Sample rate in Hz",
    )
    parser.add_argument(
        "--points",
        type=int,
        default=DEFAULT_POINTS,
        help="Number of log-spaced frequency samples",
    )
    parser.add_argument(
        "--fmin",
        type=float,
        default=DEFAULT_FMIN,
        help="Minimum plotted frequency in Hz",
    )
    parser.add_argument(
        "--fmax",
        type=float,
        default=DEFAULT_FMAX,
        help="Maximum plotted frequency in Hz",
    )
    return parser.parse_args()


def parse_vhdl_package(pkg_path: Path) -> DspPackage:
    text = pkg_path.read_text(encoding="utf-8", errors="replace")
    wl = parse_int_constant(text, "WL")
    fl = parse_int_constant(text, "FL")
    n = parse_int_constant(text, "N")
    scale = 2**fl

    sos_names = sorted(set(re.findall(r"constant\s+([A-Z0-9_]+_COEFFS)\s*:\s*sos_bank_t", text)))
    if not sos_names:
        raise ValueError("Could not locate any SOS bank constants in package.")
    sos = {name: parse_sos_bank(text, name, scale) for name in sos_names}

    controllers: list[StateSpaceController] = []
    for index in range(1, 5):
        a_flat = parse_numeric_array(text, f"A{index}", scale)
        b_vec = parse_numeric_array(text, f"B{index}", scale)
        c_vec = parse_numeric_array(text, f"C{index}", scale)
        d_val = parse_signed_scalar(text, f"D{index}", scale)

        if len(a_flat) != n * n:
            raise ValueError(
                f"A{index} contains {len(a_flat)} coefficients, expected {n * n}."
            )
        if len(b_vec) != n or len(c_vec) != n:
            raise ValueError(
                f"Controller {index} vector sizes do not match N={n}."
            )

        a_mat = [a_flat[row * n : (row + 1) * n] for row in range(n)]
        controllers.append(
            StateSpaceController(
                name=f"SS{index}",
                a=a_mat,
                b=b_vec,
                c=c_vec,
                d=d_val,
            )
        )

    return DspPackage(wl=wl, fl=fl, n=n, sos=sos, controllers=controllers)


def parse_int_constant(text: str, name: str) -> int:
    match = re.search(rf"constant\s+{re.escape(name)}\s*:\s*integer\s*:=\s*(\d+)\s*;", text)
    if not match:
        raise ValueError(f"Could not locate integer constant {name}.")
    return int(match.group(1))


def parse_numeric_array(text: str, name: str, scale: float) -> list[float]:
    body = parse_constant_body(text, name)
    return [int(value) / scale for value in re.findall(r"to_signed\((-?\d+),\s*24\)", body)]


def parse_signed_scalar(text: str, name: str, scale: float) -> float:
    match = re.search(
        rf"constant\s+{re.escape(name)}\s*:\s*signed\([^\)]*\)\s*:=\s*to_signed\((-?\d+),\s*24\)\s*;",
        text,
    )
    if not match:
        raise ValueError(f"Could not locate scalar constant {name}.")
    return int(match.group(1)) / scale


def parse_constant_body(text: str, name: str) -> str:
    match = re.search(
        rf"constant\s+{re.escape(name)}\s*:\s*.*?\s*:=\s*\((.*?)\)\s*;",
        text,
        re.S,
    )
    if not match:
        raise ValueError(f"Could not locate constant body for {name}.")
    return match.group(1)


def parse_sos_bank(text: str, name: str, scale: float) -> list[SosSection]:
    values = parse_numeric_array(text, name, scale)
    if len(values) % 5 != 0:
        raise ValueError(f"{name} does not contain a whole number of biquad sections.")
    sections: list[SosSection] = []
    for index in range(0, len(values), 5):
        sections.append(SosSection(*values[index : index + 5]))
    return sections


def logspace(start_hz: float, stop_hz: float, points: int) -> list[float]:
    if start_hz <= 0 or stop_hz <= start_hz:
        raise ValueError("Frequency range must satisfy 0 < fmin < fmax.")
    if points < 2:
        raise ValueError("At least two points are required.")

    log_start = math.log10(start_hz)
    log_stop = math.log10(stop_hz)
    return [10 ** (log_start + (log_stop - log_start) * index / (points - 1)) for index in range(points)]


def solve_linear_system(matrix: list[list[complex]], rhs: list[complex]) -> list[complex]:
    size = len(rhs)
    aug = [row[:] + [rhs_val] for row, rhs_val in zip(matrix, rhs)]

    for col in range(size):
        pivot_row = max(range(col, size), key=lambda row: abs(aug[row][col]))
        if abs(aug[pivot_row][col]) < 1e-14:
            raise ValueError("Singular matrix while evaluating state-space response.")
        aug[col], aug[pivot_row] = aug[pivot_row], aug[col]

        pivot = aug[col][col]
        for row in range(col + 1, size):
            factor = aug[row][col] / pivot
            if factor == 0:
                continue
            for idx in range(col, size + 1):
                aug[row][idx] -= factor * aug[col][idx]

    solution = [0j] * size
    for row in range(size - 1, -1, -1):
        value = aug[row][size]
        for col in range(row + 1, size):
            value -= aug[row][col] * solution[col]
        solution[row] = value / aug[row][row]

    return solution


def state_space_response(controller: StateSpaceController, z: complex) -> complex:
    size = len(controller.b)
    rhs = [complex(value, 0.0) for value in controller.b]
    matrix = [
        [((z if row == col else 0j) - controller.a[row][col]) for col in range(size)]
        for row in range(size)
    ]
    try:
        state = solve_linear_system(matrix, rhs)
    except ValueError:
        # Avoid aborting on isolated frequency samples where (zI-A) is nearly
        # singular by adding a tiny diagonal regularization.
        state = None
        for eps in (1e-12, 1e-10, 1e-8, 1e-6):
            reg_matrix = [row[:] for row in matrix]
            for idx in range(size):
                reg_matrix[idx][idx] += eps
            try:
                state = solve_linear_system(reg_matrix, rhs)
                break
            except ValueError:
                continue
        if state is None:
            raise ValueError("State-space response is singular at this frequency sample.")
    return complex(controller.d, 0.0) + sum(controller.c[idx] * state[idx] for idx in range(size))


def biquad_response(section: SosSection, z: complex) -> complex:
    z_inv = 1.0 / z
    z_inv2 = z_inv * z_inv
    numerator = section.b0 + section.b1 * z_inv + section.b2 * z_inv2
    denominator = 1.0 + section.a1 * z_inv + section.a2 * z_inv2
    return z_inv * numerator / denominator


def cascade_response(sections: list[SosSection], z: complex, extra_delay: int = 0) -> complex:
    response = 1.0 + 0.0j
    for section in sections:
        response *= biquad_response(section, z)
    if extra_delay:
        response *= z ** (-extra_delay)
    return response


def crossover_band_responses(pkg: DspPackage, frequencies: list[float], fs: float) -> dict[str, list[complex]]:
    band_defs = build_band_definitions(pkg.sos)
    responses: dict[str, list[complex]] = {band.label: [] for band in band_defs}
    for frequency in frequencies:
        z = cmath.exp(1j * 2.0 * math.pi * frequency / fs)
        for band in band_defs:
            sections: list[SosSection] = []
            for name in band.sos_names:
                sections.extend(pkg.sos[name])
            responses[band.label].append(
                cascade_response(sections, z, extra_delay=band.extra_delay)
            )
    return responses


def build_band_definitions(sos: dict[str, list[SosSection]]) -> list[BandDefinition]:
    # Current thesis split chain used in crossover_filters.vhd:
    # band0 = LP300 -> HP50, band1 = HP300 -> LP1000,
    # band2 = HP300 -> HP1000 -> LP2500,
    # band3 = HP300 -> HP1000 -> HP2500 -> LP4500.
    thesis = [
        BandDefinition("Band0 50-300 Hz", ("LP300_COEFFS", "HP50_COEFFS")),
        BandDefinition("Band1 300-1000 Hz", ("HP300_COEFFS", "LP1000_COEFFS")),
        BandDefinition("Band2 1000-2500 Hz", ("HP300_COEFFS", "HP1000_COEFFS", "LP2500_COEFFS")),
        BandDefinition("Band3 2500-4500 Hz", ("HP300_COEFFS", "HP1000_COEFFS", "HP2500_COEFFS", "LP4500_COEFFS")),
    ]
    if all(all(name in sos for name in band.sos_names) for band in thesis):
        return thesis

    # Backward-compatible legacy split chain.
    legacy = [
        BandDefinition("Band0 <300 Hz", ("LP300_COEFFS",), extra_delay=2),
        BandDefinition("Band1 300-1000 Hz", ("HP300_COEFFS", "LP1000_COEFFS")),
        BandDefinition("Band2 1000-8000 Hz", ("HP1000_COEFFS", "LP8000_COEFFS")),
        BandDefinition("Band3 >8000 Hz", ("HP8000_COEFFS",), extra_delay=2),
    ]
    if all(all(name in sos for name in band.sos_names) for band in legacy):
        return legacy

    available = ", ".join(sorted(sos.keys()))
    raise ValueError(
        "Unsupported crossover constant set in package. "
        f"Available constants: {available}"
    )


def controller_responses(pkg: DspPackage, frequencies: list[float], fs: float) -> dict[str, list[complex]]:
    responses: dict[str, list[complex]] = {controller.name: [] for controller in pkg.controllers}
    fallback_used = {controller.name: False for controller in pkg.controllers}
    for frequency in frequencies:
        z = cmath.exp(1j * 2.0 * math.pi * frequency / fs)
        for controller in pkg.controllers:
            try:
                sample = state_space_response(controller, z)
            except ValueError:
                # Keep the curve continuous if one frequency point is singular.
                previous = responses[controller.name][-1] if responses[controller.name] else complex(0.0, 0.0)
                sample = previous
                fallback_used[controller.name] = True
            responses[controller.name].append(sample)

    for controller in pkg.controllers:
        if fallback_used[controller.name]:
            print(
                f"Warning: singular SS point(s) encountered for {controller.name}; "
                "used previous-sample fallback at those frequencies."
            )
    return responses


def identical_controllers(controllers: list[StateSpaceController]) -> bool:
    if not controllers:
        return True
    first = controllers[0]
    return all(
        controller.a == first.a
        and controller.b == first.b
        and controller.c == first.c
        and controller.d == first.d
        for controller in controllers[1:]
    )


def magnitude_db(response: complex) -> float:
    magnitude = abs(response)
    return -180.0 if magnitude <= 1e-18 else 20.0 * math.log10(magnitude)


def unwrap_phase_deg(responses: list[complex]) -> list[float]:
    raw = [math.degrees(cmath.phase(value)) for value in responses]
    if not raw:
        return []

    unwrapped = [raw[0]]
    offset = 0.0
    for index in range(1, len(raw)):
        delta = raw[index] - raw[index - 1]
        if delta > 180.0:
            offset -= 360.0
        elif delta < -180.0:
            offset += 360.0
        unwrapped.append(raw[index] + offset)
    return unwrapped


def nice_step(span: float) -> float:
    if span <= 0:
        return 1.0
    base = 10 ** math.floor(math.log10(span))
    normalized = span / base
    if normalized <= 1.5:
        return 0.2 * base
    if normalized <= 3.0:
        return 0.5 * base
    if normalized <= 7.0:
        return 1.0 * base
    return 2.0 * base


def padded_range(values: list[float], minimum_padding: float) -> tuple[float, float]:
    lo = min(values)
    hi = max(values)
    if math.isclose(lo, hi, rel_tol=0.0, abs_tol=1e-9):
        lo -= minimum_padding
        hi += minimum_padding
    else:
        pad = max(minimum_padding, 0.08 * (hi - lo))
        lo -= pad
        hi += pad

    step = nice_step(hi - lo)
    y_min = math.floor(lo / step) * step
    y_max = math.ceil(hi / step) * step
    return y_min, y_max


def y_ticks(y_min: float, y_max: float) -> list[float]:
    step = nice_step(y_max - y_min)
    count = int(round((y_max - y_min) / step))
    return [y_min + index * step for index in range(count + 1)]


def format_frequency_label(frequency: float) -> str:
    if frequency >= 1000:
        if frequency % 1000 == 0:
            return f"{int(frequency / 1000)}k"
        return f"{frequency / 1000:.1f}k"
    return f"{int(frequency)}"


def svg_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def write_bode_svg(
    out_path: Path,
    title: str,
    frequencies: list[float],
    series_list: list[Series],
) -> None:
    width = 1320
    height = 940
    left = 90
    right = 250
    top = 70
    bottom = 70
    plot_width = width - left - right
    panel_gap = 46
    panel_height = (height - top - bottom - panel_gap) / 2.0
    mag_top = top
    mag_bottom = top + panel_height
    phase_top = mag_bottom + panel_gap
    phase_bottom = phase_top + panel_height

    x_min = math.log10(frequencies[0])
    x_max = math.log10(frequencies[-1])

    def x_map(frequency: float) -> float:
        return left + (math.log10(frequency) - x_min) * plot_width / (x_max - x_min)

    magnitude_values = [magnitude_db(sample) for series in series_list for sample in series.samples]
    phase_values = [phase for series in series_list for phase in unwrap_phase_deg(series.samples)]
    mag_min, mag_max = padded_range(magnitude_values, minimum_padding=6.0)
    phase_min, phase_max = padded_range(phase_values, minimum_padding=20.0)

    def y_map(value: float, y0: float, y1: float, vmin: float, vmax: float) -> float:
        return y1 - (value - vmin) * (y1 - y0) / (vmax - vmin)

    lines: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<style>',
        'text { font-family: Segoe UI, Arial, sans-serif; fill: #1f2937; }',
        '.title { font-size: 24px; font-weight: 700; }',
        '.axis { font-size: 12px; }',
        '.legend { font-size: 13px; }',
        '.grid { stroke: #d1d5db; stroke-width: 1; }',
        '.frame { stroke: #111827; stroke-width: 1.5; fill: none; }',
        '</style>',
        f'<text x="{left}" y="36" class="title">{svg_escape(title)}</text>',
    ]

    grid_freqs = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    grid_freqs = [value for value in grid_freqs if frequencies[0] <= value <= frequencies[-1]]
    for frequency in grid_freqs:
        x_pos = x_map(float(frequency))
        lines.append(f'<line x1="{x_pos:.2f}" y1="{mag_top:.2f}" x2="{x_pos:.2f}" y2="{mag_bottom:.2f}" class="grid"/>')
        lines.append(f'<line x1="{x_pos:.2f}" y1="{phase_top:.2f}" x2="{x_pos:.2f}" y2="{phase_bottom:.2f}" class="grid"/>')
        lines.append(
            f'<text x="{x_pos:.2f}" y="{phase_bottom + 24:.2f}" text-anchor="middle" class="axis">'
            f'{format_frequency_label(float(frequency))}</text>'
        )

    for tick in y_ticks(mag_min, mag_max):
        y_pos = y_map(tick, mag_top, mag_bottom, mag_min, mag_max)
        lines.append(f'<line x1="{left:.2f}" y1="{y_pos:.2f}" x2="{left + plot_width:.2f}" y2="{y_pos:.2f}" class="grid"/>')
        lines.append(
            f'<text x="{left - 10:.2f}" y="{y_pos + 4:.2f}" text-anchor="end" class="axis">{tick:.0f}</text>'
        )

    for tick in y_ticks(phase_min, phase_max):
        y_pos = y_map(tick, phase_top, phase_bottom, phase_min, phase_max)
        lines.append(f'<line x1="{left:.2f}" y1="{y_pos:.2f}" x2="{left + plot_width:.2f}" y2="{y_pos:.2f}" class="grid"/>')
        lines.append(
            f'<text x="{left - 10:.2f}" y="{y_pos + 4:.2f}" text-anchor="end" class="axis">{tick:.0f}</text>'
        )

    lines.append(f'<rect x="{left:.2f}" y="{mag_top:.2f}" width="{plot_width:.2f}" height="{panel_height:.2f}" class="frame"/>')
    lines.append(f'<rect x="{left:.2f}" y="{phase_top:.2f}" width="{plot_width:.2f}" height="{panel_height:.2f}" class="frame"/>')
    lines.append(f'<text x="{left - 58:.2f}" y="{mag_top + panel_height / 2:.2f}" text-anchor="middle" transform="rotate(-90 {left - 58:.2f} {mag_top + panel_height / 2:.2f})" class="axis">Magnitude (dB)</text>')
    lines.append(f'<text x="{left - 58:.2f}" y="{phase_top + panel_height / 2:.2f}" text-anchor="middle" transform="rotate(-90 {left - 58:.2f} {phase_top + panel_height / 2:.2f})" class="axis">Phase (deg)</text>')
    lines.append(f'<text x="{left + plot_width / 2:.2f}" y="{height - 18:.2f}" text-anchor="middle" class="axis">Frequency (Hz)</text>')

    for series in series_list:
        mag_points = " ".join(
            f"{x_map(frequency):.2f},{y_map(magnitude_db(sample), mag_top, mag_bottom, mag_min, mag_max):.2f}"
            for frequency, sample in zip(frequencies, series.samples)
        )
        phase_points = " ".join(
            f"{x_map(frequency):.2f},{y_map(phase, phase_top, phase_bottom, phase_min, phase_max):.2f}"
            for frequency, phase in zip(frequencies, unwrap_phase_deg(series.samples))
        )
        dash_attr = f' stroke-dasharray="{series.dash_pattern}"' if series.dash_pattern else ""
        lines.append(
            f'<polyline fill="none" stroke="{series.color}" stroke-width="{series.stroke_width}"{dash_attr} points="{mag_points}"/>'
        )
        lines.append(
            f'<polyline fill="none" stroke="{series.color}" stroke-width="{series.stroke_width}"{dash_attr} points="{phase_points}"/>'
        )

    legend_x = left + plot_width + 24
    legend_y = top + 10
    lines.append(
        f'<rect x="{legend_x - 14:.2f}" y="{legend_y - 20:.2f}" width="{right - 30:.2f}" height="{28 * len(series_list) + 26:.2f}" fill="#f9fafb" stroke="#d1d5db"/>'
    )
    for index, series in enumerate(series_list):
        y_pos = legend_y + 28 * index
        dash_attr = f' stroke-dasharray="{series.dash_pattern}"' if series.dash_pattern else ""
        lines.append(
            f'<line x1="{legend_x:.2f}" y1="{y_pos:.2f}" x2="{legend_x + 34:.2f}" y2="{y_pos:.2f}" stroke="{series.color}" stroke-width="{series.stroke_width}"{dash_attr}/>'
        )
        lines.append(
            f'<text x="{legend_x + 44:.2f}" y="{y_pos + 4:.2f}" class="legend">{svg_escape(series.label)}</text>'
        )

    lines.append('</svg>')
    out_path.write_text("\n".join(lines), encoding="utf-8")


def write_csv(
    out_path: Path,
    frequencies: list[float],
    ss_series: list[Series],
    combined_series: list[Series],
) -> None:
    header = ["frequency_hz"]
    all_series = ss_series + combined_series
    for series in all_series:
        safe = sanitize_label(series.label)
        header.extend([f"{safe}_mag_db", f"{safe}_phase_deg"])

    with out_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        unwrapped = {series.label: unwrap_phase_deg(series.samples) for series in all_series}
        for index, frequency in enumerate(frequencies):
            row: list[float | str] = [f"{frequency:.6f}"]
            for series in all_series:
                row.append(f"{magnitude_db(series.samples[index]):.6f}")
                row.append(f"{unwrapped[series.label][index]:.6f}")
            writer.writerow(row)


def sanitize_label(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_")


def main() -> None:
    args = parse_args()
    pkg = parse_vhdl_package(args.pkg)
    frequencies = logspace(args.fmin, args.fmax, args.points)
    controller_map = controller_responses(pkg, frequencies, args.fs)
    band_map = crossover_band_responses(pkg, frequencies, args.fs)
    band_labels = list(band_map.keys())

    colors = ["#1d4ed8", "#0f766e", "#b45309", "#7c3aed"]
    branch_colors = ["#2563eb", "#059669", "#d97706", "#9333ea"]

    ss_series = [
        Series(label=name, color=colors[index], samples=controller_map[name])
        for index, name in enumerate(sorted(controller_map.keys()))
    ]

    branch_responses: list[list[complex]] = []
    combined_series: list[Series] = []
    for index, band_label in enumerate(band_labels):
        controller_label = f"SS{index + 1}"
        branch = [
            band_sample * ss_sample
            for band_sample, ss_sample in zip(band_map[band_label], controller_map[controller_label])
        ]
        branch_responses.append(branch)
        combined_series.append(
            Series(
                label=f"{band_label} x {controller_label}",
                color=branch_colors[index],
                samples=branch,
                stroke_width=1.8,
            )
        )

    crossover_sum = [sum(values) for values in zip(*(band_map[label] for label in band_labels))]
    processed_sum = [sum(values) for values in zip(*branch_responses)]
    combined_series.append(
        Series(
            label="Crossover sum only",
            color="#6b7280",
            samples=crossover_sum,
            stroke_width=2.4,
            dash_pattern="7 4",
        )
    )
    combined_series.append(
        Series(
            label="Crossover + SS summed output",
            color="#dc2626",
            samples=processed_sum,
            stroke_width=2.8,
        )
    )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    ss_svg = args.out_dir / "ss_blocks_bode.svg"
    combined_svg = args.out_dir / "crossover_plus_ss_bode.svg"
    csv_path = args.out_dir / "dsp_response_data.csv"

    write_bode_svg(ss_svg, "SS Controller Bode Response", frequencies, ss_series)
    write_bode_svg(
        combined_svg,
        "Crossover + SS Bode Response",
        frequencies,
        combined_series,
    )
    write_csv(csv_path, frequencies, ss_series, combined_series)

    identical_note = "yes" if identical_controllers(pkg.controllers) else "no"
    print(f"Wrote {ss_svg}")
    print(f"Wrote {combined_svg}")
    print(f"Wrote {csv_path}")
    print(f"All SS controllers identical: {identical_note}")


if __name__ == "__main__":
    main()