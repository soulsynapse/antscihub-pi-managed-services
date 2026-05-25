Go to the setup folder for the most up to date agent instructions.






Pasted here:




# Fleet Message Format Guide for Downstream Modules

## Overview

This guide describes how to format MQTT messages for proper display in the Fleet Orchestrator GUI. The orchestrator uses a **severity-based prioritization system** to reduce clutter and help operators focus on important events.

---

## Quick Start

### Using the Shared MQTT Client

All services on the Pi can import the shared MQTT client:

```python
from mqtt_client import fleet, DEVICE_ID

# Publish unencrypted JSON (recommended for most services)
fleet.publish(
    f"fleet/services/{DEVICE_ID}/meta",
    {
        "event": "status",
        "device_id": DEVICE_ID,
        "timestamp": time.time(),
        "healthy": ["sensor1", "sensor2"],
        "unhealthy": []
    },
    encrypt=False  # Important: most messages should be unencrypted
)
```

### Using the CLI Tool

For simple messages from shell scripts:

```bash
# Plain text message
fleet-publish --topic fleet/report/my-device --text "sensor started" --no-encrypt

# JSON payload
fleet-publish --topic fleet/report/my-device --json '{"temp_c": 24.1}' --no-encrypt
```

---

## Severity Levels

All messages are categorized by severity for filtering in the GUI:

| Severity | Purpose | Visual Treatment | When to Use |
|----------|---------|------------------|-------------|
| **ROUTINE** | Background noise | Dimmed gray text | Heartbeats, health checks when healthy, periodic sensor readings with normal values |
| **INFO** | Normal operations | Blue text | Successful completions, normal state transitions, informational logs |
| **ATTENTION** | State changes | Orange text | Updates in progress, services restarting, new devices connecting |
| **WARNING** | Problems needing action | Yellow text, bold | Unhealthy services, timeouts, retries, degraded performance |
| **ERROR** | Critical issues | Red text, bold | Crashes, failed updates, critical failures |

**GUI Filter Behavior:**
- **ALL** - Shows everything including ROUTINE
- **INFO+** - Shows INFO and above (hides ROUTINE background noise) ← Default
- **ATTENTION+** - Shows ATTENTION, WARNING, ERROR
- **WARNING+** - Shows WARNING, ERROR
- **ERROR** - Shows only ERROR

---

## Message Display Format

The orchestrator displays messages in columns:

```
Time     | Level   | Device | Channel              | Status    | Message
---------|---------|--------|----------------------|-----------|---------------------------
15:46:33 | INFO    | ant3b5 | services/ant3b5/meta | OK        | Boot complete
15:46:48 | ROUTINE | ant3b5 | services/ant3b5/meta | HEALTHY   | 3/3 services running
15:47:18 | WARNING | ant3b5 | services/ant3b5/meta | UNHEALTHY | 1/3 services down: sensor1
```

---

## Core Message Types

### 1. Heartbeat Messages

**Topic:** `fleet/heartbeat/{device_id}`

**Format:**
```json
{
  "type": "heartbeat",
  "device_id": "ant3b5",
  "timestamp": 1679432800.123
}
```

**Severity:** ROUTINE (hidden by default in INFO+ filter)

**Encryption:** ❌ Unencrypted (for visibility)

**Example:**
```python
fleet.publish(
    f"fleet/heartbeat/{DEVICE_ID}",
    {
        "type": "heartbeat",
        "device_id": DEVICE_ID,
        "timestamp": time.time()
    },
    encrypt=False
)
```

---

### 2. Health Status Events

**Topic:** `fleet/services/{device_id}/meta`

Sent periodically (every 30s) to report service health.

**Format:**
```json
{
  "event": "status",
  "device_id": "ant3b5",
  "timestamp": 1679432800.123,
  "managed": ["heartbeat", "sensor1", "monitor"],
  "healthy": ["heartbeat", "sensor1", "monitor"],
  "unhealthy": []
}
```

**Severity Mapping:**
- All services healthy → **ROUTINE**
- No managed services → **ROUTINE**
- Any unhealthy services → **WARNING**

**Encryption:** ❌ Unencrypted

**Example:**
```python
def publish_health_status():
    healthy = []
    unhealthy = []

    for service in managed_services:
        if check_service_health(service):
            healthy.append(service)
        else:
            unhealthy.append(service)

    fleet.publish(
        f"fleet/services/{DEVICE_ID}/meta",
        {
            "event": "status",
            "device_id": DEVICE_ID,
            "timestamp": time.time(),
            "managed": managed_services,
            "healthy": healthy,
            "unhealthy": unhealthy
        },
        encrypt=False
    )
```

---

### 3. Boot Events

**Boot Start:**
```json
{
  "event": "boot_start",
  "device_id": "ant3b5",
  "version": "1.2.3",
  "timestamp": 1679432800.123
}
```
→ **Severity: INFO** | **Encryption: ❌ No**

**Boot Complete:**
```json
{
  "event": "boot_complete",
  "device_id": "ant3b5",
  "timestamp": 1679432800.456
}
```
→ **Severity: INFO** | **Encryption: ❌ No**

**Boot Update Done:**
```json
{
  "event": "boot_update_done",
  "device_id": "ant3b5",
  "timestamp": 1679432800.789
}
```
→ **Severity: INFO** | **Encryption: ❌ No**

---

### 4. Update Events

#### Self-Update Events

**Update Start:**
```json
{
  "event": "self_update_start",
  "device_id": "ant3b5",
  "timestamp": 1679432800.123
}
```
→ **Severity: ATTENTION** | **Encryption: ❌ No**

**Update Success:**
```json
{
  "event": "self_update_done",
  "device_id": "ant3b5",
  "success": true,
  "timestamp": 1679432850.456
}
```
→ **Severity: INFO** | **Encryption: ❌ No**

**Update Failure:**
```json
{
  "event": "self_update_done",
  "device_id": "ant3b5",
  "success": false,
  "error": "Download failed: connection timeout",
  "timestamp": 1679432850.456
}
```
→ **Severity: ERROR** | **Encryption: ❌ No**

#### Managed Service Update Events

**Service Update Start:**
```json
{
  "event": "service_update_start",
  "device_id": "ant3b5",
  "service": "sensor1",
  "timestamp": 1679432800.123
}
```
→ **Severity: ATTENTION** | **Encryption: ❌ No**

**Service Update Success:**
```json
{
  "event": "service_update_done",
  "device_id": "ant3b5",
  "service": "sensor1",
  "success": true,
  "timestamp": 1679432850.456
}
```
→ **Severity: INFO** | **Encryption: ❌ No**

**Service Update Failure:**
```json
{
  "event": "service_update_done",
  "device_id": "ant3b5",
  "service": "sensor1",
  "success": false,
  "error": "Checksum verification failed",
  "timestamp": 1679432850.456
}
```
→ **Severity: ERROR** | **Encryption: ❌ No**

---

### 5. Service Management Events

**Service Restart:**
```json
{
  "event": "service_restart",
  "device_id": "ant3b5",
  "service": "sensor1",
  "reason": "crashed: exit code 1",
  "timestamp": 1679432800.123
}
```
→ **Severity: WARNING** | **Encryption: ❌ No**

---

### 6. Shell Command Responses

**Topic:** `fleet/response/{device_id}`

**Format:**
```json
{
  "schema": "fleet.shell.v1",
  "status": "completed",
  "success": true,
  "device_id": "ant3b5",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "cmd": "uptime",
  "return_code": 0,
  "duration_ms": 234,
  "stdout": " 15:46:33 up 2 days, 4:32, 1 user, load average: 0.15, 0.10, 0.08",
  "stderr": ""
}
```

**Severity Mapping:**
- `status: "completed"` + `success: true` → **INFO**
- `status: "completed"` + `success: false` → **ERROR**
- `status: "rejected"` or `status: "timeout"` → **WARNING**
- `status: "error"` → **ERROR**

**Encryption:** ✅ **Encrypted** (shell commands and responses are always encrypted for security)

**Note:** This format is automatically handled by `fleet_shell.py`. You don't need to implement this unless creating a new shell command handler.

---

## Best Practices for Service Developers

### 1. Always Include Core Fields

Every message should include:
```json
{
  "device_id": "your-device-id",
  "timestamp": 1679432800.123
}
```

```python
import time
from mqtt_client import DEVICE_ID

payload = {
    "device_id": DEVICE_ID,
    "timestamp": time.time(),
    # ... your other fields
}
```

### 2. Use Standard Event Names

If your service performs similar actions to the meta service, use the same event names:
- `status` for health checks
- `service_restart` for recovery actions
- `*_update_start` and `*_update_done` for update operations
- `boot_start`, `boot_complete`, `boot_update_done` for boot sequence

### 3. Design for Severity Filtering

**Think about operator attention:**

**Use ROUTINE for:**
```python
# Periodic heartbeats
fleet.publish(
    f"fleet/heartbeat/{DEVICE_ID}",
    {"type": "heartbeat", "device_id": DEVICE_ID, "timestamp": time.time()},
    encrypt=False
)

# Regular health checks when everything is OK
fleet.publish(
    f"fleet/services/{DEVICE_ID}/meta",
    {
        "event": "status",
        "device_id": DEVICE_ID,
        "timestamp": time.time(),
        "managed": ["sensor1"],
        "healthy": ["sensor1"],
        "unhealthy": []
    },
    encrypt=False
)
```

**Use INFO for:**
```python
# Successful completions
fleet.publish(
    f"fleet/services/{DEVICE_ID}/meta",
    {
        "event": "update_done",
        "device_id": DEVICE_ID,
        "success": True,
        "timestamp": time.time()
    },
    encrypt=False
)
```

**Use ATTENTION for:**
```python
# Changes in progress
fleet.publish(
    f"fleet/services/{DEVICE_ID}/meta",
    {
        "event": "self_update_start",
        "device_id": DEVICE_ID,
        "timestamp": time.time()
    },
    encrypt=False
)
```

**Use WARNING for:**
```python
# Services becoming unhealthy
fleet.publish(
    f"fleet/services/{DEVICE_ID}/meta",
    {
        "event": "service_restart",
        "device_id": DEVICE_ID,
        "service": "sensor1",
        "reason": "crashed: exit code 1",
        "timestamp": time.time()
    },
    encrypt=False
)
```

**Use ERROR for:**
```python
# Critical failures
fleet.publish(
    f"fleet/services/{DEVICE_ID}/meta",
    {
        "event": "update_done",
        "device_id": DEVICE_ID,
        "success": False,
        "error": "Download failed: connection timeout",
        "timestamp": time.time()
    },
    encrypt=False
)
```

### 4. Provide Context in Messages

**Good:**
```json
{
  "event": "service_restart",
  "service": "sensor1",
  "reason": "crashed: exit code 1, exceeded restart limit (3/3)",
  "timestamp": 1679432800.123
}
```

**Bad:**
```json
{
  "event": "restart"
}
```

### 5. Use Success/Error Patterns Consistently

For operations that can succeed or fail:
```json
{
  "event": "operation_done",
  "success": true,  // or false
  "error": "error message if success=false",
  "timestamp": 1679432800.123
}
```

### 6. Don't Encrypt Most Messages

**Encrypt ONLY:**
- Shell commands (`fleet/shell/*`)
- Shell responses (`fleet/response/*`)

**Don't encrypt:**
- Heartbeats
- Status messages
- Meta service events
- Sensor readings
- Most operational messages

Encryption reduces visibility and makes debugging harder. Only encrypt sensitive command/control messages.

---

## Example: Complete Service Implementation

Here's a complete example of a monitoring service that follows all best practices:

```python
#!/usr/bin/env python3
"""
monitor_service.py - Example monitoring service
"""
import os
import sys
import time
import subprocess

# Add parent dir to import mqtt_client
sys.path.insert(0, os.path.dirname(__file__))
from mqtt_client import fleet, DEVICE_ID

SERVICE_NAME = "monitor"
CHECK_INTERVAL = 30

def check_disk_usage():
    """Check disk usage and return percentage used."""
    result = subprocess.run(
        ["df", "/", "--output=pcent"],
        capture_output=True,
        text=True
    )
    if result.returncode == 0:
        lines = result.stdout.strip().split('\n')
        if len(lines) > 1:
            return int(lines[1].strip().rstrip('%'))
    return None

def publish_status(healthy: bool, message: str = ""):
    """Publish service health status."""
    event = {
        "event": "status",
        "device_id": DEVICE_ID,
        "service": SERVICE_NAME,
        "timestamp": time.time(),
        "healthy": healthy,
        "message": message
    }
    fleet.publish(f"fleet/services/{DEVICE_ID}/{SERVICE_NAME}", event, encrypt=False)

def main():
    # Publish boot event
    fleet.loop_start()
    if not fleet.wait_until_connected(timeout=15):
        print(f"ERROR: MQTT connect timeout")
        return 1

    fleet.publish(
        f"fleet/services/{DEVICE_ID}/meta",
        {
            "event": "boot_complete",
            "device_id": DEVICE_ID,
            "service": SERVICE_NAME,
            "timestamp": time.time()
        },
        encrypt=False
    )
    print(f"[{SERVICE_NAME}] Started")

    try:
        while True:
            disk_usage = check_disk_usage()

            if disk_usage is None:
                # Error checking disk
                publish_status(False, "Failed to check disk usage")
            elif disk_usage > 90:
                # Warning level
                publish_status(False, f"Disk usage critical: {disk_usage}%")
            elif disk_usage > 80:
                # Attention level
                publish_status(True, f"Disk usage high: {disk_usage}%")
            else:
                # Normal - ROUTINE level (will be filtered out by INFO+)
                publish_status(True, f"Disk usage normal: {disk_usage}%")

            time.sleep(CHECK_INTERVAL)

    except KeyboardInterrupt:
        print(f"[{SERVICE_NAME}] Shutting down...")
    finally:
        fleet.loop_stop()

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

---

## Testing Your Messages

### Manual Testing with mosquitto_pub

```bash
# Test a heartbeat (should appear as ROUTINE - dimmed)
mosquitto_pub -h broker.example.com -p 8883 \
  -u admin -P password \
  --cafile ca.crt \
  -t "fleet/heartbeat/test-device" \
  -m '{"type":"heartbeat","device_id":"test-device","timestamp":1679432800}'

# Test a healthy status (should appear as ROUTINE - dimmed)
mosquitto_pub -h broker.example.com -p 8883 \
  -u admin -P password \
  --cafile ca.crt \
  -t "fleet/services/test-device/meta" \
  -m '{"event":"status","device_id":"test-device","managed":["svc1"],"healthy":["svc1"],"unhealthy":[],"timestamp":1679432800}'

# Test an unhealthy status (should appear as WARNING - yellow/bold)
mosquitto_pub -h broker.example.com -p 8883 \
  -u admin -P password \
  --cafile ca.crt \
  -t "fleet/services/test-device/meta" \
  -m '{"event":"status","device_id":"test-device","managed":["svc1"],"healthy":[],"unhealthy":["svc1"],"timestamp":1679432800}'

# Test an error (should appear as ERROR - red/bold)
mosquitto_pub -h broker.example.com -p 8883 \
  -u admin -P password \
  --cafile ca.crt \
  -t "fleet/services/test-device/meta" \
  -m '{"event":"service_update_done","device_id":"test-device","service":"sensor1","success":false,"error":"Download failed","timestamp":1679432800}'
```

### Expected Console Output

With severity filter set to **INFO+** (default):
- ✅ ROUTINE messages (heartbeats, healthy status) are **hidden**
- ✅ INFO messages are shown in blue
- ✅ ATTENTION messages are shown in orange
- ✅ WARNING messages are shown in yellow/bold
- ✅ ERROR messages are shown in red/bold

---

## Quick Reference Table

| Event Type | Topic Pattern | Event Field | Severity | Encrypt |
|------------|---------------|-------------|----------|---------|
| Heartbeat | `fleet/heartbeat/{id}` | `type: "heartbeat"` | ROUTINE | ❌ No |
| Health (OK) | `fleet/services/{id}/meta` | `event: "status"` (all healthy) | ROUTINE | ❌ No |
| Health (Issues) | `fleet/services/{id}/meta` | `event: "status"` (some unhealthy) | WARNING | ❌ No |
| Boot Start | `fleet/services/{id}/meta` | `event: "boot_start"` | INFO | ❌ No |
| Boot Complete | `fleet/services/{id}/meta` | `event: "boot_complete"` | INFO | ❌ No |
| Update Start | `fleet/services/{id}/meta` | `event: "*_update_start"` | ATTENTION | ❌ No |
| Update Success | `fleet/services/{id}/meta` | `event: "*_update_done"` + `success: true` | INFO | ❌ No |
| Update Failure | `fleet/services/{id}/meta` | `event: "*_update_done"` + `success: false` | ERROR | ❌ No |
| Service Restart | `fleet/services/{id}/meta` | `event: "service_restart"` | WARNING | ❌ No |
| Shell Success | `fleet/response/{id}` | `status: "completed"` + `success: true` | INFO | ✅ Yes |
| Shell Failure | `fleet/response/{id}` | `status: "completed"` + `success: false` | ERROR | ✅ Yes |

---

## Common Pitfalls

### ❌ Don't: Encrypt Everything
```python
# BAD - encrypting a heartbeat makes it invisible to the GUI
fleet.publish(f"fleet/heartbeat/{DEVICE_ID}", data, encrypt=True)
```

### ✅ Do: Only Encrypt Shell Commands
```python
# GOOD - heartbeats should be unencrypted
fleet.publish(f"fleet/heartbeat/{DEVICE_ID}", data, encrypt=False)

# GOOD - shell commands/responses should be encrypted
fleet.publish(f"fleet/response/{DEVICE_ID}", data, encrypt=True)
```

### ❌ Don't: Spam INFO Messages
```python
# BAD - this will flood the console every second
while True:
    fleet.publish(topic, {"event": "tick", ...}, encrypt=False)  # INFO level
    time.sleep(1)
```

### ✅ Do: Use ROUTINE for Periodic Messages
```python
# GOOD - ROUTINE messages are filtered by default
while True:
    fleet.publish(topic, {"event": "status", "healthy": [...], ...}, encrypt=False)
    time.sleep(30)
```

### ❌ Don't: Missing Core Fields
```python
# BAD - missing device_id and timestamp
fleet.publish(topic, {"event": "status"}, encrypt=False)
```

### ✅ Do: Always Include device_id and timestamp
```python
# GOOD
fleet.publish(
    topic,
    {
        "event": "status",
        "device_id": DEVICE_ID,
        "timestamp": time.time()
    },
    encrypt=False
)
```

---

## Need Help?

- **Check existing services:** Look at `fleet_shell.py` for shell command handling examples
- **Use the shared client:** Import `mqtt_client.py` for consistent behavior
- **Follow the patterns:** Use standard event names and severity levels
- **Test with INFO+ filter:** Ensure important messages are visible, routine messages are hidden
