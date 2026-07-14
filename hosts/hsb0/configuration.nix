# hsb0 server for Markus
# Primary Purpose: DNS and DHCP server running AdGuard Home
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  hostdashHsb0 = inputs.hostdash.packages.${pkgs.system}.hsb0;

  # ============================================================================
  # DNS ALLOWLIST - Domains that bypass ad-blocking
  # ============================================================================
  # Add domains here that need to be whitelisted for devices to function
  # Format: "@@||domain.example.com^" (AdGuard Home allowlist syntax)
  # Source: sudo grep 'DEVICE_IP' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u
  # ============================================================================
  dnsAllowlist = [
    # Roborock Vacuum (192.168.1.235 / roborock-vacuum-a226)
    "@@||mqtt-eu-3.roborock.com^" # MQTT broker
    "@@||api-eu.roborock.com^" # API endpoint
    "@@||eu-app.roborock.com^" # App backend
    "@@||euiot.roborock.com^" # IoT endpoint
    "@@||v-eu-2.roborock.com^" # Voice/firmware
    "@@||v-eu-3.roborock.com^" # Voice/firmware
    "@@||vivianspro-eu-1316693915.cos.eu-frankfurt.myqcloud.com^" # Tencent COS (maps)
    "@@||conf-eu-1316693915.cos.eu-frankfurt.myqcloud.com^" # Tencent COS (config)
    "@@||anonymousinfo-eu-1316693915.cos.eu-frankfurt.myqcloud.com^" # Tencent COS (telemetry)
    "@@||cdn.awsde0.fds.api.mi-img.com^" # Xiaomi CDN (firmware/images)
  ];

  # DNS rewrite rules (internal hostnames)
  dnsRewrites = [
    "||csb0^$dnsrewrite=NOERROR;CNAME;cs0.barta.cm"
    "||csb1^$dnsrewrite=NOERROR;CNAME;cs1.barta.cm"
  ];
in
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/hostdash-status.nix # NIX-280 — same-origin runtime status artifact for HostDash
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.nixosModules.nixfleet-agent)

    # INSPR-73 (2026-05-04): system-side ssh-authorized — see the
    # inspr.ssh.authorized.users.mba block further down. force=true
    # because hsb0 hokage-injects external operator keys we do not
    # want admitted on this private/family host.
    inputs.inspr-modules.nixosModules.ssh-authorized
    ../../modules/shared/ssh-authorized-nixos.nix
  ];

  # ============================================================================
  # UZUMAKI MODULE - Fish functions, zellij, stasysmo (all-in-one)
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "server";
    fish.editor = "nano";
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  # NOTE: starship and atuin are configured in common.nix (via commonServerModules)

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # ============================================================================
  # UPS Monitoring — Eaton Ellipse PRO 650 DIN via NUT (NIX-297 / NIX-135)
  # ============================================================================
  # WAS: services.apcupsd (APC Back-UPS BX500MI). That unit is FAULTY — it falsely
  # rejects healthy mains as "high line voltage" and cuts to battery for no reason
  # (LINEV 230-234 V against a HITRANS of 295 V, independently confirmed against the
  # Sonnen powermeter). It has been replaced by an Eaton, so apcupsd has to go: it is
  # APC-only.
  #
  # apcupsd DOES half-talk to the Eaton over generic USB HID, which is a trap worth
  # naming: it reports model/serial/charge/runtime, but `OUTPUTV` and `LINEFREQ` come
  # back as 0.0 and `LINEV` is MISSING ENTIRELY. The failure that started NIX-135 was a
  # UPS lying about line voltage — running it on a stack that cannot read line voltage
  # at all would be a poor joke. Partial telemetry that looks complete is exactly the
  # class of bug this fleet keeps getting bitten by.
  #
  # NUT is vendor-neutral, fully local, no cloud. `nut-scanner -U` identified the device
  # unprompted and picked the driver itself:
  #     driver "usbhid-ups" | vendorid 0463 | productid FFFF
  #     vendor "EATON"      | product "Ellipse PRO" | serial "G355V01095"
  # which is the HCL "support level 5" claim holding up in practice.
  services.apcupsd.enable = false;

  power.ups = {
    enable = true;
    mode = "standalone"; # driver + upsd + upsmon, all on this host. No network exposure.

    ups.eaton = {
      driver = "usbhid-ups";
      port = "auto";
      description = "Eaton Ellipse PRO 650 DIN (hsb0)";
      directives = [
        # Pin the device explicitly. `auto` alone would happily bind whatever HID power
        # device turns up, which on a host that has already had one UPS swapped under it
        # is not a theoretical concern.
        "vendorid = 0463"
        "productid = FFFF"

        # THRESHOLDS — the point of this migration, not a detail.
        #
        # apcupsd ran on its defaults: MBATTCHG 10%, MINTIMEL 5 min. On 2026-07-13 that
        # produced the near-deadlock Markus hit — the UPS kept flipping to battery on
        # phantom "high line voltage", and 5 minutes is not enough margin to shut a ZFS
        # host down calmly, especially with a battery whose true runtime we now know is
        # ~35 min under load.
        #
        # `ignorelb` tells NUT to DISREGARD the UPS's own low-battery flag and use these
        # thresholds instead. That is deliberate: this whole ticket exists because a UPS
        # lied about its own state. We decide when to shut down, from charge and runtime
        # we can actually see — not from a flag the hardware raises when it feels like it.
        "ignorelb"
        "override.battery.charge.low = 30" # %
        "override.battery.runtime.low = 900" # seconds = 15 min
      ];
    };

    # upsd listens on loopback only. Nothing off-host needs to talk to it, and an open
    # UPS control port is a way to be shut down by a stranger.
    upsd.listen = [ { address = "127.0.0.1"; } ];

    users.upsmon = {
      # Password is GENERATED ON THE HOST (see nut-upsmon-password.service below) and
      # never enters git. It authenticates upsmon to upsd across a loopback socket —
      # there is no meaningful attacker here, and inventing an agenix ceremony for it
      # would be security theatre with a rotation burden attached.
      passwordFile = "/var/lib/nut/upsmon.pass";
      upsmon = "primary";
      # Needed so nut-beeper-off.service below can actually silence the thing.
      instcmds = [ "beeper.disable" ];
    };

    # powerValue = 1: this UPS really does feed hsb0, so upsmon may shut it down.
    #
    # ⚠️ THIS IS ONLY TRUE WHILE hsb0 IS PLUGGED INTO THE EATON. It is stated explicitly
    # rather than left to the default, because getting it wrong cost us the host:
    #
    # On 2026-07-14, with the Eaton on mains + USB but carrying NO LOAD, it reported
    #     ups.status: OL CHRG OFF
    # and to upsmon an OFF output means "not supplying power". Its count of live supplies
    # fell below MINSUPPLIES (1), so it did exactly what it is built to do — SHUTDOWNCMD.
    # It shut hsb0 down BECAUSE THE UPS WAS NOT POWERING IT. hsb0 is the LAN's DNS, so
    # the whole house lost name resolution, and the box needed a physical power button.
    #
    # With the load actually on the Eaton the status is `OL CHRG`, the OFF flag is gone,
    # and ups.load reads 8% — so this setting now describes reality and upsmon is a real
    # shutdown guard at the 30% / 15min thresholds above.
    #
    # IF THE LOAD IS EVER TAKEN OFF THE EATON (bench testing, a swap, an RMA), set
    # powerValue = 0 AND upsmon.settings.MINSUPPLIES = 0 first, or upsmon will shut this
    # host down the moment the UPS output goes idle.
    upsmon.monitor.eaton = {
      system = "eaton@localhost";
      user = "upsmon";
      powerValue = 1;
    };
  };

  # Generate upsd's local password once, on the host. Must exist BEFORE upsd/upsmon
  # start: the NixOS module passes it via systemd LoadCredential, and a missing file
  # makes those units fail outright rather than degrade.
  systemd.services.nut-upsmon-password = {
    description = "Generate the local upsd password for upsmon (NIX-297)";
    wantedBy = [ "multi-user.target" ];
    before = [
      "upsd.service"
      "upsmon.service"
    ];
    requiredBy = [
      "upsd.service"
      "upsmon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0750 /var/lib/nut
      if [ ! -s /var/lib/nut/upsmon.pass ]; then
        umask 077
        ${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\n' > /var/lib/nut/upsmon.pass
        chmod 0400 /var/lib/nut/upsmon.pass
      fi
    '';
  };

  # MQTT credentials for UPS status publishing
  # Format: MQTT_HOST, MQTT_USER, MQTT_PASS (sourced by bash)
  # Edit: agenix -e secrets/mqtt-hsb0.age
  age.secrets.mqtt-hsb0 = {
    file = ../../secrets/mqtt-hsb0.age;
    mode = "400";
    owner = "root";
    group = "root";
  };

  # Systemd service: Publish UPS status to MQTT as JSON
  # 🔇 SILENCE THE BEEPER. This is a hard requirement, not a preference.
  #
  # The Eaton ships with `ups.beeper.status: enabled`. Markus's son sleeps in the room
  # next door, and the old APC's alarm woke him at every power blip — which is why that
  # unit's beeper was deliberately disabled and why "the alarm stays off" is a standing
  # rule. A UPS that screams at 3am gets unplugged, and then it protects nothing.
  #
  # Telemetry is the alarm now: MQTT -> Node-RED -> Telegram/Pushover. The box itself
  # stays quiet.
  #
  # Runs on every boot rather than once by hand: the setting lives in the UPS's own
  # NVRAM, and a firmware reset or a swapped unit would silently bring the noise back.
  # Idempotent — disabling an already-disabled beeper is a no-op.
  systemd.services.nut-beeper-off = {
    description = "Disable the UPS beeper (sleeping child — see NIX-135)";
    after = [ "upsd.service" ];
    requires = [ "upsd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # NOTE: upscmd takes the password as an argv parameter — there is no file or stdin
      # option — so it is briefly visible in /proc. Accepted: this credential only
      # authenticates to a loopback-only upsd, it is host-generated, and it guards
      # nothing beyond "may silence a beeper".
      pass="$(cat /var/lib/nut/upsmon.pass)"

      # RETRY, and verify the OUTCOME rather than the exit code.
      #
      # `upsc eaton` answering does NOT mean upsd is ready to authenticate an instcmd:
      # on the very first deploy this service ran the instant upsd restarted, upsc
      # succeeded, upscmd failed, and the beeper stayed ON — while the journal happily
      # recorded that we had tried. The identical command run by hand ten seconds later
      # returned OK. A beeper that is silent by luck is not silent.
      for attempt in $(seq 1 15); do
        ${config.power.ups.package}/bin/upscmd -u upsmon -p "$pass" eaton beeper.disable >/dev/null 2>&1 || true
        sleep 1
        state="$(${config.power.ups.package}/bin/upsc eaton ups.beeper.status 2>/dev/null || true)"
        if [ "$state" = "disabled" ]; then
          ${pkgs.util-linux}/bin/logger -t nut-beeper-off "OK: UPS beeper disabled (attempt $attempt)"
          exit 0
        fi
        sleep 2
      done

      # Loud, because the failure mode here is a 3am scream next to a sleeping child.
      ${pkgs.util-linux}/bin/logger -t nut-beeper-off "ERROR: UPS beeper is still '$state' after 15 attempts — IT MAY SOUND"
    '';
  };

  # Publish UPS status to MQTT — ported from apcaccess to NUT's `upsc` (NIX-297).
  #
  # THE TOPIC AND THE PAYLOAD KEYS ARE A CONTRACT. Node-RED's UPS alerting (Telegram +
  # Pushover) reads exactly `upsname`, `model`, `status`, `bcharge` and `timeleft`, and
  # routes on `upsname`. Swapping apcupsd for NUT must be INVISIBLE downstream, so this
  # translates NUT's variable names back into the established shape rather than making
  # every consumer chase the rename.
  #
  # Fixed on the way past: the old awk emitted values WITH THEIR UNITS ("84.0 Percent",
  # "65.6 Minutes"), while the alert template does `bcharge & " % (" & timeleft & " min)"`
  # — so a real alert would have read "84.0 Percent % (65.6 Minutes min)". The flow's own
  # `testvalues` node uses plain numbers (bcharge: 85, timeleft: 120); that is the shape
  # it was always meant to receive. bcharge is now a number, and timeleft is a number in
  # MINUTES (NUT reports runtime in seconds).
  systemd.services.ups-mqtt-publish = {
    description = "Publish UPS status (NUT) to MQTT";
    after = [
      "upsd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.coreutils
      pkgs.jq
      pkgs.gnugrep
      pkgs.gawk
    ];
    script = ''
      set -euo pipefail

      # shellcheck source=/dev/null  # agenix-materialized, absent at lint time
      source ${config.age.secrets.mqtt-hsb0.path}

      # `upsc` prints "var: value" lines. If the driver is not talking to the UPS this
      # fails outright — which is correct: publishing a cheerful stale payload while the
      # UPS is unreachable is exactly how a dead UPS goes unnoticed for seven weeks.
      raw="$(${config.power.ups.package}/bin/upsc eaton 2>/dev/null || true)"

      get() { printf '%s\n' "$raw" | ${pkgs.gnugrep}/bin/grep -m1 "^$1:" | ${pkgs.gnused}/bin/sed "s|^$1: ||" || true; }

      if [ -z "$raw" ]; then
        # Say so, loudly and in-band, instead of going quiet. A consumer that stops
        # hearing from us cannot tell "all is well" from "the publisher died".
        status="COMMLOST"
        model=""; bcharge=0; timeleft=0; linev=0; battv=0; loadpct=0; serial=""
      else
        model="$(get 'device.model')"; [ -n "$model" ] || model="$(get 'ups.model')"
        serial="$(get 'device.serial')"; [ -n "$serial" ] || serial="$(get 'ups.serial')"
        bcharge="$(get 'battery.charge')"; bcharge="''${bcharge:-0}"
        runtime="$(get 'battery.runtime')"; runtime="''${runtime:-0}"
        timeleft="$(${pkgs.gawk}/bin/awk -v s="$runtime" 'BEGIN{printf "%.1f", s/60}')"
        linev="$(get 'input.voltage')"; linev="''${linev:-0}"
        battv="$(get 'battery.voltage')"; battv="''${battv:-0}"
        loadpct="$(get 'ups.load')"; loadpct="''${loadpct:-0}"

        # NUT's ups.status is a terse flag string (OL, OB, OB LB, OL CHRG ...). The alert
        # message says "<model> is now <status>", so it must read like something a human
        # wrote. Mapped to the apcupsd vocabulary the consumers already know.
        nutstat="$(get 'ups.status')"
        case "$nutstat" in
          *LB*)   status="LOWBATT" ;;
          *OB*)   status="ONBATT" ;;
          *OL*)   status="ONLINE" ;;
          "")     status="UNKNOWN" ;;
          *)      status="$nutstat" ;;
        esac
      fi

      # `upsname` is the ROUTING KEY: Node-RED sets msg.topic from it and switches on
      # "ups350vr". Keep it, or the alerts silently stop matching — which is precisely
      # the bug that left this UPS unwatched for seven weeks.
      payload="$(${pkgs.jq}/bin/jq -n \
        --arg upsname "ups350vr" \
        --arg hostname "hsb0" \
        --arg model    "''${model:-Eaton Ellipse PRO 650 DIN}" \
        --arg status   "$status" \
        --arg serialno "$serial" \
        --arg nutstat  "''${nutstat:-}" \
        --argjson bcharge  "''${bcharge:-0}" \
        --argjson timeleft "''${timeleft:-0}" \
        --argjson linev    "''${linev:-0}" \
        --argjson battv    "''${battv:-0}" \
        --argjson loadpct  "''${loadpct:-0}" \
        --argjson published "$(date +%s%3N)" \
        '{upsname:$upsname, hostname:$hostname, model:$model, status:$status,
          bcharge:$bcharge, timeleft:$timeleft, linev:$linev, battv:$battv,
          loadpct:$loadpct, serialno:$serialno, nut_status:$nutstat,
          driver:"usbhid-ups", __published:$published}')"

      ${pkgs.mosquitto}/bin/mosquitto_pub \
        --topic home/vr/battery/ups350 \
        -u "$MQTT_USER" -P "$MQTT_PASS" -h "$MQTT_HOST" \
        -m "$payload"
    '';
    serviceConfig = {
      Type = "oneshot";
      # root: reads the agenix MQTT secret
    };
  };

  # Timer: Run every minute
  systemd.timers.ups-mqtt-publish = {
    description = "Timer for APC UPS MQTT publishing";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      Unit = "ups-mqtt-publish.service";
    };
  };

  # AdGuard Home - DNS and DHCP server with ad-blocking
  # Web interface: http://192.168.1.99:3000
  services.adguardhome = {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    mutableSettings = false; # Use declarative configuration
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        # Use Cloudflare DNS as upstream
        bootstrap_dns = [
          "1.1.1.1"
          "1.0.0.1"
        ];
        upstream_dns = [
          "1.1.1.1"
          "1.0.0.1"
        ];
        # Enable DNS cache
        cache_size = 4194304; # 4MB
        cache_ttl_min = 0;
        cache_ttl_max = 0;
        cache_optimistic = true;
      };

      rewrites = [ ];

      # Custom filtering rules: allowlist + DNS rewrites
      user_rules = dnsAllowlist ++ dnsRewrites;

      users = [
        {
          name = "admin";
          # NOTE: Bcrypt hash intentionally inline - AdGuard Home requires password in config.
          # This is an accepted tradeoff since bcrypt is resistant to reversal and
          # the hash is already in git history. The actual password is in 1Password.
          password = "$2y$05$6tWeTokm6nLLq7nTIpeQn.J9ln.4CWK9HDyhJzY.w6qAk4CmEpUNy";
        }
      ];

      dhcp = {
        enabled = true;
        interface_name = "enp2s0f0";
        dhcpv4 = {
          gateway_ip = "192.168.1.1";
          subnet_mask = "255.255.255.0";
          range_start = "192.168.1.201";
          range_end = "192.168.1.254";
          lease_duration = 86400; # 24 hours
          icmp_timeout_msec = 1000;

          # Add DHCP Option 15 (domain name)
          # Format: "option_code type value"
          # See: https://github.com/AdguardTeam/AdGuardHome/wiki/DHCP
          options = [
            "15 text lan"
          ];

          # Static DHCP leases are managed via agenix and loaded at runtime
          # See preStart script below for implementation
          static_leases = [ ];
        };
      };

      # Filtering settings
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
      };

      # Query log settings
      querylog = {
        enabled = true;
        interval = "2160h"; # 90 days
        size_memory = 1000;
      };

      # Statistics
      statistics = {
        enabled = true;
        interval = "2160h"; # 90 days
      };
    };
  };

  # Static DHCP Leases Management
  # Leases are stored encrypted in git and decrypted at system activation
  systemd.services.adguardhome.preStart = lib.mkAfter ''
    leases_dir="/var/lib/private/AdGuardHome/data"
    leases_file="$leases_dir/leases.json"
    install -d "$leases_dir"

    # Read static leases from agenix-decrypted JSON file
    # Agenix automatically decrypts to /run/agenix/<secret-name>
    static_leases_file="/run/agenix/static-leases-hsb0"

    # Validate that the agenix secret file exists
    if [ ! -f "$static_leases_file" ]; then
      echo "ERROR: Static leases file not found at $static_leases_file"
      echo "This should have been decrypted by agenix during activation."
      exit 1
    fi

    # Validate JSON format
    if ! ${pkgs.jq}/bin/jq empty "$static_leases_file" 2>/dev/null; then
      echo "ERROR: Invalid JSON in static leases file: $static_leases_file"
      echo "Use 'agenix -e secrets/static-leases-hsb0.age' to fix the format."
      exit 1
    fi

    # Merge static leases with existing dynamic leases
    tmp="$(mktemp)"

    if [ -f "$leases_file" ]; then
      # Merge: keep dynamic leases, replace/add static leases
      ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_leases_file")" '
        def normalize_mac($mac): ($mac | ascii_downcase);
        def static_entries: $static | map(.mac |= normalize_mac(.));
        def without_static($list):
          ($list // [])
          | map(
              (.mac | ascii_downcase) as $m
              | (.static // false) as $is_static
              | (static_entries | map(.mac) | index($m)) as $idx
              | select($idx == null and ($is_static | not))
            );
        def build_static:
          static_entries | map(. + {static: true, expires: ""});
        {version: (.version // 1), leases: without_static(.leases) + build_static}
      ' "$leases_file" > "$tmp"
    else
      # First run: create leases file with static entries only
      ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_leases_file")" '
        {version: 1, leases: ($static | map(. + {static: true, expires: ""}))}
      ' <<< '{}' > "$tmp"
    fi

    # Atomic update
    mv "$tmp" "$leases_file"
    echo "✓ Loaded $(${pkgs.jq}/bin/jq '[.leases[] | select(.static == true)] | length' "$leases_file") static DHCP leases"
  '';

  # Networking configuration - Triple redundancy for core infrastructure
  # 1. /etc/hosts: Immediate resolution without network/DNS dependency
  # 2. Search domain (.lan): Client-side domain appending
  # 3. DNS server (AdGuard Home): Full DNS resolution with blocking/filtering
  # Critical devices get guaranteed resolution even if DNS server fails
  networking = {
    # Use localhost for DNS since AdGuard Home runs locally
    nameservers = [ "127.0.0.1" ];
    search = [ "lan" ];
    defaultGateway = "192.168.1.1";

    # Critical infrastructure hosts - guaranteed resolution via /etc/hosts
    # Provides fallback when DNS server (AdGuard Home) is unavailable
    # Both short names and FQDNs for maximum compatibility
    hosts = {
      # Network switch - core infrastructure, must be reachable for network management
      "192.168.1.3" = [
        "vr-netgear-gs724"
        "vr-netgear-gs724.lan"
      ];
      # Router/gateway - internet access, must work even during DNS outages
      "192.168.1.5" = [
        "vr-fritz-box"
        "vr-fritz-box.lan"
      ];
      # Solar battery storage - power monitoring, critical for energy management
      "192.168.1.32" = [
        "kr-sonnen-batteriespeicher"
        "kr-sonnen-batteriespeicher.lan"
      ];
      # This DNS/DHCP server itself - self-resolution for services and management
      "192.168.1.99" = [
        "hsb0"
        "hsb0.lan"
      ];
      # Home automation server + MQTT broker - runs Node-RED, Home Assistant, cameras, notifications + MQTT for IoT devices
      "192.168.1.101" = [
        "hsb1"
        "hsb1.lan"
        "mosquitto"
        "mosquitto.lan"
      ];
      # Smart home controller - for controlling lights, roller-blinds, ... and expose them to HomeKit as bridge
      "192.168.1.102" = [
        "vr-opus-gateway"
        "vr-opus-gateway.lan"
      ];
      # Smart home status display 1 - shows system health and status information
      "192.168.1.159" = [
        "wz-pixoo-64-00"
        "wz-pixoo-64-00.lan"
      ];
      # Smart home status display 2 - shows system health and status information
      "192.168.1.189" = [
        "wz-pixoo-64-01"
        "wz-pixoo-64-01.lan"
      ];
    };
    interfaces.enp2s0f0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.99";
          prefixLength = 24;
        }
      ];
    };
    # Firewall configuration for DNS/DHCP server
    firewall = {
      enable = true;
      allowedTCPPorts = [
        53 # DNS
        3000 # AdGuard Home web interface
        3001 # Uptime Kuma web interface
        8501 # NCPS binary cache proxy
        18789 # OpenClaw Gateway (Merlin + Nimue AI agents)
        80 # HTTP (for future use)
        443 # HTTPS (for future use)
      ];
      allowedUDPPorts = [
        53 # DNS
        67 # DHCP
        41641 # Tailscale WireGuard
      ];
    };
  };

  # ============================================================================
  # Uptime Kuma - Service Monitoring
  # ============================================================================
  # Monitors service uptime and availability. Web interface: http://192.168.1.99:3001
  # Uses native NixOS service (no Docker required).
  # ============================================================================
  services.uptime-kuma = {
    enable = true;
    settings = {
      PORT = "3001";
      HOST = "0.0.0.0"; # Listen on all interfaces
    };
  };

  # Apprise support for Uptime Kuma with Environment Variable expansion.
  # This allows using $VAR_NAME in the Apprise URL within the Uptime Kuma UI.
  # Tokens are stored securely in agenix and expanded by the wrapper script.
  systemd.services.uptime-kuma = {
    path = [
      (pkgs.writeShellScriptBin "apprise" ''
        # Apprise Wrapper for Environment Variable Expansion
        # Usage in Uptime Kuma UI: tgram://$TELEGRAM_TOKEN/ChatID

        args=()
        for arg in "$@"; do
          # Use envsubst to safely expand environment variables
          # We provide the variables from the EnvironmentFile
          expanded_arg=$(echo "$arg" | ${pkgs.gettext}/bin/envsubst)
          args+=("$expanded_arg")
        done

        exec ${pkgs.apprise}/bin/apprise "''${args[@]}"
      '')
    ];
    serviceConfig.EnvironmentFile = [ config.age.secrets.uptime-kuma-env.path ];
  };

  # Enable Fwupd for firmware updates
  # https://nixos.wiki/wiki/Fwupd
  services.fwupd.enable = true;

  # Tailscale VPN client (connects to headscale on csb0)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client"; # Client mode only
  };

  # Additional system packages for DNS/DHCP server
  environment.systemPackages = with pkgs; [
    # Network diagnostic tools
    dig
    tcpdump
    nmap
    # UPS monitoring
    apcupsd # For apcaccess CLI
    mosquitto # For mosquitto_sub debugging
    # Secret management tools
    rage # Modern age encryption tool (for agenix)
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default # agenix CLI
    # Notifications
    apprise # Apprise CLI for Uptime Kuma and manual alerts
  ];

  # Agenix secrets configuration
  # Static DHCP leases: encrypted JSON array in git, decrypted at activation
  # Format: [{"mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.100", "hostname": "device-name"}]
  # Edit with: agenix -e secrets/static-leases-hsb0.age
  age.secrets.static-leases-hsb0 = {
    file = ../../secrets/static-leases-hsb0.age;
    # Agenix creates /run/agenix/static-leases-hsb0 automatically
    # The 'path' attribute is optional and defaults to /run/agenix/<secret-name>
    mode = "444"; # World-readable (not sensitive data, just DHCP assignments)
    owner = "root";
    group = "root";
  };

  # Uptime Kuma secrets (e.g., APPRISE_TELEGRAM_TOKEN)
  age.secrets.uptime-kuma-env = {
    file = ../../secrets/uptime-kuma-env.age;
    mode = "400";
    owner = "root";
  };

  # NCPS signing key for binary cache proxy
  age.secrets.ncps-key = {
    file = ../../secrets/ncps-key.age;
    mode = "400";
    owner = "root";
  };

  # Restic Hetzner secrets (shared sub1)
  age.secrets.restic-hetzner-env = {
    file = ../../secrets/restic-hetzner-env.age;
    mode = "444";
  };

  age.secrets.restic-hetzner-ssh-key = {
    file = ../../secrets/restic-hetzner-ssh-key.age;
    mode = "444";
  };

  # Uptime Kuma API key for Merlin (read monitors, create incidents)
  age.secrets.hsb0-uptime-kuma-api-key = {
    file = ../../secrets/hsb0-uptime-kuma-api-key.age;
    mode = "444";
  };

  age.secrets.hsb0-speedtest-tracker-app-key = {
    file = ../../secrets/hsb0-speedtest-tracker-app-key.age;
    mode = "400";
    owner = "root";
    group = "root";
  };

  # ============================================================================
  # OpenClaw Merlin - AI assistant via Telegram
  # ============================================================================
  # Runs in Docker via docker-compose (hosts/hsb0/docker/docker-compose.yml).
  # Secrets mounted as files in container (mode 444 for node user access).
  # Data persisted at /var/lib/openclaw-merlin/

  age.secrets.hsb0-elevenlabs-api-key = {
    file = ../../secrets/hsb0-elevenlabs-api-key.age;
    mode = "444";
  };
  age.secrets.hsb0-groq-api-key = {
    file = ../../secrets/hsb0-groq-api-key.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-gateway-token = {
    file = ../../secrets/hsb0-openclaw-gateway-token.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-telegram-token = {
    file = ../../secrets/hsb0-openclaw-telegram-token.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-openrouter-key = {
    file = ../../secrets/hsb0-openclaw-openrouter-key.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-hass-token = {
    file = ../../secrets/hsb0-openclaw-hass-token.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-brave-key = {
    file = ../../secrets/hsb0-openclaw-brave-key.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-icloud-password = {
    file = ../../secrets/hsb0-openclaw-icloud-password.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-opus-gateway = {
    file = ../../secrets/hsb0-openclaw-opus-gateway.age;
    mode = "444";
  };
  age.secrets.hsb0-gogcli-keyring-password = {
    file = ../../secrets/hsb0-gogcli-keyring-password.age;
    mode = "444";
  };
  age.secrets.hsb0-openclaw-github-pat = {
    file = ../../secrets/hsb0-openclaw-github-pat.age;
    mode = "444";
  };

  # Merlin SSH key for accessing hsb1 (home automation host)
  age.secrets.hsb0-merlin-ssh-key = {
    file = ../../secrets/hsb0-merlin-ssh-key.age;
    mode = "444"; # Readable by container (node user, uid 1000)
  };

  # Nimue agent secrets (second agent in openclaw-gateway)
  age.secrets.hsb0-nimue-telegram-token = {
    file = ../../secrets/hsb0-nimue-telegram-token.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-github-pat = {
    file = ../../secrets/hsb0-nimue-github-pat.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-icloud-password = {
    file = ../../secrets/hsb0-nimue-icloud-password.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-gogcli-keyring-password = {
    file = ../../secrets/hsb0-nimue-gogcli-keyring-password.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-gogcli-credentials = {
    file = ../../secrets/hsb0-nimue-gogcli-credentials.age;
    mode = "444";
  };

  # M365 calendar (read-only) - Azure AD app: Merlin-AI-hsb0-cal
  # TODO: Uncomment when Azure AD app is created and .age files exist
  # age.secrets.hsb0-openclaw-m365-cal-client-id = {
  #   file = ../../secrets/hsb0-openclaw-m365-cal-client-id.age;
  #   mode = "444";
  # };
  # age.secrets.hsb0-openclaw-m365-cal-tenant-id = {
  #   file = ../../secrets/hsb0-openclaw-m365-cal-tenant-id.age;
  #   mode = "444";
  # };
  # age.secrets.hsb0-openclaw-m365-cal-client-secret = {
  #   file = ../../secrets/hsb0-openclaw-m365-cal-client-secret.age;
  #   mode = "444";
  # };

  # OpenClaw Gateway data directories — multi-agent (Merlin + Nimue).
  # openclaw.json is git-managed (see docker/openclaw-gateway/openclaw.json).
  # The entrypoint script deploys it on every container start (with timestamped backup).
  system.activationScripts.openclaw-gateway = ''
    # One-time migration: move old Merlin data to new unified path
    if [ -d /var/lib/openclaw-merlin ] && [ ! -d /var/lib/openclaw-gateway ]; then
      echo "[migration] Moving /var/lib/openclaw-merlin -> /var/lib/openclaw-gateway/data"
      mkdir -p /var/lib/openclaw-gateway
      mv /var/lib/openclaw-merlin/data /var/lib/openclaw-gateway/data
      mv /var/lib/openclaw-merlin/vdirsyncer /var/lib/openclaw-gateway/merlin-vdirsyncer
      mv /var/lib/openclaw-merlin/khal /var/lib/openclaw-gateway/merlin-khal
      mv /var/lib/openclaw-merlin/gogcli /var/lib/openclaw-gateway/merlin-gogcli
    fi

    mkdir -p /var/lib/openclaw-gateway/data/workspace-merlin
    mkdir -p /var/lib/openclaw-gateway/data/workspace-nimue
    mkdir -p /var/lib/openclaw-gateway/data/agents/merlin/agent
    mkdir -p /var/lib/openclaw-gateway/data/agents/merlin/sessions
    mkdir -p /var/lib/openclaw-gateway/data/agents/nimue/agent
    mkdir -p /var/lib/openclaw-gateway/data/agents/nimue/sessions
    mkdir -p /var/lib/openclaw-gateway/data/media/inbound
    mkdir -p /var/lib/openclaw-gateway/data/media/outbound
    mkdir -p /var/lib/openclaw-gateway/merlin-vdirsyncer
    mkdir -p /var/lib/openclaw-gateway/merlin-khal
    mkdir -p /var/lib/openclaw-gateway/merlin-gogcli
    mkdir -p /var/lib/openclaw-gateway/nimue-vdirsyncer
    mkdir -p /var/lib/openclaw-gateway/nimue-khal
    mkdir -p /var/lib/openclaw-gateway/nimue-gogcli
    chown -R 1000:1000 /var/lib/openclaw-gateway/
  '';

  # ============================================================================
  # HostDash — static LAN service dashboard for hsb0
  # ============================================================================
  # hsb0's existing compose stack is not fully systemd-owned yet; at least one
  # live bridge container predates compose labels. Keep this unit narrow and
  # reconcile only the dashboard service instead of adopting the whole stack.
  systemd.services.hsb0-home-dashboard = {
    description = "hsb0 HostDash nginx dashboard";
    after = [
      "docker.service"
      "network-online.target"
    ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      (builtins.readFile ./docker/docker-compose.yml)
      hostdashHsb0
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose -p docker -f /home/mba/Code/nixcfg/hosts/hsb0/docker/docker-compose.yml up -d --force-recreate --no-deps hsb0-home";
      TimeoutStartSec = "180";
    };
  };

  environment.etc."hostdash/hsb0".source = hostdashHsb0;

  # ============================================================================
  # NCPS - Nix binary Cache Proxy Service
  # ============================================================================
  # Local binary cache that proxies and caches upstream stores.
  # Speeds up rebuilds across the home LAN and reduces WAN bandwidth.
  # Web UI / Stats: http://192.168.1.99:8501
  #
  # MIGRATED TO DOCKER (2026-01-11): Native service removed to avoid migration issues.
  # See: hosts/hsb0/docker/docker-compose.yml
  # ============================================================================

  # RESILIENCE: NCPS container data must depend on its ZFS mount.
  # We keep the mount defined here so systemd manages it.
  systemd.services.docker-ncps = {
    requires = [ "var-lib-ncps.mount" ];
    after = [ "var-lib-ncps.mount" ];
  };

  # Fresh-install ownership for ncps paths. ncps runs as uid 994 (kalbasit/ncps
  # image). /storage (the ZFS mount) and the decoupled /dbstorage dir must be
  # writable by 994 or the container crash-loops on first start — docker would
  # otherwise auto-create /var/lib/ncps-db as root:root. tmpfiles is idempotent;
  # live hosts already have these (set once, persisted on-disk).
  systemd.tmpfiles.rules = [
    "d /var/lib/ncps    0700 994 992 - -"
    "d /var/lib/ncps-db 0755 994 992 - -"
  ];

  # Fix: P6400 / P5012 - Remove evaluation warning by forcing null on initialHashedPassword
  users.users.mba.initialHashedPassword = lib.mkForce null;

  # ============================================================================
  # Cache Warmer — populate local NCPS with the LAN fleet's substitutable deps
  # ============================================================================
  # NIX-155: the previous warmer used `nix build --dry-run`, which downloads
  # NOTHING (it only evaluates) — so NCPS was never actually warmed (proven: a
  # real run transferred 0 bytes). This rewrite does a REAL warm.
  #
  # How it works, per host config:
  #   1. `nix build --dry-run` to split the closure into "will be built"
  #      (host-specific, unwarmable) and "will be fetched" (substitutable deps).
  #   2. Realise ONLY the substitutable set THROUGH ncps (substituters overridden
  #      to ncps), so ncps proxies + caches each NAR from its upstreams. The
  #      host toplevel itself is never on a public cache (built per-host), so we
  #      deliberately warm the dependency closure, not the toplevel.
  #   3. `--max-jobs 0` => never build, substitute only. This is what lets the
  #      darwin (macOS) configs warm on this x86_64-linux host: their prebuilt
  #      NARs are fetched, nothing is compiled.
  #
  # Host list is STATIC and LAN-only by design: offsite hosts (csb0/csb1/
  # hsb8/hsb9) do not pull from this cache, so warming them is pointless.
  # Future: define the "local fleet" set in FleetCom and generate this list
  # (tracked in NIX-155).
  #
  # Schedule: Sat & Mon 04:00. ncps LRU now runs every 6h (00/06/12/18) for
  # deadlock safety (see docker-compose.yml), so a warm is trimmed within ~2h;
  # acceptable trade — recently-USED paths survive LRU, and never wedging the
  # cache matters more than a warmed-but-unused path surviving the full day.
  # ============================================================================
  systemd.services.ncps-warmer = {
    description = "Warm local NCPS with LAN fleet substitutable closures";
    after = [
      "ncps.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.nix
      pkgs.git
      pkgs.openssh # git pull uses the ssh remote (git-personal:); without it: "cannot run ssh"
      pkgs.gawk
      pkgs.findutils
      pkgs.coreutils
    ];
    script = ''
      set -uo pipefail
      NCPS="http://hsb0.lan:8501"
      REPO="/home/mba/Code/nixcfg"

      # Warm the latest committed fleet state, not just whatever was last
      # switched. Read-only ff pull; never auto-update the flake lock.
      git -C "$REPO" pull --ff-only || echo "warmer: git pull skipped (dirty/no-ff)"
      cd "$REPO"

      warm() {
        name="$1"; ref="$2"
        # Substitutable closure paths only ("will be fetched"); the
        # "will be built" host-specific derivations are skipped.
        paths="$(nix build "$ref" --dry-run 2>&1 \
          | awk '/will be fetched/{f=1;next} /will be built/{f=0} f && /\/nix\/store\//{gsub(/^ +/,"");print}')"
        if [ -z "$paths" ]; then
          echo "warmer: $name — nothing to fetch (already cached)"; return 0
        fi
        n="$(printf '%s\n' "$paths" | wc -l)"
        if printf '%s\n' "$paths" \
          | xargs nix-store --realise --option substituters "$NCPS" --option max-jobs 0 >/dev/null 2>&1; then
          echo "warmer: $name — warmed $n paths"
        else
          echo "warmer: $name — PARTIAL ($n paths attempted; some unsubstitutable)"
        fi
      }

      # STATIC LAN list (NIX-155). NixOS hosts:
      warm gpc0      ".#nixosConfigurations.gpc0.config.system.build.toplevel"
      warm hsb1      ".#nixosConfigurations.hsb1.config.system.build.toplevel"
      warm hsb0      ".#nixosConfigurations.hsb0.config.system.build.toplevel"
      # macOS Home-Manager hosts (warm their prebuilt deps; no darwin builder needed):
      warm mbp0      '.#homeConfigurations."mba@mbp0".activationPackage'
      echo "warmer: done"
    '';
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/home/mba/Code/nixcfg";
      User = "mba";
      TimeoutStartSec = "3h";
      # Be gentle on the family server during the warm.
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUWeight = 20;
    };
  };

  systemd.timers.ncps-warmer = {
    description = "Timer for NCPS Cache Warmer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Sat & Mon 04:00 — after the 03:00 LRU so warmed paths aren't trimmed.
      OnCalendar = [
        "Sat 04:00:00"
        "Mon 04:00:00"
      ];
      Persistent = true;
      Unit = "ncps-warmer.service";
    };
  };

  # NIX-280 — the host answers for its own services, because a browser cannot.
  # Same rationale as hsb1: HostDash's browser probe returns an OPAQUE response and
  # can neither read a status code nor see a service that has no HTTP endpoint at all.
  services.hostdash.status = {
    enable = true;
    host = "hsb0";
    units = [
      # The LAN's DNS. Everything `.lan` resolves through this one service — if it is
      # down, every hostname on the network dies with it, and a dashboard that could
      # not see that would be worse than useless.
      "adguardhome.service"
      # The UPS daemon (NIX-135: the APC unit itself is faulty and is being replaced
      # by an Eaton, at which point this becomes NUT — see NIX-297).
      #
      # CAVEAT worth knowing: `apcupsd.service` being "running" does NOT mean the UPS
      # is being monitored. As of 2026-07-14 it is `active` while apcaccess reports
      # STATUS: COMMLOST — the daemon is up and talking to nothing. The unit state is
      # the truth about the DAEMON, not about the UPS. Reporting UPS health properly
      # belongs with the NUT migration (NIX-297), where it can be published as real
      # telemetry rather than inferred from a process being alive.
      "apcupsd.service"
      "ups-mqtt-publish.timer" # publishes UPS state to MQTT
      "docker.service"
      "sshd.service"
    ];
  };

  hokage = {
    catppuccin.enable = false; # Use Tokyo Night theme instead
    hostName = "hsb0";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-home";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdb02";
    audio.enable = false;
    programs.git.enableUrlRewriting = false;
    # Point nixbit to Markus' repository (not pbek's default)
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
    # NOTE: atuin disabled in common.nix (via commonServerModules)
  };

  # NOTE: Starship configured in common.nix (via commonServerModules)

  # ============================================================================
  # StaSysMo - Starship System Monitoring
  # ============================================================================
  # Displays CPU, RAM, Load, Swap in the prompt with threshold-based coloring.
  # Daemon writes to /dev/shm/stasysmo/ every 5 seconds.
  # ============================================================================
  services.stasysmo.enable = true;

  # ============================================================================
  # 🚨 SSH KEY SECURITY
  # ============================================================================
  # The hokage server-home module auto-injects external SSH keys (omega@*).
  # We use lib.mkForce to REPLACE (not append) with our own keys only.
  # ============================================================================

  users.users.mba = {
    # 🚨 EMERGENCY RECOVERY PASSWORD — console/Tailscale access if SSH keys fail.
    # Per-host (NIX-198 standardisation, 2026-06-28): this hash mirrors the LIVE
    # /etc/shadow value, so config == reality and a reinstall reproduces it.
    # Plaintext in 1Password vault "Familie Barta", entry "hsb0 - system login".
    # (Previously the shared $6$ csb hash, which had drifted: a per-host passwd-set
    # password superseded it on the box. INSPR-79 first added a password fallback
    # here; relates to INSPR-78 per-host ed25519 / INSPR-76 shared-RSA retirement.)
    hashedPassword = "$y$j9T$lKd1UYhEZwHblUnAS6i7t/$U.xxpSqoo9AHR/ejnqsbKnH.KweMQdOeyYmutRCGjm/";
    # NOTE: openssh.authorizedKeys.keys removed in INSPR-73 — the system-side
    # render is now declarative via inspr.ssh.authorized.users.mba below.
  };

  # 🚨 SSH PASSWORD AUTH FALLBACK (INSPR-79)
  # hsb0 is home-LAN only (no public IP, accessible only via Tailscale +
  # actual home network), so password auth is acceptable risk for the
  # defence-in-depth recovery path. Pairs with the hashedPassword above.
  # See INSPR-80 for the longer-term keep-or-remove decision applying to
  # this and the equivalent csb0/csb1/msbp settings.
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  # ============================================================================
  # INSPR-73 (2026-05-04) — Declarative SSH inbound trust (NixOS + HM)
  # ============================================================================
  # System-side: inspr-modules nixosModules.ssh-authorized renders into
  # users.users.mba.openssh.authorizedKeys.keys → /etc/ssh/authorized_keys.d/mba.
  # HM-side: inspr-modules homeManagerModules.ssh-authorized renders into
  # ~/.ssh/authorized_keys (marker block).
  # Both consume the same shared keyring at modules/shared/ssh-keyring.nix.
  #
  # force = true here — hsb0 hokage-injects external operator keys we do
  # NOT want admitted on this private/family host. mkForce-wrap drops them.
  # (Defence-in-depth: matches the lib.mkForce posture the previous manual
  # declaration used.)
  inspr.ssh.authorized = {
    enable = true;
    users.mba = {
      trust = config._inspr.trustPresets.personalHosts;
      force = true;
    };
  };

  home-manager.users.mba =
    { config, ... }:
    {
      imports = [
        inputs.inspr-modules.homeManagerModules.ssh-authorized
        ../../modules/shared/ssh-authorized.nix
      ];
      inspr.ssh.authorized = {
        enable = true;
        trust = config._inspr.trustPresets.personalHosts;
      };
    };

  # ============================================================================
  # 🚨 PASSWORDLESS SUDO - Also lost when removing serverMba mixin
  # ============================================================================
  # The serverMba mixin provided passwordless sudo, which is also lost.
  # Re-enable it explicitly to prevent sudo failures.
  # ============================================================================

  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # NIXFLEET AGENT - Disabled (decommissioned, replaced by FleetCom DSC26-52)
  # ============================================================================
  # age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;

  # services.nixfleet-agent = {
  #   enable = true;
  #   url = "wss://fleet.barta.cm/ws";
  #   interval = 5;
  #   tokenFile = "/run/agenix/nixfleet-token";
  #   repoUrl = "https://github.com/markus-barta/nixcfg.git";
  #   user = "mba";
  #   logLevel = "info";
  #   location = "home";
  #   deviceType = "server";
  # };

  # Pharos beacon per-host token. Docker Compose reads it as an env_file.
  age.secrets.pharos-beacon-hsb0-env = {
    file = ../../secrets/pharos-beacon-hsb0-env.age;
    path = "/run/agenix/pharos-beacon-hsb0-env";
    owner = "mba";
    group = "users";
    mode = "0400";
  };

  # PPM (Personal Project Management) API key for Merlin/Nimue at pm.barta.cm.
  # Mounted into openclaw-gateway via docker-compose.yml; entrypoint.sh exports
  # as PPMAPIKEY (variable name matches the inspr.secrets.agents convention:
  # ~/Secrets/age/decrypted/agents/PPMAPIKEY.env on workstations).
  # mode = "444" matches sibling container-mounted secrets so node user (uid
  # 1000) inside openclaw-gateway can read it.
  age.secrets.hsb0-ppm-api-key = {
    file = ../../secrets/hsb0-ppm-api-key.age;
    mode = "444";
  };
}
