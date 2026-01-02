#!/usr/bin/env python3
"""Child Keyboard Fun - Standalone script for ACME BK03 keyboard"""
import evdev
import subprocess
import os
import random
import sys
import time
from pathlib import Path
import json

try:
    import paho.mqtt.client as mqtt
    MQTT_AVAILABLE = True
except ImportError:
    MQTT_AVAILABLE = False
    print("Warning: paho-mqtt not available, MQTT logging disabled")


# Global state for debouncing and process management
last_key_time = {}  # Per-key debounce
last_any_key_time = 0  # Global debounce
active_processes = []  # Track running audio processes
DEBOUNCE_SECONDS = 1.0  # 1 second debounce
mqtt_client = None  # MQTT client for debug logging
last_key_pressed = None  # Track last key for status updates


def get_battery_level(device):
    """Get battery level from device if available"""
    try:
        # Try to read battery level from device capabilities
        if hasattr(device, 'capabilities'):
            caps = device.capabilities(verbose=True)
            # Battery info is usually in EV_PWR or via sysfs
        # For Bluetooth devices, check sysfs
        device_path = device.path
        # Extract event number (e.g., event0 -> 0)
        event_num = device_path.split('event')[-1]
        battery_path = f"/sys/class/power_supply/hid-{device.info.bustype:02x}:{device.info.vendor:04x}:{device.info.product:04x}.{event_num}/capacity"
        if os.path.exists(battery_path):
            with open(battery_path, 'r') as f:
                return int(f.read().strip())
    except Exception:
        pass
    return None


def mqtt_log(message, level="info"):
    """Send debug log to MQTT topic"""
    global mqtt_client
    if mqtt_client and mqtt_client.is_connected():
        try:
            payload = {
                "timestamp": time.time(),
                "level": level,
                "message": message
            }
            mqtt_client.publish(
                "home/hsb1/keyboard-fun/debug",
                json.dumps(payload),
                qos=0
            )
        except Exception as e:
            print(f"MQTT log error: {e}", flush=True)


def mqtt_publish_status(device, key_name=None, sound_file=None):
    """Publish status update to MQTT"""
    global mqtt_client, last_key_pressed
    if mqtt_client and mqtt_client.is_connected():
        try:
            battery = get_battery_level(device)
            payload = {
                "timestamp": time.time(),
                "last_key": key_name or last_key_pressed,
                "battery_level": battery,
                "sound_playing": os.path.basename(sound_file) if sound_file else None
            }
            mqtt_client.publish(
                "home/hsb1/keyboard-fun/status",
                json.dumps(payload),
                qos=0,
                retain=True
            )
        except Exception as e:
            print(f"MQTT status error: {e}", flush=True)


def load_env(env_file):
    """Simple .env file parser"""
    config = {}
    if not os.path.exists(env_file):
        print(f"Error: Config file {env_file} not found")
        sys.exit(1)

    with open(env_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip()
    return config


def get_sound_files(sound_dir):
    """Get list of audio files in directory"""
    if not os.path.exists(sound_dir):
        print(f"Warning: Sound directory {sound_dir} not found")
        return []
    wav_files = list(Path(sound_dir).glob('*.wav'))
    mp3_files = list(Path(sound_dir).glob('*.mp3'))
    return wav_files + mp3_files


def stop_all_sounds():
    """Stop all currently playing sounds"""
    global active_processes
    stopped_count = 0

    for proc in active_processes[:]:  # Copy list to iterate safely
        if proc.poll() is None:  # Still running
            try:
                proc.terminate()
                stopped_count += 1
            except Exception:
                pass
        active_processes.remove(proc)

    if stopped_count > 0:
        mqtt_log(f"Stopped {stopped_count} sound(s)")


def play_sound(sound_file, device=None):
    """Play sound via kiosk user's PipeWire (same as VLC)"""
    global active_processes

    print(f"DEBUG: play_sound() called with {sound_file}", flush=True)
    if not os.path.exists(sound_file):
        print(f"DEBUG: Sound file not found: {sound_file}", flush=True)
        mqtt_log(f"Sound file not found: {sound_file}", "error")
        return

    print(f"DEBUG: File exists, stopping old sounds", flush=True)
    # Stop all currently playing sounds first
    stop_all_sounds()

    print(f"DEBUG: Starting paplay subprocess", flush=True)
    # Run paplay directly (service runs as kiosk user with XDG_RUNTIME_DIR set)
    proc = subprocess.Popen([
        'paplay',
        '--volume=45875',  # ~70% volume
        str(sound_file)
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    active_processes.append(proc)
    print(f"DEBUG: Subprocess started, PID={proc.pid}", flush=True)
    
    # Check subprocess status after a brief moment
    time.sleep(0.1)
    if proc.poll() is not None:
        # Process already exited
        stdout, stderr = proc.communicate()
        print(f"DEBUG: paplay exited with code {proc.returncode}", flush=True)
        if stderr:
            print(f"DEBUG: paplay stderr: {stderr.decode()}", flush=True)
            mqtt_log(f"paplay error: {stderr.decode()}", "error")
    
    mqtt_log(f"Playing: {os.path.basename(sound_file)}")
    
    # Publish status update with battery level
    if device:
        mqtt_publish_status(device, sound_file=sound_file)


def should_process_key(key_name):
    """Check if key press should be processed (debouncing)"""
    global last_key_time, last_any_key_time

    current_time = time.time()

    # Check global debounce (any key)
    if current_time - last_any_key_time < DEBOUNCE_SECONDS:
        return False

    # Check per-key debounce
    if key_name in last_key_time:
        if current_time - last_key_time[key_name] < DEBOUNCE_SECONDS:
            return False

    # Update timestamps
    last_key_time[key_name] = current_time
    last_any_key_time = current_time
    return True


def find_device_by_name(device_name):
    """Find input device by name"""
    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
    for device in devices:
        if device.name == device_name:
            return device.path
    return None


def main():
    global mqtt_client

    # Load configuration
    env_file = os.getenv('KEYBOARD_FUN_CONFIG', '/etc/child-keyboard-fun.env')
    config = load_env(env_file)

    device_path = config.get('KEYBOARD_DEVICE')
    sound_dir = config.get('SOUND_DIR')

    # If device path looks like a name (not starting with /), search for it
    if device_path and not device_path.startswith('/'):
        print(f"Searching for device by name: {device_path}", flush=True)
        found_path = find_device_by_name(device_path)
        if found_path:
            device_path = found_path
            print(f"Found device at: {device_path}", flush=True)
        else:
            print(f"Error: Device '{device_path}' not found", flush=True)
            sys.exit(1)

    if not device_path:
        print("Error: KEYBOARD_DEVICE not set in config")
        sys.exit(1)

    if not sound_dir:
        print("Error: SOUND_DIR not set in config")
        sys.exit(1)

    # Get available sound files
    sound_files = get_sound_files(sound_dir)
    if not sound_files:
        print(f"Warning: No audio files found in {sound_dir}")

    # Build key mapping from config
    key_mappings = {}
    for key, value in config.items():
        if key.startswith('KEY_'):
            key_name = key[4:]  # Remove 'KEY_' prefix
            key_mappings[key_name] = value

    print("Child Keyboard Fun starting...", flush=True)
    print(f"Device: {device_path}", flush=True)
    print(f"Sound directory: {sound_dir}", flush=True)
    print(f"Available sounds: {len(sound_files)}", flush=True)
    print(f"Key mappings: {len(key_mappings)}", flush=True)
    print(f"Debounce: {DEBOUNCE_SECONDS}s", flush=True)

    # Connect to MQTT for debug logging (non-blocking)
    if MQTT_AVAILABLE:
        try:
            mqtt_client = mqtt.Client()
            mqtt_host = os.getenv('MOSQITTO_HOST_HSB1', 'localhost')
            mqtt_user = os.getenv('MOSQITTO_USER_HSB1', 'smarthome')
            mqtt_pass = os.getenv('MOSQITTO_PASS_HSB1')
            if mqtt_pass:
                mqtt_client.username_pw_set(mqtt_user, mqtt_pass)
            mqtt_port = int(os.getenv('MQTT_PORT', '1883'))
            mqtt_client.connect_async(mqtt_host, mqtt_port, 60)
            mqtt_client.loop_start()
            print(f"MQTT connecting to {mqtt_host}:{mqtt_port} as {mqtt_user}...", flush=True)
            # Give it a moment to connect, but don't block
            time.sleep(0.5)
            if mqtt_client.is_connected():
                print("MQTT connected for debug logging", flush=True)
                mqtt_log("Keyboard Fun service started")
            else:
                print("MQTT connection pending (will retry in background)", flush=True)
        except Exception as e:
            print(f"MQTT connection failed: {e} (continuing without MQTT)", flush=True)
            mqtt_client = None
    else:
        print("MQTT not available, continuing without debug logging", flush=True)

    # Open the keyboard device
    try:
        device = evdev.InputDevice(device_path)
    except Exception as e:
        print(f"Error opening device {device_path}: {e}")
        mqtt_log(f"Error opening device: {e}", "error")
        sys.exit(1)

    print(f"Opened device: {device.name}", flush=True)
    mqtt_log(f"Opened device: {device.name}")
    
    # Note: We don't grab() because it causes Bluetooth keyboards to disconnect
    # Instead, udev rules prevent X/systemd-logind from accessing this device
    print("Device ready (udev-isolated from X)", flush=True)
    mqtt_log("Device ready (udev-isolated)")

    # Event loop
    print("Entering event loop...", flush=True)
    mqtt_log("Entering event loop")
    print(f"DEBUG: EV_KEY constant = {evdev.ecodes.EV_KEY}", flush=True)
    try:
        for event in device.read_loop():
            print(f"DEBUG: Got event type={event.type} code={event.code} value={event.value}", flush=True)
            if event.type == evdev.ecodes.EV_KEY:
                print(f"DEBUG: EV_KEY matched! Processing...", flush=True)
                key_event = evdev.categorize(event)
                print(f"DEBUG: keystate={key_event.keystate} key_down={evdev.KeyEvent.key_down}", flush=True)
                if key_event.keystate == evdev.KeyEvent.key_down:
                    print(f"DEBUG: Key down detected!", flush=True)
                    key_name = key_event.keycode
                    if isinstance(key_name, list):
                        key_name = key_name[0]

                    # Remove KEY_ prefix if present
                    if key_name.startswith('KEY_'):
                        key_name = key_name[4:]

                    print(f"DEBUG: Key name = {key_name}", flush=True)
                    
                    # Update global last key
                    global last_key_pressed
                    last_key_pressed = key_name
                    
                    mqtt_log(f"Key pressed: {key_name}")

                    # Special function: SPACE stops all sounds
                    if key_name == 'SPACE':
                        print(f"DEBUG: SPACE key - stopping sounds", flush=True)
                        mqtt_log("SPACE pressed - stopping all sounds")
                        stop_all_sounds()
                        continue

                    # Check debounce
                    print(f"DEBUG: Checking debounce for {key_name}", flush=True)
                    if not should_process_key(key_name):
                        print(f"DEBUG: Debounced {key_name}", flush=True)
                        continue

                    print(f"DEBUG: Passed debounce, checking mapping", flush=True)
                    # Check if key has specific mapping
                    if key_name in key_mappings:
                        print(f"DEBUG: Found mapping for {key_name}", flush=True)
                        action = key_mappings[key_name]
                        if action.startswith('sound:'):
                            # Play specific sound
                            sound_file = os.path.join(sound_dir, action[6:])
                            print(f"DEBUG: Playing specific sound: {sound_file}", flush=True)
                            play_sound(sound_file, device)
                        elif action == 'random':
                            # Play random sound
                            if sound_files:
                                sound_file = random.choice(sound_files)
                                print(f"DEBUG: Playing random sound: {sound_file}", flush=True)
                                play_sound(sound_file, device)
                    else:
                        # Default: play random sound
                        print(f"DEBUG: No mapping for {key_name}, playing random", flush=True)
                        if sound_files:
                            sound_file = random.choice(sound_files)
                            play_sound(sound_file, device)

    except KeyboardInterrupt:
        print("\nStopping...", flush=True)
        mqtt_log("Service stopping (KeyboardInterrupt)")
    except OSError as e:
        # Device disconnected (common with Bluetooth)
        print(f"Device error (likely disconnected): {e}", flush=True)
        mqtt_log(f"Device disconnected: {e}", "warning")
        # systemd will auto-restart the service
    except Exception as e:
        print(f"Error: {e}", flush=True)
        mqtt_log(f"Service error: {e}", "error")
    finally:
        stop_all_sounds()
        if mqtt_client:
            mqtt_client.loop_stop()
            mqtt_client.disconnect()


if __name__ == '__main__':
    main()

