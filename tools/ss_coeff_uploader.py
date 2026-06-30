from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import serial
    from serial import SerialException
except ImportError:
    serial = None

    class SerialException(Exception):
        pass


UART_SYNC0 = 0x55
UART_SYNC1 = 0xAA
UART_RESP_BIT = 0x80
UART_ERROR_CMD = 0x7F

UART_CMD_WRITE_BLOCK = 0x01
UART_CMD_READ_BLOCK = 0x02
UART_STATUS_BAD_COMMAND = 0x03
UART_CMD_GET_STATUS = 0x05
UART_CMD_POC_SET_ALPHA = 0x10

UART_STATUS_OK = 0x00
UART_STATUS_BAD_CHECKSUM = 0x01
UART_STATUS_BAD_LENGTH = 0x02
UART_STATUS_BAD_COMMAND = 0x03
UART_STATUS_BAD_ARGS = 0x04
UART_STATUS_RANGE = 0x05
UART_STATUS_HW_TIMEOUT = 0x06

UART_MAX_PAYLOAD = 2048
SS_CTRL_COUNT = 4
SS_BANK_COUNT = 8
SS_A_COUNT = 30 * 30
SS_B_COUNT = 30
SS_C_COUNT = 30
SS_D_COUNT = 1
SS_L_COUNT = 30
SS_K_COUNT = 30
SS_COEFFS_PER_BANK = SS_A_COUNT + SS_B_COUNT + SS_C_COUNT + SS_D_COUNT + SS_L_COUNT + SS_K_COUNT
SS_K_BASE = SS_A_COUNT + SS_B_COUNT + SS_C_COUNT + SS_D_COUNT + SS_L_COUNT
Q22_SCALE = 1 << 22
Q22_MIN = -8388608
Q22_MAX = 8388607
MAX_WORDS_PER_FRAME = (UART_MAX_PAYLOAD - 6) // 4

# Four LR4 crossover bands (splits at 300 / 1000 / 2500 Hz), one state-space
# controller each. See crossover_filters.vhd (band0..band3).
CONTROLLER_LABELS = ["low", "low-mid", "high-mid", "high"]
CONTROLLER_ALIASES = {
    "0": 0, "1": 1, "2": 2, "3": 3,
    "ss1": 0, "ss2": 1, "ss3": 2, "ss4": 3,
    "band0": 0, "band1": 1, "band2": 2, "band3": 3,
    "low": 0, "sub": 0, "bass": 0,
    "low-mid": 1, "lowmid": 1, "lomid": 1,
    "high-mid": 2, "highmid": 2, "mid": 2,
    "high": 3, "treble": 3, "air": 3,
}
STATUS_NAMES = {
    UART_STATUS_OK: "ok",
    UART_STATUS_BAD_CHECKSUM: "bad-checksum",
    UART_STATUS_BAD_LENGTH: "bad-length",
    UART_STATUS_BAD_COMMAND: "bad-command",
    UART_STATUS_BAD_ARGS: "bad-args",
    UART_STATUS_RANGE: "range",
    UART_STATUS_HW_TIMEOUT: "hw-timeout",
}


@dataclass(frozen=True)
class DeviceStatus:
    shadow_pending_raw: int
    active_raw: int
    pending_raw: int
    busy_mask: int

    @property
    def shadow_pending(self) -> tuple[int, ...]:
        return unpack_bank_fields(self.shadow_pending_raw)

    @property
    def active(self) -> tuple[int, ...]:
        return unpack_bank_fields(self.active_raw)

    @property
    def pending(self) -> tuple[int, ...]:
        return unpack_bank_fields(self.pending_raw)

    def to_dict(self) -> dict[str, object]:
        controllers: list[dict[str, object]] = []
        for index, name in enumerate(CONTROLLER_LABELS):
            controllers.append(
                {
                    "index": index,
                    "name": name,
                    "shadow_pending_bank": self.shadow_pending[index],
                    "active_bank": self.active[index],
                    "pending_bank": self.pending[index],
                    "busy": bool(self.busy_mask & (1 << index)),
                }
            )

        return {
            "shadow_pending_raw": self.shadow_pending_raw,
            "active_raw": self.active_raw,
            "pending_raw": self.pending_raw,
            "busy_mask": self.busy_mask,
            "controllers": controllers,
        }


@dataclass(frozen=True)
class PresetEntry:
    controller: int
    bank: int
    words: list[int]


class ProtocolError(RuntimeError):
    pass


class DeviceResponseError(RuntimeError):
    def __init__(self, status: int, context: str):
        self.status = status
        super().__init__(f"{context}: {status_name(status)} (0x{status:02X})")


class CoeffClient:
    def __init__(self, port: str, baud: int, timeout: float):
        if serial is None:
            raise RuntimeError(
                "pyserial not installed in current environment. Install with: pip install pyserial"
            )

        self._port = serial.Serial(
            port=port,
            baudrate=baud,
            timeout=timeout,
            write_timeout=timeout,
        )
        self._sequence = 0

    def close(self) -> None:
        self._port.close()

    def __enter__(self) -> "CoeffClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def get_status(self) -> DeviceStatus:
        response = self._request(UART_CMD_GET_STATUS, b"")
        payload = self._expect_ok(response, 14, "get-status")
        return DeviceStatus(
            shadow_pending_raw=struct.unpack_from("<I", payload, 1)[0],
            active_raw=struct.unpack_from("<I", payload, 5)[0],
            pending_raw=struct.unpack_from("<I", payload, 9)[0],
            busy_mask=payload[13],
        )

    def write_block(self, controller: int, bank: int, start_index: int, words: list[int]) -> None:
        for offset in range(0, len(words), MAX_WORDS_PER_FRAME):
            chunk = words[offset : offset + MAX_WORDS_PER_FRAME]
            payload = bytearray(struct.pack("<BBHH", controller, bank, start_index + offset, len(chunk)))
            for word in chunk:
                payload.extend(struct.pack("<i", word))
            response = self._request(UART_CMD_WRITE_BLOCK, bytes(payload))
            payload_out = self._expect_ok(response, 3, "write-block")
            chunk_count = struct.unpack_from("<H", payload_out, 1)[0]
            if chunk_count != len(chunk):
                raise ProtocolError(
                    f"write-block count mismatch: expected {len(chunk)}, got {chunk_count}"
                )

    def read_block(self, controller: int, bank: int, start_index: int, count: int) -> list[int]:
        words: list[int] = []
        remaining = count
        offset = 0
        while remaining > 0:
            chunk_count = min(remaining, MAX_WORDS_PER_FRAME)
            payload = struct.pack("<BBHH", controller, bank, start_index + offset, chunk_count)
            response = self._request(UART_CMD_READ_BLOCK, payload)
            payload_out = self._expect_ok(response, 3 + (chunk_count * 4), "read-block")
            echoed_count = struct.unpack_from("<H", payload_out, 1)[0]
            if echoed_count != chunk_count:
                raise ProtocolError(
                    f"read-block count mismatch: expected {chunk_count}, got {echoed_count}"
                )
            for index in range(chunk_count):
                words.append(struct.unpack_from("<i", payload_out, 3 + (index * 4))[0])
            remaining -= chunk_count
            offset += chunk_count
        return words

    def set_poc_alpha(self, level: int) -> int:
        if level < 0 or level > 255:
            raise ValueError("PoC alpha level out of range. Expected 0..255.")
        payload = bytes([level])
        response = self._request(UART_CMD_POC_SET_ALPHA, payload)
        payload_out = self._expect_ok(response, 2, "poc-set-alpha")
        return int(payload_out[1])

    def _request(self, command: int, payload: bytes) -> bytes:
        sequence = self._next_sequence()
        frame = build_frame(command, sequence, payload)
        self._port.write(frame)
        self._port.flush()

        response_cmd, response_seq, response_payload = self._recv_frame()
        if response_seq != sequence:
            raise ProtocolError(
                f"response sequence mismatch: expected {sequence}, got {response_seq}"
            )
        if response_cmd == UART_ERROR_CMD:
            status = response_payload[0] if response_payload else UART_STATUS_BAD_COMMAND
            raise DeviceResponseError(status, "frame-error")

        expected_cmd = command | UART_RESP_BIT
        if response_cmd != expected_cmd:
            raise ProtocolError(
                f"unexpected response command: expected 0x{expected_cmd:02X}, got 0x{response_cmd:02X}"
            )

        return response_payload

    def _expect_ok(self, payload: bytes, expected_length: int, context: str) -> bytes:
        if len(payload) < 1:
            raise ProtocolError(f"{context}: missing status byte")
        status = payload[0]
        if status != UART_STATUS_OK:
            raise DeviceResponseError(status, context)
        if len(payload) != expected_length:
            raise ProtocolError(
                f"{context}: expected {expected_length} payload bytes, got {len(payload)}"
            )
        return payload

    def _recv_frame(self) -> tuple[int, int, bytes]:
        while True:
            if self._read_exact(1)[0] != UART_SYNC0:
                continue
            if self._read_exact(1)[0] == UART_SYNC1:
                break

        header = self._read_exact(4)
        command = header[0]
        sequence = header[1]
        length = struct.unpack("<H", header[2:4])[0]
        if length > UART_MAX_PAYLOAD:
            raise ProtocolError(f"response length {length} exceeds {UART_MAX_PAYLOAD}")
        payload = self._read_exact(length)
        checksum = self._read_exact(1)[0]
        expected_checksum = frame_checksum(command, sequence, payload)
        if checksum != expected_checksum:
            raise ProtocolError(
                f"checksum mismatch: expected 0x{expected_checksum:02X}, got 0x{checksum:02X}"
            )
        return command, sequence, payload

    def _read_exact(self, size: int) -> bytes:
        data = bytearray()
        while len(data) < size:
            chunk = self._port.read(size - len(data))
            if not chunk:
                raise TimeoutError(f"Timed out reading {size} byte(s) from UART.")
            data.extend(chunk)
        return bytes(data)

    def _next_sequence(self) -> int:
        sequence = self._sequence
        self._sequence = (self._sequence + 1) & 0xFF
        return sequence


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Upload and switch runtime SS controller coefficients over the bare-metal UART "
            "protocol. Controllers map as: 0=low, 1=low-mid, 2=high-mid, 3=high."
        )
    )
    parser.add_argument(
        "--port",
        help="Serial port, for example COM5 or /dev/ttyUSB0. Required for device commands.",
    )
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate. Default: 115200")
    parser.add_argument(
        "--timeout",
        type=float,
        default=1.0,
        help="Read and write timeout in seconds. Default: 1.0",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    status_parser = subparsers.add_parser("status", help="Read active, pending, and busy bank status")
    status_parser.add_argument("--json", action="store_true", help="Emit status as JSON")
    status_parser.set_defaults(func=run_status)

    write_parser = subparsers.add_parser("write-bank", help="Write coefficients into one controller bank")
    write_parser.add_argument("--controller", required=True, help="Controller index or name")
    write_parser.add_argument("--bank", type=int, required=True, help="Target bank 0..7")
    write_parser.add_argument("--input", type=Path, required=True, help="JSON or text file with coefficients")
    write_parser.add_argument(
        "--input-values",
        choices=("auto", "float", "q22"),
        default="auto",
        help=(
            "How numeric input values are interpreted. auto: JSON/text floats convert to Q22, "
            "integers pass through as raw Q22 words."
        ),
    )
    write_parser.add_argument("--start-index", type=int, default=0, help="First coefficient index within the bank")
    write_parser.add_argument("--no-verify", action="store_true", help="Skip readback verification")
    write_parser.set_defaults(func=run_write_bank)

    read_parser = subparsers.add_parser("read-bank", help="Read coefficients from one controller bank")
    read_parser.add_argument("--controller", required=True, help="Controller index or name")
    read_parser.add_argument("--bank", type=int, required=True, help="Source bank 0..7")
    read_parser.add_argument("--start-index", type=int, default=0, help="First coefficient index within the bank")
    read_parser.add_argument("--count", type=int, default=SS_COEFFS_PER_BANK, help="Number of coefficients to read")
    read_parser.add_argument(
        "--output-values",
        choices=("float", "q22"),
        default="float",
        help="Value format for the exported coefficients. Default: float",
    )
    read_parser.add_argument("--output", type=Path, help="Optional JSON output file")
    read_parser.set_defaults(func=run_read_bank)

    preset_parser = subparsers.add_parser(
        "write-preset",
        help="Load a multi-controller preset's coefficients into their banks",
    )
    preset_parser.add_argument("--input", type=Path, required=True, help="Preset JSON file")
    preset_parser.add_argument(
        "--input-values",
        choices=("auto", "float", "q22"),
        default="auto",
        help=(
            "How preset numbers are interpreted. auto: floats convert to Q22, integers pass through as raw Q22 words."
        ),
    )
    preset_parser.add_argument(
        "--set",
        dest="assignments",
        action="append",
        metavar="CTRL=BANK",
        help="Override target bank from the preset file for one or more controllers.",
    )
    preset_parser.add_argument("--no-verify", action="store_true", help="Skip readback verification")
    preset_parser.add_argument("--json", action="store_true", help="Emit resulting status as JSON")
    preset_parser.set_defaults(func=run_write_preset)

    export_parser = subparsers.add_parser(
        "export-defaults",
        help="Export default SS controller coefficients from audiodsp_pkg.vhd as preset JSON",
    )
    export_parser.add_argument(
        "--pkg",
        type=Path,
        default=Path("audiodsp_pkg.vhd"),
        help="Path to audiodsp_pkg.vhd. Default: audiodsp_pkg.vhd",
    )
    export_parser.add_argument("--output", type=Path, required=True, help="Output JSON file")
    export_parser.add_argument(
        "--bank",
        type=int,
        default=1,
        help="Target bank to record in the exported preset. Default: 1",
    )
    export_parser.add_argument(
        "--output-values",
        choices=("float", "q22"),
        default="float",
        help="Value format for exported coefficients. Default: float",
    )
    export_parser.set_defaults(func=run_export_defaults)

    selftest_parser = subparsers.add_parser(
        "poc-selftest",
        help=(
            "Run PoC sanity checks against device: alpha command path and K-vector layout "
            "(expects one controller K non-zero and one controller K all-zero)"
        ),
    )
    selftest_parser.add_argument(
        "--bank",
        type=int,
        default=0,
        help="Bank to inspect for K vectors. Default: 0",
    )
    selftest_parser.add_argument(
        "--active-controller",
        type=int,
        default=1,
        help="Controller expected to have non-zero K entries. Default: 1",
    )
    selftest_parser.add_argument(
        "--inactive-controller",
        type=int,
        default=0,
        help="Controller expected to have all-zero K entries. Default: 0",
    )
    selftest_parser.set_defaults(func=run_poc_selftest)

    poc_alpha_parser = subparsers.add_parser(
        "poc-alpha",
        help="Set PoC single-band controller alpha (requires firmware POC_SINGLE_BAND=1)",
    )
    poc_alpha_parser.add_argument(
        "--poc-alpha",
        required=True,
        help=(
            "Alpha command. Accepts float 0..1 (for example 0.05) or integer "
            "0..255. 0=off, 1.0/255=full."
        ),
    )
    poc_alpha_parser.set_defaults(func=run_poc_alpha)

    return parser


def run_status(args: argparse.Namespace) -> int:
    with open_client(args) as client:
        status = client.get_status()
    emit_status(status, as_json=args.json)
    return 0


def run_write_bank(args: argparse.Namespace) -> int:
    controller = parse_controller(args.controller)
    validate_bank(args.bank)
    words = load_coeff_words(args.input, args.input_values)
    validate_bank_window(args.start_index, len(words))

    with open_client(args) as client:
        client.write_block(controller, args.bank, args.start_index, words)
        print(
            f"Wrote {len(words)} coefficient(s) to controller {controller} "
            f"({CONTROLLER_LABELS[controller]}) bank {args.bank} starting at index {args.start_index}."
        )

        if not args.no_verify:
            readback = client.read_block(controller, args.bank, args.start_index, len(words))
            if readback != words:
                mismatch = first_mismatch(words, readback)
                raise RuntimeError(
                    "Readback mismatch at bank index "
                    f"{args.start_index + mismatch}: wrote {words[mismatch]}, read {readback[mismatch]}"
                )
            print("Readback verification passed.")

    return 0


def run_read_bank(args: argparse.Namespace) -> int:
    controller = parse_controller(args.controller)
    validate_bank(args.bank)
    validate_bank_window(args.start_index, args.count)

    with open_client(args) as client:
        words = client.read_block(controller, args.bank, args.start_index, args.count)

    dump = build_bank_dump(
        controller=controller,
        bank=args.bank,
        start_index=args.start_index,
        words=words,
        output_values=args.output_values,
    )
    rendered = json.dumps(dump, indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
        print(f"Wrote {len(words)} coefficient(s) to {args.output}.")
    else:
        print(rendered)

    return 0


def run_write_preset(args: argparse.Namespace) -> int:
    overrides = parse_assignments(args.assignments) if args.assignments else {}
    entries = load_preset_entries(args.input, args.input_values, overrides)

    with open_client(args) as client:
        for entry in entries:
            client.write_block(entry.controller, entry.bank, 0, entry.words)
            print(
                f"Wrote preset controller {entry.controller} ({CONTROLLER_LABELS[entry.controller]}) "
                f"to bank {entry.bank}."
            )

        if not args.no_verify:
            for entry in entries:
                readback = client.read_block(entry.controller, entry.bank, 0, len(entry.words))
                if readback != entry.words:
                    mismatch = first_mismatch(entry.words, readback)
                    raise RuntimeError(
                        "Readback mismatch in preset at controller "
                        f"{entry.controller}, bank index {mismatch}: wrote {entry.words[mismatch]}, "
                        f"read {readback[mismatch]}"
                    )
            print("Preset readback verification passed.")

        status = client.get_status()
        print("Preset coefficients loaded. The supervisor selects the active bank.")

    emit_status(status, as_json=args.json)
    return 0


def run_export_defaults(args: argparse.Namespace) -> int:
    validate_bank(args.bank)
    fl, controller_words = parse_default_pkg_words(args.pkg)

    document = {
        "format": "ss-coeff-preset-v1",
        "source_pkg": str(args.pkg),
        "fractional_bits": fl,
        "value_format": args.output_values,
        "controllers": [
            build_preset_entry(index, args.bank, words, args.output_values, 1 << fl)
            for index, words in enumerate(controller_words)
        ],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote default preset for {len(controller_words)} controllers to {args.output}.")
    return 0


def run_poc_alpha(args: argparse.Namespace) -> int:
    requested = str(args.poc_alpha).strip()
    if any(ch in requested for ch in (".", "e", "E")):
        frac = float(requested)
        if frac < 0.0 or frac > 1.0:
            raise ValueError("--poc-alpha float must be in [0,1].")
        level = int(round(frac * 255.0))
    else:
        level = int(requested, 0)
        if level < 0 or level > 255:
            raise ValueError("--poc-alpha integer must be in [0,255].")

    with open_client(args) as client:
        applied = client.set_poc_alpha(level)

    print(
        "PoC alpha set: "
        f"requested={level}/255 ({level/255.0:.3f}) "
        f"applied={applied}/255 ({applied/255.0:.3f})"
    )
    return 0


def run_poc_selftest(args: argparse.Namespace) -> int:
    validate_bank(args.bank)
    if args.active_controller < 0 or args.active_controller >= SS_CTRL_COUNT:
        raise ValueError(f"--active-controller out of range: 0..{SS_CTRL_COUNT - 1}")
    if args.inactive_controller < 0 or args.inactive_controller >= SS_CTRL_COUNT:
        raise ValueError(f"--inactive-controller out of range: 0..{SS_CTRL_COUNT - 1}")
    if args.active_controller == args.inactive_controller:
        raise ValueError("--active-controller and --inactive-controller must be different")

    ok = True
    failures: list[str] = []

    with open_client(args) as client:
        # 1) Verify PoC alpha command path echoes requested state.
        applied0 = client.set_poc_alpha(0)
        applied1 = client.set_poc_alpha(255)

        if applied0 != 0:
            ok = False
            failures.append("alpha path: expected applied=0 for request 0")
        if applied1 != 255:
            ok = False
            failures.append("alpha path: expected applied=255 for request 255")

        # 2) Verify K-vector layout for PoC dummy setup.
        k_active = client.read_block(args.active_controller, args.bank, SS_K_BASE, SS_K_COUNT)
        k_inactive = client.read_block(args.inactive_controller, args.bank, SS_K_BASE, SS_K_COUNT)

        k_active_nonzero = sum(1 for w in k_active if w != 0)
        k_inactive_nonzero = sum(1 for w in k_inactive if w != 0)

        if k_active_nonzero == 0:
            ok = False
            failures.append(
                f"controller {args.active_controller} K-vector is all zero; expected non-zero for PoC dummy"
            )
        if k_inactive_nonzero != 0:
            ok = False
            failures.append(
                f"controller {args.inactive_controller} K-vector has non-zero entries; expected all zero"
            )

        print(
            "PoC selftest details: "
            f"alpha0={applied0}/255 "
            f"alpha1={applied1}/255 "
            f"k{args.active_controller}_nonzero={k_active_nonzero}/{SS_K_COUNT} "
            f"k{args.inactive_controller}_nonzero={k_inactive_nonzero}/{SS_K_COUNT}"
        )

    if ok:
        print("PASS: PoC selftest")
        return 0

    print("FAIL: PoC selftest")
    for failure in failures:
        print(f"  - {failure}")
    return 2


def open_client(args: argparse.Namespace) -> CoeffClient:
    if not args.port:
        raise ValueError("--port is required for device commands.")
    try:
        return CoeffClient(port=args.port, baud=args.baud, timeout=args.timeout)
    except SerialException as exc:
        raise RuntimeError(f"Could not open serial port {args.port}: {exc}") from exc


def frame_checksum(command: int, sequence: int, payload: bytes) -> int:
    checksum = command ^ sequence ^ (len(payload) & 0xFF) ^ ((len(payload) >> 8) & 0xFF)
    for byte in payload:
        checksum ^= byte
    return checksum


def build_frame(command: int, sequence: int, payload: bytes) -> bytes:
    return (
        bytes([UART_SYNC0, UART_SYNC1, command, sequence])
        + struct.pack("<H", len(payload))
        + payload
        + bytes([frame_checksum(command, sequence, payload)])
    )


def parse_controller(value: str) -> int:
    normalized = value.strip().lower()
    if normalized not in CONTROLLER_ALIASES:
        valid = ", ".join(CONTROLLER_LABELS)
        raise ValueError(
            f"Unknown controller '{value}'. Use 0..{SS_CTRL_COUNT - 1} or one of: {valid}."
        )
    return CONTROLLER_ALIASES[normalized]


def parse_assignments(values: list[str]) -> dict[int, int]:
    assignments: dict[int, int] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"Invalid assignment '{value}'. Expected CTRL=BANK.")
        controller_text, bank_text = value.split("=", 1)
        controller = parse_controller(controller_text)
        bank = int(bank_text, 0)
        validate_bank(bank)
        assignments[controller] = bank
    return assignments


def validate_bank(bank: int) -> None:
    if bank < 0 or bank >= SS_BANK_COUNT:
        raise ValueError(f"Bank {bank} out of range. Expected 0..{SS_BANK_COUNT - 1}.")


def validate_bank_window(start_index: int, count: int) -> None:
    if count <= 0:
        raise ValueError("Count must be greater than zero.")
    if start_index < 0 or start_index >= SS_COEFFS_PER_BANK:
        raise ValueError(f"Start index {start_index} out of range. Expected 0..{SS_COEFFS_PER_BANK - 1}.")
    if start_index + count > SS_COEFFS_PER_BANK:
        raise ValueError(
            f"Coefficient window [{start_index}, {start_index + count}) exceeds bank size {SS_COEFFS_PER_BANK}."
        )


def load_coeff_words(path: Path, input_values: str) -> list[int]:
    if not path.exists():
        raise FileNotFoundError(f"Input file not found: {path}")

    if path.suffix.lower() == ".json":
        source = json.loads(path.read_text(encoding="utf-8-sig"))
        values = flatten_json_values(source)
    else:
        values = parse_text_values(path.read_text(encoding="utf-8-sig"))

    words = [coerce_q22_word(value, input_values) for value in values]
    return words


def load_preset_entries(
    path: Path,
    input_values: str,
    bank_overrides: dict[int, int],
) -> list[PresetEntry]:
    if not path.exists():
        raise FileNotFoundError(f"Preset file not found: {path}")

    source = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(source, dict):
        raise ValueError("Preset JSON must be an object with a 'controllers' field.")

    controllers = source.get("controllers")
    if controllers is None:
        raise ValueError("Preset JSON must contain a 'controllers' field.")

    entries: list[PresetEntry] = []
    seen_controllers: set[int] = set()

    for controller_key, controller_node in iter_preset_controllers(controllers):
        if not isinstance(controller_node, dict):
            raise ValueError("Each preset controller entry must be an object.")

        controller_ref = controller_node.get("controller")
        if controller_ref is None:
            controller_ref = controller_node.get("name")
        if controller_ref is None:
            controller_ref = controller_key
        if controller_ref is None:
            raise ValueError("Each preset controller entry must identify the target controller.")

        controller = parse_controller(str(controller_ref))
        if controller in seen_controllers:
            raise ValueError(f"Preset contains duplicate controller entry for {controller}.")
        seen_controllers.add(controller)

        if controller in bank_overrides:
            bank = bank_overrides[controller]
        elif "bank" in controller_node:
            bank = parse_int_value(controller_node["bank"], "bank")
        else:
            raise ValueError(
                f"Preset controller {controller} does not specify a bank. Add 'bank' or use --set CTRL=BANK."
            )
        validate_bank(bank)

        words = [coerce_q22_word(value, input_values) for value in flatten_json_values(controller_node)]
        if len(words) != SS_COEFFS_PER_BANK:
            raise ValueError(
                f"Preset controller {controller} contains {len(words)} coefficients, expected {SS_COEFFS_PER_BANK}."
            )
        entries.append(PresetEntry(controller=controller, bank=bank, words=words))

    if not entries:
        raise ValueError("Preset does not contain any controllers.")

    entries.sort(key=lambda entry: entry.controller)
    return entries


def iter_preset_controllers(controllers: object) -> list[tuple[str | None, object]]:
    if isinstance(controllers, list):
        return [(None, item) for item in controllers]
    if isinstance(controllers, dict):
        return [(str(key), value) for key, value in controllers.items()]
    raise ValueError("Preset field 'controllers' must be a list or object.")


def flatten_json_values(source: object) -> list[object]:
    if isinstance(source, list):
        return list(source)

    if not isinstance(source, dict):
        raise ValueError("JSON input must be a list or object.")

    fields = {str(key).lower(): value for key, value in source.items()}
    if "coefficients" in fields:
        coefficients = fields["coefficients"]
        if not isinstance(coefficients, list):
            raise ValueError("JSON field 'coefficients' must be a list.")
        return list(coefficients)

    required = ("a", "b", "c", "d")
    if all(field in fields for field in required):
        a_vals = ensure_list(fields["a"], "a")
        b_vals = ensure_list(fields["b"], "b")
        c_vals = ensure_list(fields["c"], "c")
        d_value = fields["d"]
        d_vals = ensure_list(d_value, "d") if isinstance(d_value, list) else [d_value]

        if len(a_vals) != SS_A_COUNT:
            raise ValueError(f"JSON field 'a' must contain {SS_A_COUNT} values.")
        if len(b_vals) != SS_B_COUNT:
            raise ValueError(f"JSON field 'b' must contain {SS_B_COUNT} values.")
        if len(c_vals) != SS_C_COUNT:
            raise ValueError(f"JSON field 'c' must contain {SS_C_COUNT} values.")
        if len(d_vals) != SS_D_COUNT:
            raise ValueError("JSON field 'd' must contain exactly one value.")

        return [*a_vals, *b_vals, *c_vals, *d_vals]

    raise ValueError("JSON input must contain 'coefficients' or the full A/B/C/D structure.")


def parse_default_pkg_words(pkg_path: Path) -> tuple[int, list[list[int]]]:
    if not pkg_path.exists():
        raise FileNotFoundError(f"Package file not found: {pkg_path}")

    text = pkg_path.read_text(encoding="utf-8", errors="replace")
    wl = parse_pkg_int_constant(text, "WL")
    fl = parse_pkg_int_constant(text, "FL")
    n = parse_pkg_int_constant(text, "N")
    expected_total = (n * n) + n + n + 1

    if expected_total != SS_COEFFS_PER_BANK:
        raise ValueError(
            f"Package N={n} implies {expected_total} coefficients per controller, expected {SS_COEFFS_PER_BANK}."
        )
    if wl != 24:
        raise ValueError(f"Package WL={wl} is not supported by this uploader. Expected 24.")

    controllers: list[list[int]] = []
    for index in range(1, SS_CTRL_COUNT + 1):
        a_vals = parse_pkg_array_words(text, f"A{index}")
        b_vals = parse_pkg_array_words(text, f"B{index}")
        c_vals = parse_pkg_array_words(text, f"C{index}")
        d_val = parse_pkg_scalar_word(text, f"D{index}")

        if len(a_vals) != n * n:
            raise ValueError(f"A{index} contains {len(a_vals)} coefficients, expected {n * n}.")
        if len(b_vals) != n:
            raise ValueError(f"B{index} contains {len(b_vals)} coefficients, expected {n}.")
        if len(c_vals) != n:
            raise ValueError(f"C{index} contains {len(c_vals)} coefficients, expected {n}.")

        controllers.append([*a_vals, *b_vals, *c_vals, d_val])

    return fl, controllers


def parse_pkg_int_constant(text: str, name: str) -> int:
    match = re.search(rf"constant\s+{re.escape(name)}\s*:\s*integer\s*:=\s*(\d+)\s*;", text)
    if not match:
        raise ValueError(f"Could not locate integer constant {name} in audiodsp_pkg.vhd.")
    return int(match.group(1))


def parse_pkg_array_words(text: str, name: str) -> list[int]:
    body = parse_pkg_constant_body(text, name)
    return [int(value) for value in re.findall(r"to_signed\((-?\d+),\s*\d+\)", body)]


def parse_pkg_scalar_word(text: str, name: str) -> int:
    match = re.search(
        rf"constant\s+{re.escape(name)}\s*:\s*signed\([^\)]*\)\s*:=\s*to_signed\((-?\d+),\s*\d+\)\s*;",
        text,
    )
    if not match:
        raise ValueError(f"Could not locate scalar constant {name} in audiodsp_pkg.vhd.")
    return int(match.group(1))


def parse_pkg_constant_body(text: str, name: str) -> str:
    match = re.search(
        rf"constant\s+{re.escape(name)}\s*:\s*.*?\s*:=\s*\((.*?)\)\s*;",
        text,
        re.S,
    )
    if not match:
        raise ValueError(f"Could not locate constant body for {name} in audiodsp_pkg.vhd.")
    return match.group(1)


def ensure_list(value: object, field_name: str) -> list[object]:
    if not isinstance(value, list):
        raise ValueError(f"JSON field '{field_name}' must be a list.")
    return list(value)


def parse_text_values(text: str) -> list[object]:
    tokens = [token for token in re.split(r"[\s,;]+", text) if token]
    if not tokens:
        raise ValueError("Input file does not contain any coefficients.")
    return [parse_numeric_token(token) for token in tokens]


def parse_numeric_token(token: str) -> object:
    if any(marker in token for marker in (".", "e", "E")):
        return float(token)
    return int(token, 0)


def parse_int_value(value: object, field_name: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"Field '{field_name}' must be an integer.")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        return int(value, 0)
    raise ValueError(f"Field '{field_name}' must be an integer.")


def coerce_q22_word(value: object, mode: str) -> int:
    if isinstance(value, bool):
        raise ValueError("Boolean coefficient values are not supported.")

    numeric: int | float
    if isinstance(value, (int, float)):
        numeric = value
    elif isinstance(value, str):
        numeric = parse_numeric_token(value)
    else:
        raise ValueError(f"Unsupported coefficient value type: {type(value).__name__}")

    if mode == "float":
        word = int(round(float(numeric) * Q22_SCALE))
    elif mode == "q22":
        if isinstance(numeric, float) and not numeric.is_integer():
            raise ValueError(f"Non-integer raw Q22 value '{numeric}'")
        word = int(round(float(numeric)))
    else:
        if isinstance(numeric, float):
            word = int(round(numeric * Q22_SCALE))
        else:
            word = int(numeric)

    if word < Q22_MIN or word > Q22_MAX:
        raise ValueError(f"Coefficient word {word} outside signed Q22 range [{Q22_MIN}, {Q22_MAX}].")
    return word


def build_bank_dump(
    controller: int,
    bank: int,
    start_index: int,
    words: list[int],
    output_values: str,
) -> dict[str, object]:
    values = render_words(words, output_values)
    dump: dict[str, object] = {
        "controller": controller,
        "controller_name": CONTROLLER_LABELS[controller],
        "bank": bank,
        "start_index": start_index,
        "count": len(words),
        "value_format": output_values,
        "coefficients": values,
        "raw_words": words,
    }

    if start_index == 0 and len(words) == SS_COEFFS_PER_BANK:
        dump["a"] = values[0:SS_A_COUNT]
        dump["b"] = values[SS_A_COUNT : SS_A_COUNT + SS_B_COUNT]
        dump["c"] = values[SS_A_COUNT + SS_B_COUNT : SS_A_COUNT + SS_B_COUNT + SS_C_COUNT]
        dump["d"] = values[-1]

    return dump


def build_preset_entry(
    controller: int,
    bank: int,
    words: list[int],
    output_values: str,
    scale: int,
) -> dict[str, object]:
    values = render_words(words, output_values, scale)
    return {
        "controller": controller,
        "name": CONTROLLER_LABELS[controller],
        "bank": bank,
        "a": values[0:SS_A_COUNT],
        "b": values[SS_A_COUNT : SS_A_COUNT + SS_B_COUNT],
        "c": values[SS_A_COUNT + SS_B_COUNT : SS_A_COUNT + SS_B_COUNT + SS_C_COUNT],
        "d": values[-1],
    }


def render_words(words: list[int], output_values: str, scale: int = Q22_SCALE) -> list[float] | list[int]:
    if output_values == "q22":
        return list(words)
    return [word / scale for word in words]


def unpack_bank_fields(packed_value: int) -> tuple[int, ...]:
    return tuple((packed_value >> (index * 3)) & 0x7 for index in range(SS_CTRL_COUNT))


def emit_status(status: DeviceStatus, as_json: bool) -> None:
    if as_json:
        print(json.dumps(status.to_dict(), indent=2))
        return

    for index, name in enumerate(CONTROLLER_LABELS):
        busy = "yes" if (status.busy_mask & (1 << index)) else "no"
        print(
            f"ctrl {index} ({name}): active={status.active[index]} "
            f"pending={status.pending[index]} shadow={status.shadow_pending[index]} busy={busy}"
        )


def first_mismatch(expected: list[int], actual: list[int]) -> int:
    for index, (lhs, rhs) in enumerate(zip(expected, actual)):
        if lhs != rhs:
            return index
    return -1


def status_name(status: int) -> str:
    return STATUS_NAMES.get(status, "unknown-status")


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    try:
        return int(args.func(args))
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())