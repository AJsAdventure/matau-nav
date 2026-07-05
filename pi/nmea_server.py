#!/usr/bin/env python3
"""
Demo NMEA TCP server — more dynamic sailing simulation.
Run on the Pi; SignalK connects as a TCP client on port 10111.
"""
import socket, time, math, random

def checksum(sentence):
    cs = 0
    for c in sentence:
        cs ^= ord(c)
    return f"{cs:02X}"

def nmea(fields):
    body = ",".join(fields)
    return f"${body}*{checksum(body)}\r\n"

def knots_to_ms(k): return k * 0.514444
def ms_to_knots(m): return m / 0.514444

def main():
    HOST, PORT = "0.0.0.0", 10111
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT))
        srv.listen(1)
        print(f"NMEA demo server listening on {PORT}")
        while True:
            conn, addr = srv.accept()
            print(f"Client connected: {addr}")
            with conn:
                t0 = time.time()
                while True:
                    t = (time.time() - t0) % 600      # 10-min looping scenario

                    # --- Heading: meanders with two overlapping periods ---
                    hdg = (47
                           + 14 * math.sin(t / 18)
                           + 6  * math.sin(t / 7.1)
                           + 2  * math.sin(t / 2.3)
                           + random.gauss(0, 0.4)) % 360

                    # --- Boat speed: gusts 4-10 kts ---
                    spd_kts = max(2.5, min(10.5,
                        7.0
                        + 1.8 * math.sin(t / 55)
                        + 0.9 * math.sin(t / 9)
                        + random.gauss(0, 0.15)))
                    spd_ms = knots_to_ms(spd_kts)

                    # --- True wind speed: 8-22 kts with gusts ---
                    tws_kts = max(6, min(24,
                        14
                        + 4  * math.sin(t / 70)
                        + 2  * math.sin(t / 13)
                        + 1  * random.gauss(0, 0.4)))
                    tws_ms = knots_to_ms(tws_kts)

                    # --- True wind angle: tacks between 30-70° S / P ---
                    twa_mag = max(25, min(75,
                        48
                        + 18 * math.sin(t / 30)
                        + 7  * math.sin(t / 8)
                        + random.gauss(0, 0.5)))
                    # Switch tack at t=280-295 each 600s cycle
                    tack = -1 if (280 < t % 600 < 295) else 1
                    twa_rad = math.radians(twa_mag * tack)  # positive = starboard

                    # --- Apparent wind (vector sum) ---
                    # Simplified: awa ≈ twa scaled, aws from vector addition
                    awa_rad = twa_rad * 0.82 + math.radians(random.gauss(0, 0.5))
                    aws_ms  = math.sqrt(
                        tws_ms**2 + spd_ms**2
                        + 2 * tws_ms * spd_ms * math.cos(math.radians(twa_mag))
                    )
                    aws_kts = ms_to_knots(aws_ms)

                    # --- Depth: 20-60 m ---
                    depth_m = max(8, 38 + 12 * math.sin(t / 240) + random.gauss(0, 0.2))

                    # --- Water temperature ---
                    water_c = 22.8 + 0.6 * math.sin(t / 400) + random.gauss(0, 0.05)

                    # --- Rudder: reacts to heading rate of change ---
                    hdg_rate = (14 / 18) * math.cos(t / 18) + (6 / 7.1) * math.cos(t / 7.1)
                    rudder_deg = max(-28, min(28,
                        -3.5 * hdg_rate + random.gauss(0, 0.4)))

                    # --- Position (Malta area, drifting slowly) ---
                    lat = 35.8893 + 0.0015 * math.sin(t / 130)
                    lon = 14.5122 + 0.0020 * math.sin(t / 95)
                    lat_deg = int(abs(lat)); lat_min = (abs(lat) - lat_deg) * 60
                    lon_deg = int(abs(lon)); lon_min = (abs(lon) - lon_deg) * 60
                    lat_hem = "N" if lat >= 0 else "S"
                    lon_hem = "E" if lon >= 0 else "W"

                    sentences = [
                        # Magnetic heading
                        nmea(["HCHDT", f"{hdg:.1f}", "T"]),
                        # Speed through water + heading
                        nmea(["IIVHW",
                              f"{hdg:.1f}", "T", f"{hdg:.1f}", "M",
                              f"{spd_kts:.2f}", "N", f"{spd_ms:.3f}", "K"]),
                        # Apparent wind
                        nmea(["IIMWV",
                              f"{math.degrees(awa_rad):.1f}", "R",
                              f"{aws_kts:.1f}", "N", "A"]),
                        # True wind
                        nmea(["IIMWV",
                              f"{math.degrees(twa_rad):.1f}", "T",
                              f"{tws_kts:.1f}", "N", "A"]),
                        # Depth
                        nmea(["IIDBT",
                              f"{depth_m / 0.3048:.1f}", "f",
                              f"{depth_m:.1f}", "M",
                              f"{depth_m / 1.8288:.1f}", "F"]),
                        # Water temperature
                        nmea(["IIMTW", f"{water_c:.1f}", "C"]),
                        # Rudder angle
                        nmea(["IIRSA", f"{rudder_deg:.1f}", "A", "0.0", "B"]),
                        # RMC (position + SOG + COG)
                        nmea(["GPRMC",
                              time.strftime("%H%M%S", time.gmtime()), "A",
                              f"{lat_deg:02d}{lat_min:07.4f}", lat_hem,
                              f"{lon_deg:03d}{lon_min:07.4f}", lon_hem,
                              f"{spd_kts:.2f}", f"{hdg:.1f}",
                              time.strftime("%d%m%y", time.gmtime()),
                              "0.0", "E"]),
                    ]

                    try:
                        for s in sentences:
                            conn.sendall(s.encode())
                        time.sleep(0.5)
                    except (BrokenPipeError, ConnectionResetError):
                        print("Client disconnected")
                        break

if __name__ == "__main__":
    main()
