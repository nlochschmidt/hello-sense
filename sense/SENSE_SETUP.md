# Self-hosting the Hello Sense

*Part of [Reviving the Hello Sense Sleep System](../README.md).*

Make a **Hello Sense** sleep tracker (the company is defunct, cloud shut down) upload its
sensor data to a **local server** over its own WiFi + HTTPS, exactly the way it once
talked to Hello's cloud.

Confirmed working on firmware **build 4513** (hello/kitsune git tag `1.9.2`; the
device reports this as firmware **1.3.0**). This is the original **Sense without
Voice** (TI CC3200). The matching firmware, rebuildable byte-for-byte from source,
is in [`firmware/kitsune-4513/`](firmware/kitsune-4513/).

> **Your Sense is irreplaceable.** Nothing here is guaranteed non-destructive. The
> flash steps (installing a CA, etc.) modify the device. **Run `make backup` first** so
> you can restore. Proceed at your own risk.

---

## What this does

`sense_server.py` is a TLS front-end. It handles the two things only it can (the
device's ancient TLS handshake and its antique certificate clock), then forwards every
request untouched to **orb**, the backend that replaced Hello's cloud, running under
docker compose in [`../infrastructure`](../infrastructure/README.md).

```
   Sense --WiFi--> your DNS (*.hello.is -> your PC) --> sense_server.py (:80, :443)
                                                             |  terminates TLS, proxies
                                    time.hello.is     ------>|
                                    sense-in.hello.is ------>|--> orb  :8081
                                    messeji.hello.is  ------>|
```

Bodies are relayed byte-for-byte. Every request is AES-CBC signed with the device's own
key, and orb verifies that signature against the key it holds for that Sense, so nothing
here may rewrite a payload.

Five problems had to be solved, all handled by the code here:

1. **Message signing** -- every request is AES-128-CBC signed with a per-device key stored
   on the device. You recover that key over UART, then register it with orb so the
   backend can verify requests (step 5 below).
2. **DNS** -- the endpoints (`sense-in.hello.is`, `messeji.hello.is`, `time.hello.is`) are
   hardcoded in firmware, so your network has to resolve them to your PC (step 6).
3. **TLS** -- the device speaks an ancient handshake modern TLS libraries reject. We
   terminate TLS with **tlslite-ng** (pure Python).
4. **Cert trust + a clock bug** -- you install your own CA on the device, and the server
   cert must be dated from **1950** because the device's clock starts ~70 years behind.
5. **The NTP epoch** -- the Sense expects timestamps counted from **1900**, not the Unix
   1970 epoch. Feed it Unix seconds and it sits exactly 70 years in the past (reporting
   1956), and the backend then discards every sensor sample as more than two hours out
   of sync. orb answers time sync on the 1900 epoch.

See **[How it works](#how-it-works)** for the details.

### Running against the backend

Start orb first (step 0 below), then `make run`, which points all three upstreams at
orb on `127.0.0.1:8081`. Upstreams and behaviour are configurable by environment
variable:

| Variable | `make run` sets | Purpose |
|---|---|---|
| `SENSE_UPSTREAM_TIME` | `http://127.0.0.1:8081` | clock sync |
| `SENSE_UPSTREAM_SENSE` | `http://127.0.0.1:8081` | sensor uploads |
| `SENSE_UPSTREAM_MESSEJI` | `http://127.0.0.1:8081` | the command long-poll |
| `SENSE_TIME_MODE` | `proxy` | set `local` to answer time sync in Python instead, for running with no backend |
| `SENSE_AES_KEY` | -- | 32 hex chars, only needed for `SENSE_TIME_MODE=local` |

Run `sense_server.py` directly without `make run` and the upstreams fall back to the
ports of the retired Java services, which nothing listens on any more.

---

## Hardware

### Sense UART access

The Sense's micro-USB port carries UART serial (not real USB) on the D+/D- pins.

| Part | Example |
|------|---------|
| Micro-USB **male breakout board** (breaks out VBUS/D-/D+/ID/GND) | Treedix USB MicroB Plug Breakout Board (Amazon `B09JC7JPGN`) |
| **3.3V-capable USB-UART adapter** (FT232R with a 3V3/5V jumper) | FT232 USB-UART board (FT232RL, 5V/3.3V) (Amazon `B0CSYVXH8L`) |

### Physical access

The Sense's micro-USB port is recessed, so to seat the breakout you must partially
disassemble the sphere:
1. Remove the **4 screws on the bottom**.
2. Remove the screws holding the **light ring** and the **internal board**, so the board
   lifts enough for the breakout to plug into the micro-USB port.

### UART pinout (micro-USB connector)

```
Pin 1 (VBUS) = 5V power
Pin 2 (D-)   = UART TX (Sense -> host)
Pin 3 (D+)   = UART RX (host -> Sense)
Pin 4 (ID)   = mode select (see below)
Pin 5 (GND)  = ground
```

Baud rate: **115200, 8N1**

### Wiring (UART adapter to micro-USB breakout)

Set the adapter's voltage jumper to **3.3V**. The CC3200 is **not** 5V-tolerant on its
I/O, and 5V also silently breaks the bootloader handoff (see Troubleshooting).

| Breakout pin | Adapter pin | Notes |
|---|---|---|
| `VBUS` | **5V** | raw USB 5V, powers the Sense. On boards whose jumper selects `VCCIO`, the `VCCIO` pin follows the jumper and gives only 3.3V: take 5V from the jumper header's free `5V` pin instead, and check it with a multimeter first. |
| `GND`  | `GND` | common ground |
| `D+`   | `TXD` | **D+/D- are swapped on this breakout. If no console output, swap D+ and D-.** |
| `D-`   | `RXD` | |
| `ID`   | `GND` **or** `RTS` | mode select (below) |

### Two modes (the `ID` pin)

| `ID` connected to | Mode | Use |
|---|---|---|
| `GND` | **debug console** -- 115200 8N1. The device joins WiFi but **waits at the console**: type `boot` to start sensing and uploading | watch boot log, `connect` to WiFi |
| adapter `RTS` | **CC3200 bootloader** -- flash read/write via `cc3200tool` | `make backup`, `read-key`, `write-ca` |

Power-cycle after changing the `ID` pin. (`RTS` idles high, which is what puts the CC3200
into the bootloader; `cc3200tool` is invoked with `--sop2 '~rts'`.) Pulling the `VBUS`
wire for a few seconds is the easiest power-cycle, because the adapter stays plugged in
and keeps its port name.

Two bootloader rules that each cost a power-cycle to learn:

- **One `cc3200tool` session per power-up.** A second run fails with `Did not get ACK on
  break condition`. Power-cycle before every `make` target that talks to the device, or
  pass several commands to one `cc3200tool` call.
- **Close the serial terminal first.** A `screen` session left open holds the port, and
  `cc3200tool` fails with `Resource busy`.

The "waits at the console" behaviour is the firmware's own: at power-up it drives the
UART's TX line low and checks whether RX follows. A plain USB wall charger ties the two
USB data lines (which carry TX and RX) together, so RX follows and the Sense starts
everything by itself, dark until you wave at it. Anything else (the debug cable, **a
computer's USB port**, a charge-only cable) reads as a debug cable: the ring spins yellow
and the Sense waits at the console. Once reassembled, run it from a wall charger.

### Console commands

Once connected in debug mode (ID to GND), these commands are available. Backspace does
not work from a macOS terminal; use **Ctrl-H**. The up arrow recalls the last command.

| Command | Description |
|---|---|
| `boot` | Start sensing, clock sync and uploads (needed whenever the debug cable is attached) |
| `status` | IP, subnet, gateway and DNS, in hex and dotted form |
| `connect <ssid> <key> 2` | Connect to WPA2 WiFi (profile persists across reboots) |
| `disconnect` | Delete **all** saved WiFi profiles (also resets the antenna choice to its default) |
| `dns <hex-ip>` | Set the DNS server, e.g. `dns C0A8010A` for 192.168.1.10. **Freezes the current IP as static**; see step 6 |
| `temp` | Read temperature |
| `humid` | Read humidity |
| `dust` | Read dust/particulate level |
| `light` | Read light level |
| `prox` | Read proximity sensor |
| `set-time <unix_ts>` | Set device clock (bypasses network time sync) |
| `factory_reset` | Factory reset: deletes WiFi profiles, alarms and pill pairings |
| `led stop` | Stop LED animation |
| `nwp` | Network processor info |

---

## Setup

The server scripts, `Makefile`, and `proto/` live in the repo's **`services/`**
directory. Run every `make` command below from there:

```bash
cd ../services    # from this guide's folder (sense/); or `cd services` from the repo root
make setup        # venv + deps + cc3200tool + generate *_pb2.py from proto/
```

Requires Python 3.9+ and (for `gen-certs`) nothing but the venv. tlslite-ng and the
`cryptography` cert generator are pure/portable, so the host OpenSSL version doesn't
matter.

---

## Step by step

Set `PORT` to your adapter's serial device (find it: `ls /dev/tty.usbserial-*` on macOS,
`/dev/ttyUSB*` on Linux). Every bootloader step needs its own power-cycle (see
[Two modes](#two-modes-the-id-pin)).

### 0. Start orb

orb, its algorithm service and Postgres run under docker compose. Follow the quick start
in [`../infrastructure/README.md`](../infrastructure/README.md): `make init`, set
`POSTGRES_PASSWORD` in `.env`, then `make build up migrate verify`. The build needs
Hello's `suripu-app` jar, which is not in this repository; how to rebuild it is in
[`../infrastructure/orb-algo/patches/README.md`](../infrastructure/orb-algo/patches/README.md).

### 1. Back up the device (bootloader mode: `ID` to `RTS`, power-cycle)

```bash
make backup PORT=/dev/tty.usbserial-XXXX
```

The backup **skips the certificate files**: `cc3200tool` cannot list the names of files
under `/cert/`, so it reports them as "file without filename" and moves on. They are
read by name in step 2.

### 2. Recover the AES key and the original CA (bootloader mode, power-cycle)

```bash
mkdir -p sense_fs_backup/cert
./venv/bin/cc3200tool -p /dev/tty.usbserial-XXXX --reset none --sop2 '~rts' \
  read_file /cert/key.aes ./key.aes \
  read_file /cert/ca.der sense_fs_backup/cert/ca.der
xxd -p key.aes | tr -d '\n' > aes.key      # 32 hex chars -> ./aes.key
```

`aes.key` is what the server signs with. (If the device has no key, it falls back to the
firmware default `1234567891234567`; leave `aes.key` absent to use that.) The original
`ca.der` is what `make restore-ca` puts back; without it, step 4 has no undo.

> **Critical: use 3.3V signal levels.** At 5V the `SWITCH_2_APPS` bootloader handoff
> silently fails. Set the FT232 jumper to 3V3 so TXD/RXD/RTS all swing 3.3V. Power
> the Sense's VBUS from the board's separate 5V pin (USB VBUS), not VCCIO.

### 3. Generate certificates

```bash
make gen-certs        # -> ca.crt ca.der ca.key server.crt server.key (valid 1950-2046)
```

### 4. Install your CA on the device (bootloader mode, power-cycle)

```bash
make write-ca PORT=/dev/tty.usbserial-XXXX
```

### 5. Register the Sense with orb

orb accepts a Sense only when it knows the device's key **and** the device is paired to
an account. The app normally does the pairing over Bluetooth; without the app, do it by
hand.

The device id is the 16 hex characters in the backup:

```bash
xxd -p sense_fs_backup/hello/deviceid | tr a-f A-F      # 16 hex characters
```

Create an account through orb's sign-up endpoint (the same one the app uses). `tz` is
your UTC offset in milliseconds:

```bash
curl -s -X POST http://127.0.0.1:9999/v1/account -H 'Content-Type: application/json' \
  -d '{"name":"<name>","email":"<email>","password":"<password>","tz":<utc-offset-ms>}'
```

Then, in `make psql` from `../infrastructure`, store the key, pair the Sense to the
account and give the account its time zone (the app would send the zone too). Use the
email in lower case; orb stores it that way.

```sql
INSERT INTO senses (device_id, aes_key)
VALUES ('<DEVICE_ID>', decode('<contents of aes.key>', 'hex'));

INSERT INTO account_senses (account_id, device_id)
SELECT id, '<DEVICE_ID>' FROM accounts WHERE email = '<email>';

INSERT INTO timezone_history (account_id, effective_from, timezone_id, offset_ms)
SELECT id, created_at, '<zone, e.g. Europe/London>', <utc-offset-ms> FROM accounts WHERE email = '<email>';
```

Missing the pairing, orb answers every request with `401` and logs `unknown device`.
Missing the time zone, it logs `no timezone history for account` and stores readings as
UTC.

### 6. Resolve `*.hello.is` to your PC

The Sense only uses three names: `time.hello.is`, `sense-in.hello.is` and
`messeji.hello.is`.

**Recommended: local DNS records on your router**, each pointing at your PC's LAN IP. The
Sense keeps getting its address and DNS server by DHCP, so it works on any network
without touching the device:

Most routers and DNS filters can do this; look for local DNS records, DNS rewrites,
host overrides or domain forwarding (Pi-hole, AdGuard Home, OpenWrt, OPNsense/pfSense
and UniFi all have one of them). A wildcard `*.hello.is` works where supported; three
plain A records work everywhere.

If the router answered `NXDOMAIN` for these names before the records existed, it caches
that for up to 30 minutes. Keep the records permanent: `hello.is` is still a registered
domain, so a Sense that asks public DNS reaches whoever owns it.

**Alternative: DNS on your PC plus the console `dns` command.** Run `make dns
REDIRECT_IP=192.168.x.y` in its own terminal, connect the Sense to WiFi, then on the
console `dns C0A8xxyy` (your PC's IP in hex). This **freezes the Sense's current IP as
static**, and no console command turns DHCP back on. The undo is a bootloader session
that erases the stored IP configuration:

```bash
./venv/bin/cc3200tool -p /dev/tty.usbserial-XXXX --reset none --sop2 '~rts' \
  erase_file /sys/ipcfg.ini
```

**Separate IoT network?** Allow the Sense to reach your PC on TCP 80 and 443 (and UDP 53
if your PC answers DNS). Many routers block IoT-to-LAN traffic by default.

### 7. Run the server and boot the Sense

```bash
make run
```

Switch the device to **debug mode** (`ID` to `GND`), power-cycle, and open the console
(`screen /dev/tty.usbserial-XXXX 115200`). The first time, join WiFi with
`connect <ssid> <key> 2` (`2` = WPA/WPA2; the profile persists across reboots). Then type
**`boot`**.

Within a minute `make run` shows the clock request to `time.hello.is`, followed by
uploads to `sense-in.hello.is`. orb's log (`docker compose logs -f orb` in
`../infrastructure`) shows `time sync served` and then `ingested ... written=1` once a
minute.

If the Sense tried to connect before DNS worked, it may have used up its clock-sync
retries and gone quiet. Power-cycle and `boot` again.

---

## How it works

**Message signing.** Requests are `protobuf + IV(16) + AES-CBC(SHA1(body) padded to 32B)`;
responses mirror it. The key lives at `/cert/key.aes` on the CC3200 flash. orb signs its
responses with the same key; the signed time-sync response is what sets the device clock
and unblocks everything else. Clock sync itself travels as plain HTTP on port 80, not
HTTPS.

**UART bootloader -- the 3.3V gotcha.** `cc3200tool` can read/write the SimpleLink flash,
but only after `SWITCH_2_APPS` hands control to the APPS bootloader. At 5V logic levels
that handoff silently fails; at **3.3V** it works. (Power VBUS at 5V, drive signals at 3.3V.)

**TLS -- the hard part.** The Sense's ClientHello offers only
`TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA` (0xC014) and sends **no `supported_groups`
extension**. OpenSSL 3.x, LibreSSL, and Go all reject this (`NO_SHARED_CIPHER`) because
they won't choose an ECDHE curve without the extension. The original Hello servers ran old
OpenSSL 1.0.x, which defaulted to P-256. We reproduce that with **tlslite-ng** (pure
Python), configured for `ecdhe_rsa` / `aes256` / `sha` / `secp256r1`. One tlslite quirk is
patched in `sense_server.py`: its `recv_into` returns `None` at EOF, which crashes
`http.server`; we make it return `0`.

**HTTP/1.1 keep-alive is required, not optional.** The Sense holds **one socket per host
and reuses it** across requests (its log shows `using sock 85 85` on consecutive
requests). If the server answers `HTTP/1.0`, that means close-after-response, so the
device's next request goes out on a socket we already closed: `recv` returns zero bytes
(`start recv error 0`), the request fails, and it only succeeds when the network task
retries over a fresh connection.

The result is that **every** request silently fails on its first attempt and succeeds on
the second, roughly 2-3 seconds later. On uploads this is invisible. On pill pairing it is
not: `_on_pair_failure` (kitsune `ble_proto.c`) replies to the phone immediately with
`ErrorType_NETWORK_ERROR`, which the app shows as **-12 "pairing failed"** — even though
the retry then succeeds server-side and the pill really does get paired.

`sense_server.py` therefore sets `protocol_version = "HTTP/1.1"` on the handler. This
needs three things to be true, and all are:

- an accurate `Content-Length` on every response (all paths set one, `0` on errors);
- `HOP_BY_HOP` stripping upstream `content-length` / `transfer-encoding` / `connection`,
  so framing headers can't duplicate or leak a `Connection: close`;
- a deadline on idle connections — `ReusableHTTPServer` is threaded with `daemon_threads`
  and sets `request_timeout` on every accepted socket, so a kept-alive connection the
  device abandons costs one daemon thread briefly rather than wedging the server.

After the change, TLS handshakes drop from roughly one per request to almost none, and
round trips that took 4-5 seconds complete in under one. To revert, delete the
`protocol_version` line.

**Cert trust + the 1950 date.** The device validates the server cert against
`/cert/ca.der`, so you install your own CA there. At power-on, before time sync
completes, the device's clock starts at ~1956 (NTP epoch offset). The TLS handshake
happens before the time sync response corrects the clock, so cert date validation fails
(`sl_Connect` error **-461 = `SL_ESECDATEERROR`**) unless the cert's `notBefore` predates
~1956. `gen_certs.py` dates the certs from **1950**, which satisfies both the pre-sync
clock and real time. Once orb answers the clock request, the clock is correct.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cc3200tool` times out at "Switching UART to APPS" | Signals at 5V. Set the jumper to **3.3V**. |
| `cc3200tool`: `Did not get ACK on break condition` | The bootloader already served a session since power-up. Power-cycle. |
| `cc3200tool`: `Resource busy` | A serial terminal (`screen`) still holds the port. Quit it (Ctrl-A, K). |
| Console prompt, WiFi connected, but no requests ever arrive | The debug cable is attached, so the firmware waits. Type `boot`. |
| Reassembled, the ring keeps spinning yellow and nothing uploads | It is powered from a computer's USB port, which looks like a debug cable. Use a plain USB wall charger. |
| Backspace does nothing in the console | Use Ctrl-H. |
| orb logs `unknown device` and answers `401` | The Sense is not registered, or not paired to an account. See step 5. |
| orb logs `no timezone history for account` | The account has no time zone. See step 5. |
| `status` shows the right DNS but nothing reaches your PC | The Sense is on another subnet whose traffic to your PC is blocked. See step 6. |
| No debug console output | Swap **D+ and D-** |
| `zsh: no matches found: ~rts` | Quote it: `--sop2 '~rts'` (the Makefile already does) |
| TLS `NO_SHARED_CIPHER` / `-340` | You're using OpenSSL, not tlslite. Use this server. |
| `sl_Connect` **-461** | Cert `notBefore` after the device's (skewed) clock. Use `gen_certs.py` (1950). |
| Device ignores responses, resends same reading | See "Known limitations" |
| Every request seems to take 3-5s; app shows `-12` on pill pairing | Server answering HTTP/1.0 while the Sense reuses sockets. See the keep-alive note above. |
| A request never appears in the proxy log at all, but the device reports failure | It was written to a socket the server had already closed. Same cause as above. |

### Read the Sense's own logs

The single most useful debugging move, and easy to miss: the Sense uploads its internal
`LOGF`/`LOGI` output via `POST /logs`, so you can read it without a serial cable. orb
accepts and drops these by default. Start it with `-debug` and it prints them instead:
set `ORB_EXTRA_FLAGS=-debug` in `../infrastructure/.env`, run `make up` there, and follow
`docker compose logs -f orb`.

This is what tells you, in the device's own words, things the proxy log cannot show:
`signature validation fail`, `using sock 85 85`, `start recv error 0`, `NT <host><path> --
0` / `-- 1` attempt numbers, and `status: http/1.0 200 ok`. Dump whole log uploads rather
than grepping for a keyword, since the mechanism usually shows up in the surrounding
lines.

---

## Known limitations

- **Readings repeat in standalone mode.** When running with `SENSE_TIME_MODE=local`
  (no backend), the server acks `/in/sense/batch` with a plain `200`. The firmware
  wants a **signed** response and resends until it gets one, so the same reading loops
  rather than advancing. When running against orb (the default `make run` mode), orb
  signs the response and this does not happen.

---

## References / credits

- Firmware source: [hello/kitsune](https://github.com/hello/kitsune)
- Self-hosted server project + write-up: [oaeide/hello-sense-server](https://github.com/oaeide/hello-sense-server)
- Encryption discussion: [owarz/sense](https://github.com/owarz/sense)
- CC3200 flashing tool: [toniebox-reverse-engineering/cc3200tool](https://github.com/toniebox-reverse-engineering/cc3200tool)
- UART console discovery: [0ff/long-live-sense#2](https://github.com/0ff/long-live-sense/issues/2)
