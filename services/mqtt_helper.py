#!/usr/bin/env python3
"""
mqtt_helper.py — Persistent MQTT connection for the service manager.

Reads JSON messages from stdin (one per line) and publishes them encrypted.
Stays connected between publishes. No connect/disconnect churn.

Used as a bash coprocess:
    coproc MQTT { python3 mqtt_helper.py 2> >(logger -t TAG); }
    echo '{"event":"status","managed":["svc1"]}' >&${MQTT[1]}

FIX #12: Added reconnection monitoring and health logging.
"""

import glob
import json
import os
import signal
import sys
import threading
import time

# Find mqtt_client
mqtt_dir = None
for pattern in ["/home/*/Desktop/1-MQTT", "/home/*/1-MQTT"]:
    for d in glob.glob(pattern):
        if os.path.isfile(os.path.join(d, "mqtt_client.py")):
            mqtt_dir = d
            break
    if mqtt_dir:
        break

if not mqtt_dir:
    print("FATAL: Cannot find MQTT directory", file=sys.stderr)
    sys.exit(1)

sys.path.insert(0, mqtt_dir)
from mqtt_client import FleetMQTT, DEVICE_ID

# Dedicated client ID — won't collide with fleet-shell or fleet-publish
client = FleetMQTT(role="svcmgr")
RESPONSE_TOPIC = f"fleet/response/{DEVICE_ID}"

# FIX #12: Track connection state for reconnection monitoring
_connected = threading.Event()
_shutting_down = False


def _on_connect(mqttc, userdata, flags, rc):
    """Called when the client connects or reconnects."""
    if rc == 0:
        _connected.set()
        print("MQTT connected", file=sys.stderr)
        sys.stderr.flush()
    else:
        _connected.clear()
        print(f"MQTT connect failed rc={rc}", file=sys.stderr)
        sys.stderr.flush()


def _on_disconnect(mqttc, userdata, rc):
    """Called when the client disconnects. paho will auto-reconnect if
    loop_start() is active, but we log it for visibility."""
    _connected.clear()
    if rc == 0:
        print("MQTT disconnected cleanly", file=sys.stderr)
    else:
        print(f"MQTT unexpected disconnect rc={rc}, will auto-reconnect", file=sys.stderr)
    sys.stderr.flush()


# Attach callbacks
client.on_connect = _on_connect
client.on_disconnect = _on_disconnect


def publish(payload: dict):
    payload.setdefault("device_id", DEVICE_ID)
    payload.setdefault("timestamp", time.time())

    # FIX #12: Wait briefly for connection if we're in a reconnect cycle
    if not _connected.is_set():
        print("MQTT not connected, waiting up to 10s...", file=sys.stderr)
        sys.stderr.flush()
        if not _connected.wait(timeout=10):
            print("MQTT still not connected, dropping message", file=sys.stderr)
            sys.stderr.flush()
            return

    try:
        info = client.publish(RESPONSE_TOPIC, payload, encrypt=True)
        rc = getattr(info, "rc", 1)
        if rc != 0:
            print(f"publish failed rc={rc}", file=sys.stderr)
            sys.stderr.flush()
    except Exception as e:
        print(f"publish error: {e}", file=sys.stderr)
        sys.stderr.flush()


def shutdown(sig, frame):
    global _shutting_down
    _shutting_down = True
    print("MQTT helper shutting down", file=sys.stderr)
    sys.stderr.flush()
    try:
        client.loop_stop()
    except Exception:
        pass
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    client.loop_start()
    if not client.wait_until_connected(timeout=15):
        print("FATAL: MQTT connect timeout", file=sys.stderr)
        sys.exit(1)

    _connected.set()
    print("CONNECTED", file=sys.stderr)
    sys.stderr.flush()

    for line in sys.stdin:
        if _shutting_down:
            break
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
            publish(payload)
        except json.JSONDecodeError as e:
            print(f"bad JSON: {e}", file=sys.stderr)
            sys.stderr.flush()
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)
            sys.stderr.flush()

    client.loop_stop()


if __name__ == "__main__":
    main()