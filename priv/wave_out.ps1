param([Parameter(Mandatory = $true)][int]$Port)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WaveBridge
{
    const uint Done = 1;
    static Stream Input;
    static Stream Output;
    static readonly BlockingCollection<byte[]> Messages = new BlockingCollection<byte[]>();

    [StructLayout(LayoutKind.Sequential)]
    struct Format {
        public ushort tag, channels;
        public uint rate, bytesPerSecond;
        public ushort blockAlign, bits, extra;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Header {
        public IntPtr data;
        public uint length, recorded;
        public IntPtr user;
        public uint flags, loops;
        public IntPtr next, reserved;
    }

    sealed class Slot { public IntPtr data, header; public bool active; }

    [DllImport("winmm.dll")]
    static extern uint waveOutOpen(out IntPtr handle, UIntPtr device, ref Format format,
                                   IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")]
    static extern uint waveOutPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")]
    static extern uint waveOutWrite(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")]
    static extern uint waveOutUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")]
    static extern uint waveOutReset(IntPtr handle);
    [DllImport("winmm.dll")]
    static extern uint waveOutClose(IntPtr handle);

    public static void Run(int port)
    {
        IntPtr wave = IntPtr.Zero;
        TcpClient client = new TcpClient();
        Slot[] slots = { new Slot(), new Slot(), new Slot(), new Slot() };
        try {
            client.Connect(IPAddress.Loopback, port);
            Input = Output = client.GetStream();
            Format format = new Format { tag = 1, channels = 1, rate = 44100,
                bytesPerSecond = 88200, blockAlign = 2, bits = 16, extra = 0 };
            Check(waveOutOpen(out wave, new UIntPtr(0xffffffff), ref format,
                              IntPtr.Zero, IntPtr.Zero, 0), "waveOutOpen");

            new Thread(ReadMessages) { IsBackground = true }.Start();
            foreach (Slot slot in slots) WriteFrame(new byte[] { (byte)'R' });

            bool ending = false;
            while (true) {
                foreach (Slot slot in slots) {
                    if (!slot.active) continue;
                    Header header = (Header)Marshal.PtrToStructure(slot.header, typeof(Header));
                    if ((header.flags & Done) == 0) continue;
                    Check(waveOutUnprepareHeader(wave, slot.header,
                                                (uint)Marshal.SizeOf(typeof(Header))),
                          "waveOutUnprepareHeader");
                    Marshal.FreeHGlobal(slot.header);
                    Marshal.FreeHGlobal(slot.data);
                    slot.header = slot.data = IntPtr.Zero;
                    slot.active = false;
                    WriteFrame(new byte[] { (byte)'R' });
                }

                bool active = false;
                foreach (Slot slot in slots) active |= slot.active;
                if (ending && !active) { WriteFrame(new byte[] { (byte)'D' }); break; }

                byte[] message;
                if (!Messages.TryTake(out message, 3)) continue;
                if (message.Length == 0) throw new EndOfStreamException();
                if (message[0] == (byte)'E') { ending = true; continue; }
                if (message[0] != (byte)'A') throw new InvalidDataException("bad command");

                Slot free = Array.Find(slots, delegate(Slot slot) { return !slot.active; });
                if (free == null) throw new InvalidDataException("audio without credit");
                int length = message.Length - 1;
                free.data = Marshal.AllocHGlobal(length);
                Marshal.Copy(message, 1, free.data, length);
                Header h = new Header { data = free.data, length = (uint)length };
                free.header = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Header)));
                Marshal.StructureToPtr(h, free.header, false);
                Check(waveOutPrepareHeader(wave, free.header,
                                           (uint)Marshal.SizeOf(typeof(Header))),
                      "waveOutPrepareHeader");
                Check(waveOutWrite(wave, free.header, (uint)Marshal.SizeOf(typeof(Header))),
                      "waveOutWrite");
                free.active = true;
            }
        }
        catch (Exception error) {
            try { WriteFrame(Join((byte)'X', Encoding.UTF8.GetBytes(error.Message))); }
            catch { }
        }
        finally {
            if (wave != IntPtr.Zero) {
                waveOutReset(wave);
                Thread.Sleep(10);
                foreach (Slot slot in slots) {
                    if (slot.header != IntPtr.Zero) {
                        waveOutUnprepareHeader(wave, slot.header,
                                               (uint)Marshal.SizeOf(typeof(Header)));
                        Marshal.FreeHGlobal(slot.header);
                    }
                    if (slot.data != IntPtr.Zero) Marshal.FreeHGlobal(slot.data);
                }
                waveOutClose(wave);
            }
            client.Close();
        }
    }

    static void ReadMessages()
    {
        try { while (true) Messages.Add(ReadFrame()); }
        catch { Messages.Add(new byte[0]); }
    }

    static byte[] ReadFrame()
    {
        byte[] head = Read(4);
        int size = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        if (size < 1 || size > 1048576) throw new InvalidDataException("bad frame");
        return Read(size);
    }

    static byte[] Read(int size)
    {
        byte[] bytes = new byte[size];
        int offset = 0;
        while (offset < size) {
            int count = Input.Read(bytes, offset, size - offset);
            if (count == 0) throw new EndOfStreamException();
            offset += count;
        }
        return bytes;
    }

    static void WriteFrame(byte[] message)
    {
        int n = message.Length;
        byte[] head = { (byte)(n >> 24), (byte)(n >> 16), (byte)(n >> 8), (byte)n };
        Output.Write(head, 0, head.Length);
        Output.Write(message, 0, message.Length);
        Output.Flush();
    }

    static byte[] Join(byte first, byte[] rest)
    {
        byte[] result = new byte[rest.Length + 1];
        result[0] = first;
        Buffer.BlockCopy(rest, 0, result, 1, rest.Length);
        return result;
    }

    static void Check(uint result, string operation)
    {
        if (result != 0) throw new InvalidOperationException(operation + " failed: " + result);
    }
}
'@

[WaveBridge]::Run($Port)
