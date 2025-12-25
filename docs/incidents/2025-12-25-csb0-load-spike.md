# Incident Report: 2025-12-25 Load Spike & I/O Brownout (csb0)

**Date**: Thursday, Dec 25, 2025  
**Duration**: ~30 minutes (16:15 - 16:45 CET)  
**Host**: `csb0` (Cloud Server Barta 0)  
**Impact**: Transient unavailability in NixFleet dashboard, smart home automation delays (Node-RED), and slow SSH response.

---

## 🚨 What Happened?

At approximately 16:15 CET, `csb0` experienced a severe performance degradation. The host was reported "down" in NixFleet, and internal monitoring showed a load average spike exceeding **50.0** (on a 2-core VPS).

**Root Cause**:  
Memory pressure led to heavy swap thrashing. `nixfleet-agent` recorded a memory peak of **970.8 MiB**, consuming nearly 50% of the available 2GB RAM. This triggered ZFS transaction group (`txg_sync`) delays and high I/O wait (**45.8% `wa`**), effectively "locking" the system while it struggled to flush data to disk.

---

## 🔍 Log Evidence

**High Load & I/O Wait (16:30 CET):**

```text
top - 16:30:30 up 19 days, 3:04, 1 user, load average: 53,12, 23,29, 9,73
%Cpu(s):  0,0 us,  8,3 sy,  0,0 ni, 45,8 id, 45,8 wa,  0,0 hi,  0,0 si,  0,0 st
```

**Memory Pressure (nixfleet-agent):**

```text
Memory: 5.9M (peak: 970.8M, swap: 1.7M, swap peak: 489.9M)
```

**Service Impact (Node-RED):**

```text
25 Dec 16:30:49 - [info] [mqtt-broker:...] Disconnected from broker: mqtt://mosquitto:1883
25 Dec 16:31:25 - [info] [mqtt-broker:...] Connected to broker: mqtt://mosquitto:1883
```

**Kernel / ZFS Bottleneck:**

```text
# Kernel traces showing zio_wait during the spike:
Dez 25 16:30:39 csb0 kernel:  zio_wait+0x14e/0x2e0 [zfs]
Dez 25 16:30:39 csb0 kernel:  dsl_pool_sync+0xf1/0x510 [zfs]
```

---

## 🛠️ Resolution (2025-12-25 16:45)

1.  **Observation**: Monitored load recovery; load dropped from 53.12 to 13.50 within 15 minutes.
2.  **Verification**: Confirmed all Docker containers (8/8) recovered and reconnected to MQTT.
3.  **Stability**: Verified `nixfleet-agent` re-registered with the dashboard.

---

## 🛡️ Prevention & Next Steps

1.  **Memory Limits**: Evaluate setting systemd resource limits (`MemoryHigh`, `MemoryMax`) for `nixfleet-agent` to prevent it from starving the system during git/nix operations.
2.  **Monitoring**: Investigate if a specific `nix-daemon` job triggered the spike (likely a large flake evaluation or pull).
3.  **Resource Audit**: Consider increasing RAM if `nixfleet` and smart home services continue to exceed 2GB under moderate load.
