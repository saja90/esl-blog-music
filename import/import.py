#!/usr/bin/env python3
"""Convert Standard MIDI files into Erlang song modules.

The importer deliberately uses only Python's standard library.  By default it
reads every ``.mid`` file from ``import/input`` and writes generated modules to
``import/output``.  Use ``--output src`` when the modules should be compiled as
part of the application.
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import struct
import sys
from collections import defaultdict, deque
from pathlib import Path
from typing import Iterable


DEFAULT_TEMPO = 500_000  # microseconds per quarter note (120 BPM)


class MidiError(ValueError):
    """Raised for an invalid or unsupported MIDI file."""


@dataclasses.dataclass(frozen=True)
class MidiEvent:
    tick: int
    track: int
    order: int
    kind: str
    channel: int | None = None
    first: int | None = None
    second: int | None = None
    data: bytes = b""


@dataclasses.dataclass(frozen=True)
class Note:
    start_tick: int
    end_tick: int
    track: int
    channel: int
    pitch: int
    program: int


@dataclasses.dataclass
class MidiSong:
    ticks_per_beat: int
    tempos: list[tuple[int, int]]
    notes: list[Note]


def read_u32(data: bytes, offset: int) -> tuple[int, int]:
    if offset + 4 > len(data):
        raise MidiError("unexpected end of file")
    return struct.unpack_from(">I", data, offset)[0], offset + 4


def read_vlq(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for _ in range(4):
        if offset >= len(data):
            raise MidiError("truncated variable-length value")
        byte = data[offset]
        offset += 1
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            return value, offset
    raise MidiError("variable-length value is longer than four bytes")


def parse_track(data: bytes, track: int) -> list[MidiEvent]:
    events: list[MidiEvent] = []
    offset = 0
    tick = 0
    running_status: int | None = None
    order = 0

    while offset < len(data):
        delta, offset = read_vlq(data, offset)
        tick += delta
        if offset >= len(data):
            raise MidiError(f"track {track + 1}: missing event after delta time")

        byte = data[offset]
        if byte & 0x80:
            status = byte
            offset += 1
            if status < 0xF0:
                running_status = status
        elif running_status is not None:
            status = running_status
        else:
            raise MidiError(f"track {track + 1}: data byte without running status")

        if status == 0xFF:
            running_status = None
            if offset >= len(data):
                raise MidiError(f"track {track + 1}: truncated meta event")
            meta_type = data[offset]
            offset += 1
            length, offset = read_vlq(data, offset)
            if offset + length > len(data):
                raise MidiError(f"track {track + 1}: truncated meta event data")
            payload = data[offset : offset + length]
            offset += length
            kind = "tempo" if meta_type == 0x51 else "track_name" if meta_type == 0x03 else "meta"
            events.append(MidiEvent(tick, track, order, kind, first=meta_type, data=payload))
            order += 1
            if meta_type == 0x2F:
                break
            continue

        if status in (0xF0, 0xF7):
            running_status = None
            length, offset = read_vlq(data, offset)
            if offset + length > len(data):
                raise MidiError(f"track {track + 1}: truncated SysEx event")
            offset += length
            continue

        event_type = status >> 4
        channel = status & 0x0F
        size = 1 if event_type in (0xC, 0xD) else 2
        if event_type < 0x8 or event_type > 0xE or offset + size > len(data):
            raise MidiError(f"track {track + 1}: invalid channel event 0x{status:02x}")
        first = data[offset]
        second = data[offset + 1] if size == 2 else None
        offset += size
        kind = {
            0x8: "note_off",
            0x9: "note_on" if second else "note_off",
            0xB: "control",
            0xC: "program",
        }.get(event_type, "channel")
        events.append(MidiEvent(tick, track, order, kind, channel, first, second))
        order += 1

    return events


def parse_midi(path: Path) -> MidiSong:
    data = path.read_bytes()
    if len(data) < 14 or data[:4] != b"MThd":
        raise MidiError("missing MIDI header")
    header_size = struct.unpack_from(">I", data, 4)[0]
    if header_size < 6 or 8 + header_size > len(data):
        raise MidiError("invalid MIDI header length")
    midi_format, track_count, division = struct.unpack_from(">HHH", data, 8)
    if midi_format not in (0, 1):
        raise MidiError(f"MIDI format {midi_format} is not supported")
    if division & 0x8000:
        raise MidiError("SMPTE time division is not supported")
    if division == 0:
        raise MidiError("ticks per beat cannot be zero")

    offset = 8 + header_size
    all_events: list[MidiEvent] = []
    for track in range(track_count):
        if offset + 8 > len(data) or data[offset : offset + 4] != b"MTrk":
            raise MidiError(f"missing track chunk {track + 1}")
        size, payload_offset = read_u32(data, offset + 4)
        offset = payload_offset
        if offset + size > len(data):
            raise MidiError(f"track {track + 1} extends past end of file")
        all_events.extend(parse_track(data[offset : offset + size], track))
        offset += size

    tempos: list[tuple[int, int]] = []
    for event in all_events:
        if event.kind == "tempo" and len(event.data) == 3:
            tempo = int.from_bytes(event.data, "big")
            if tempo:
                tempos.append((event.tick, tempo))

    # Merge tracks before interpreting program changes: MIDI channels are global.
    all_events.sort(key=lambda event: (event.tick, event.track, event.order))
    programs = [0] * 16
    active: dict[tuple[int, int, int], deque[tuple[int, int]]] = defaultdict(deque)
    notes: list[Note] = []
    last_tick = 0
    for event in all_events:
        last_tick = max(last_tick, event.tick)
        if event.kind == "program" and event.channel is not None and event.first is not None:
            programs[event.channel] = event.first
        elif event.kind == "note_on" and event.channel is not None:
            key = (event.track, event.channel, int(event.first))
            active[key].append((event.tick, programs[event.channel]))
        elif event.kind == "note_off" and event.channel is not None:
            key = (event.track, event.channel, int(event.first))
            if active[key]:
                start, program = active[key].popleft()
                if event.tick > start:
                    notes.append(Note(start, event.tick, event.track, event.channel,
                                      int(event.first), program))

    # A malformed but playable file may omit final note-off events. Give such notes
    # one quarter note, capped by the end of the track collection when possible.
    for (track, channel, pitch), starts in active.items():
        for start, program in starts:
            end = max(start + division, last_tick)
            notes.append(Note(start, end, track, channel, pitch, program))

    # At a shared tick the first tempo encountered wins. MIDI defaults to 120 BPM.
    tempo_by_tick = {0: DEFAULT_TEMPO}
    for tick, tempo in sorted(tempos):
        tempo_by_tick[tick] = tempo
    return MidiSong(division, sorted(tempo_by_tick.items()),
                    sorted(notes, key=lambda n: (n.start_tick, n.track, n.pitch)))


def tick_seconds(song: MidiSong, tick: int) -> float:
    elapsed = 0.0
    previous_tick = 0
    tempo = DEFAULT_TEMPO
    for change_tick, new_tempo in song.tempos:
        if change_tick > tick:
            break
        elapsed += (change_tick - previous_tick) * tempo / 1_000_000 / song.ticks_per_beat
        previous_tick = change_tick
        tempo = new_tempo
    return elapsed + (tick - previous_tick) * tempo / 1_000_000 / song.ticks_per_beat


def program_preset(program: int) -> str:
    if program < 16:
        return "piano"
    if program < 24:
        return "organ"
    if program < 32:
        return "guitar"
    if program < 40:
        return "bass"
    if program < 56:
        return "strings"
    if program < 64:
        return "brass"
    if program < 88:
        return "lead"
    if program < 104:
        return "pad"
    return "lead"


def percussion_preset(note: int) -> str:
    if note in (35, 36):
        return "kick"
    if note in (41, 43, 45, 47, 48, 50):
        return "tom"
    if note in (42, 44, 46):
        return "closed_hat"
    if note in (49, 51, 52, 53, 55, 57, 59):
        return "cymbal"
    return "snare"


def midi_note_atom(note: int) -> str:
    names = ("c", "cs", "d", "ds", "e", "f", "fs", "g", "gs", "a", "as", "b")
    return f"{names[note % 12]}{note // 12 - 1}"


def atom_name(text: str, fallback: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_") or fallback
    if value[0].isdigit():
        value = f"song_{value}"
    return value


def number(value: float, places: int = 6) -> str:
    rounded = round(value, places)
    if abs(rounded - round(rounded)) < 10 ** (-places):
        return str(int(round(rounded)))
    return f"{rounded:.{places}f}".rstrip("0").rstrip(".")


def render_module(path: Path, song: MidiSong, module_name: str | None = None) -> str:
    module = module_name or atom_name(path.stem.removesuffix(" Midi").removesuffix(" midi"), "midi_song")
    first_tempo = song.tempos[0][1] if song.tempos else DEFAULT_TEMPO
    bpm = 60_000_000 / first_tempo
    # MIDI tempo is integral microseconds, so common whole BPM values often
    # decode as e.g. 140.00014. Keep generated modules pleasant to edit.
    if abs(bpm - round(bpm)) < 0.01:
        bpm = float(round(bpm))

    grouped: dict[tuple[int, int, str], list[tuple[float, float, int]]] = defaultdict(list)
    for note in song.notes:
        preset = percussion_preset(note.pitch) if note.channel == 9 else program_preset(note.program)
        start = tick_seconds(song, note.start_tick) * bpm / 60
        end = tick_seconds(song, note.end_tick) * bpm / 60
        grouped[(note.track, note.channel, preset)].append(
            (start, max(end - start, 0.001), note.pitch))

    tracks: list[tuple[str, list[str]]] = []
    for (track_index, _channel, preset), values in sorted(grouped.items()):
        events: list[str] = []
        if preset in {"kick", "snare", "closed_hat", "tom", "cymbal"}:
            for start, _duration, _pitch in values:
                events.append(number(start))
        else:
            chords: dict[tuple[float, float], list[int]] = defaultdict(list)
            for start, duration, pitch in values:
                chords[(start, duration)].append(pitch)
            for (start, duration), pitches in sorted(chords.items()):
                atoms = [midi_note_atom(pitch) for pitch in sorted(pitches)]
                notes = atoms[0] if len(atoms) == 1 else "{" + ", ".join(atoms) + "}"
                events.append(f"{{{number(start)}, {number(duration)}, {notes}}}")
        tracks.append((preset, events))

    track_lines = []
    for preset, events in tracks:
        if not events:
            track_lines.append(f"        {{{preset}, []}}")
            continue
        wrapped = []
        line = ""
        for event in events:
            candidate = event if not line else f"{line}, {event}"
            if len(candidate) > 92:
                wrapped.append(line)
                line = event
            else:
                line = candidate
        if line:
            wrapped.append(line)
        body = (",\n" + " " * (len(preset) + 12)).join(wrapped)
        track_lines.append(f"        {{{preset}, [{body}]}}")

    rendered_tracks = ",\n".join(track_lines)
    return (
        f"%% Generated from {path.name} by import/import.py.\n"
        f"-module({module}).\n"
        "-export([bpm/0, tracks/0]).\n\n"
        f"bpm() -> {number(bpm, 4)}.\n\n"
        "tracks() ->\n"
        f"    [\n{rendered_tracks}\n    ].\n"
    )


def midi_files(input_path: Path) -> Iterable[Path]:
    if input_path.is_file():
        if input_path.suffix.lower() not in (".mid", ".midi"):
            raise MidiError(f"not a MIDI filename: {input_path}")
        return [input_path]
    if not input_path.is_dir():
        raise MidiError(f"input path does not exist: {input_path}")
    return sorted((path for path in input_path.iterdir()
                   if path.is_file() and path.suffix.lower() in (".mid", ".midi")),
                  key=lambda path: path.name.lower())


def build_parser(script_dir: Path) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=script_dir / "input",
                        help="MIDI file or directory (default: import/input)")
    parser.add_argument("--output", type=Path, default=script_dir / "output",
                        help="generated module directory (default: import/output)")
    parser.add_argument("--overwrite", action="store_true",
                        help="replace existing generated modules")
    parser.add_argument("--check", action="store_true",
                        help="parse and report files without writing modules")
    return parser


def main(argv: list[str] | None = None) -> int:
    script_dir = Path(__file__).resolve().parent
    args = build_parser(script_dir).parse_args(argv)
    try:
        files = list(midi_files(args.input.resolve()))
    except (MidiError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if not files:
        print(f"error: no MIDI files found in {args.input}", file=sys.stderr)
        return 2

    failures = 0
    written = 0
    if not args.check:
        args.output.mkdir(parents=True, exist_ok=True)
    for path in files:
        try:
            song = parse_midi(path)
            module = atom_name(path.stem.removesuffix(" Midi").removesuffix(" midi"), "midi_song")
            destination = args.output / f"{module}.erl"
            if args.check:
                presets = sorted({percussion_preset(note.pitch) if note.channel == 9
                                  else program_preset(note.program) for note in song.notes})
                print(f"OK {path.name}: {len(song.notes)} notes, {len(song.tempos)} tempo point(s), "
                      f"instruments={','.join(presets) or 'none'}")
            elif destination.exists() and not args.overwrite:
                print(f"SKIP {destination} (use --overwrite)")
            else:
                destination.write_text(render_module(path, song, module), encoding="utf-8", newline="\n")
                written += 1
                print(f"WROTE {destination} ({len(song.notes)} notes)")
        except (MidiError, OSError, UnicodeError) as error:
            failures += 1
            print(f"ERROR {path}: {error}", file=sys.stderr)

    if not args.check:
        print(f"Generated {written} module(s); {failures} file(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
