"""Open N keep-alive connections, send one GET /api/tags on each, then hold them idle.

Usage: python3 -I idle_conns.py <port> <n> <hold_seconds>
Prints how many connections completed their request and are still open when the hold ends.
"""
import asyncio
import sys

PORT, N, HOLD = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
REQUEST = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"


async def one(i, opened, sem):
    async with sem:
        reader, writer = await asyncio.open_connection("127.0.0.1", PORT)
        writer.write(REQUEST)
        await writer.drain()
        head = await reader.readuntil(b"\r\n\r\n")
        length = int(next(l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length:")).split(b":")[1])
        await reader.readexactly(length)
        opened.append((reader, writer))


async def main():
    opened, sem = [], asyncio.Semaphore(200)
    results = await asyncio.gather(*(one(i, opened, sem) for i in range(N)), return_exceptions=True)
    errors = [r for r in results if isinstance(r, Exception)]
    print(f"opened {len(opened)} connections, {len(errors)} errors" + (f" (first: {errors[0]!r})" if errors else ""),
          flush=True)
    print("HOLDING", flush=True)
    await asyncio.sleep(HOLD)
    still_open = sum(1 for r, _ in opened if not r.at_eof())
    print(f"after {HOLD:.0f}s idle: {still_open} still open", flush=True)
    for _, w in opened:
        w.close()


asyncio.run(main())
