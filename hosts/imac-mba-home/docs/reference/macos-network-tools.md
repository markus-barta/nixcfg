# macOS Network Tools - Why We Use Native Versions

**Issue Date**: 2025-11-16  
**Status**: Documented & Resolved

## Problem

The Nix `inetutils` package (which provides Linux network utilities like `ping`, `telnet`, etc.) has a critical bug when running on macOS:

### Symptoms

```bash
$ ping 192.168.1.223
PING 192.168.1.223 (192.168.1.223): 56 data bytes
56 bytes from 192.168.1.145: icmp_seq=0 ttl=64 time=-1084818903855532605440.000 ms
56 bytes from 192.168.1.89: icmp_seq=0 ttl=255 time=-1084818903855532605440.000 ms (DUP!)
56 bytes from 192.168.1.140: icmp_seq=0 ttl=64 time=-1084818903855532605440.000 ms (DUP!)
...
64 bytes from 192.168.1.223: icmp_seq=0 ttl=64 time=0.380 ms (DUP!)
```

### Root Cause

- **Linux ping on macOS**: The `inetutils` package provides the Linux version of `ping`
- **Timestamp calculation bug**: When running on Darwin (macOS), the timestamp arithmetic overflows
- **Integer overflow**: Results in astronomically large negative numbers (-10^21 ms)
- **Duplicate packets**: All responses are marked as duplicates due to the timestamp corruption

### Investigation Path

Initially suspected:

1. ✅ Network broadcast storm (ruled out - only one device responding normally)
2. ✅ Promiscuous mode interfaces (Thunderbolt bridge was in PROMISC, but wasn't the cause)
3. ✅ System clock corruption (ruled out - system time was correct)
4. **✅ Buggy ping binary** - ACTUAL CAUSE

The issue was confirmed when testing with macOS native ping showed perfect results:

```bash
$ /sbin/ping -c 3 192.168.1.223
PING 192.168.1.223 (192.168.1.223): 56 data bytes
64 bytes from 192.168.1.223: icmp_seq=0 ttl=64 time=0.649 ms
64 bytes from 192.168.1.223: icmp_seq=1 ttl=64 time=0.617 ms
64 bytes from 192.168.1.223: icmp_seq=2 ttl=64 time=0.587 ms
```

## Solution

### 1. Package Configuration

**Removed** `inetutils` from `home.nix`:

```nix
# home.packages = with pkgs; [
#   inetutils # ❌ REMOVED - ping has bugs on macOS
# ];
```

### 2. Shell Aliases

**Added** explicit aliases to use macOS native network tools in `home.nix`:

```nix
shellAliases = {
  # Force macOS native ping (inetutils ping has bugs on Darwin)
  ping = "/sbin/ping";

  # Other macOS network tools for reference
  traceroute = "/usr/sbin/traceroute";
  netstat = "/usr/sbin/netstat";
};
```

### 3. Verification

```bash
$ which ping
ping: aliased to /sbin/ping

$ ping -c 3 192.168.1.223
PING 192.168.1.223 (192.168.1.223): 56 data bytes
64 bytes from 192.168.1.223: icmp_seq=0 ttl=64 time=0.649 ms
64 bytes from 192.168.1.223: icmp_seq=1 ttl=64 time=0.617 ms
64 bytes from 192.168.1.223: icmp_seq=2 ttl=64 time=0.587 ms
```

## macOS Native Network Tools

macOS includes high-quality BSD network utilities that should be preferred:

| Tool         | Path                   | Purpose                         |
| ------------ | ---------------------- | ------------------------------- |
| `ping`       | `/sbin/ping`           | ICMP echo requests              |
| `traceroute` | `/usr/sbin/traceroute` | Network path tracing            |
| `netstat`    | `/usr/sbin/netstat`    | Network statistics              |
| `ifconfig`   | `/sbin/ifconfig`       | Network interface configuration |
| `arp`        | `/usr/sbin/arp`        | ARP table management            |
| `route`      | `/sbin/route`          | Routing table management        |

## Alternatives for Removed Tools

Since we removed `inetutils`, here are alternatives for other tools it provided:

### telnet

**Option 1**: Use `netcat` (already installed in Nix):

```bash
nc -v hostname port
```

**Option 2**: Install via Homebrew:

```bash
brew install telnet
```

### ftp

**Option 1**: Use `curl` or `wget` (already in Nix):

```bash
curl ftp://server/path/file
wget ftp://server/path/file
```

**Option 2**: Use macOS native `ftp`:

```bash
/usr/bin/ftp
```

## Lesson Learned

**When on macOS, prefer native tools for low-level system utilities:**

- ✅ Use macOS native: `ping`, `traceroute`, `netstat`, `ifconfig`
- ✅ Use Nix for: Modern CLI tools (`bat`, `ripgrep`, `fd`, etc.)
- ⚠️ Avoid: Linux-specific system utilities on Darwin

**Cross-platform compatibility issues** can be subtle and hard to diagnose. When dealing with low-level networking or system utilities on macOS, always test against native BSD tools.

## Related Files

- `hosts/imac-mba-home/home.nix` - Removed `inetutils`, added aliases
- `hosts/imac-mba-home/README.md` - Main documentation

## References

- [macOS ping man page](https://ss64.com/mac/ping.html)
- [BSD vs GNU utilities differences](https://ponderthebits.com/2017/01/know-your-tools-linux-gnu-vs-mac-bsd-command-line-utilities-grep-strings-sed-and-find/)
