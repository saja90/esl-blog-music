#!/usr/bin/env python3
"""Linux audio bridge speaking the same protocol as wave_out.ps1.

Frames: 4-byte big-endian length + payload.
  Erlang -> bridge: b'A' + PCM (s16le, mono, 44100 Hz) | b'E' (end of stream)
  bridge -> Erlang: b'R' (one buffer credit) | b'D' (drained) | b'X' + error text
"""
import shutil
import socket
import struct
import subprocess
import sys

CREDITS = 4
MAX_FRAME = 1048576
PLAYERS = [
    ["pacat", "--playback", "--raw", "--format=s16le", "--channels=1", "--rate=44100"],
    ["aplay", "-q", "-t", "raw", "-f", "S16_LE", "-c", "1", "-r", "44100", "-"],
]


def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed")
        buf += chunk
    return bytes(buf)


def read_frame(sock):
    (size,) = struct.unpack(">I", read_exact(sock, 4))
    if size < 1 or size > MAX_FRAME:
        raise ValueError("bad frame")
    return read_exact(sock, size)


def write_frame(sock, payload):
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def start_player():
    for cmd in PLAYERS:
        if shutil.which(cmd[0]):
            return subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    raise RuntimeError("no audio player found (need pacat or aplay)")


def main():
    port = int(sys.argv[-1])
    sock = socket.create_connection(("127.0.0.1", port))
    player = None
    try:
        player = start_player()
        credits = CREDITS
        for _ in range(CREDITS):
            write_frame(sock, b"R")
        while True:
            msg = read_frame(sock)
            cmd = msg[:1]
            if cmd == b"A":
                if credits == 0:
                    raise ValueError("audio without credit")
                credits -= 1
                player.stdin.write(msg[1:])   # blocks when the pipe is full -> backpressure
                player.stdin.flush()
                credits += 1
                write_frame(sock, b"R")
            elif cmd == b"E":
                player.stdin.close()          # let the player drain what's buffered
                status = player.wait()
                player = None
                if status != 0:
                    raise RuntimeError("audio player exited with %d" % status)
                write_frame(sock, b"D")
                return
            else:
                raise ValueError("bad command")
    except Exception as error:
        try:
            write_frame(sock, b"X" + str(error).encode("utf-8"))
        except OSError:
            pass
    finally:
        if player is not None:                # abnormal exit: stop sound immediately
            player.kill()
            player.wait()
        sock.close()


if __name__ == "__main__":
    main()
