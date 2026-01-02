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


def play_sound(sound_file):
    """Play sound via kiosk user's PipeWire (same as VLC)"""
    global active_processes

    if not os.path.exists(sound_file):
        mqtt_log(f"Sound file not found: {sound_file}", "error")
        return

    # Stop all currently playing sounds first
    stop_all_sounds()

    # Run paplay as kiosk user with XDG_RUNTIME_DIR set
    proc = subprocess.Popen([
        'sudo',
        '-u', 'kiosk',
        'env',
        'XDG_RUNTIME_DIR=/run/user/1001',
        'paplay',
        '--volume=45875',  # ~70% volume
        str(sound_file)
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    active_processes.append(proc)
    mqtt_log(f"Playing: {os.path.basename(sound_file)}")


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


def main():
    global mqtt_client

    # Load configuration
    env_file = os.getenv('KEYBOARD_FUN_CONFIG', '/etc/child-keyboard-fun.env')
    config = load_env(env_file)

    device_path = config.get('KEYBOARD_DEVICE')
    sound_dir = config.get('SOUND_DIR')

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

    # Connect to MQTT for debug logging
    if MQTT_AVAILABLE:
        try:
            mqtt_client = mqtt.Client()
            mqtt_client.connect("localhost", 1883, 60)
            mqtt_client.loop_start()
            print("MQTT connected for debug logging", flush=True)
            mqtt_log("Keyboard Fun service started")
        except Exception as e:
            print(f"MQTT connection failed: {e} (continuing without MQTT)", flush=True)
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

    # Event loop
    try:
        for event in device.read_loop():
            if event.type == evdev.ecodes.EV_KEY:
                key_event = evdev.categorize(event)
                if key_event.keystate == evdev.KeyEvent.key_down:
                    key_name = key_event.keycode
                    if isinstance(key_name, list):
                        key_name = key_name[0]

                    # Remove KEY_ prefix if present
                    if key_name.startswith('KEY_'):
                        key_name = key_name[4:]

                    mqtt_log(f"Key pressed: {key_name}")

                    # Special function: SPACE stops all sounds
                    if key_name == 'SPACE':
                        mqtt_log("SPACE pressed - stopping all sounds")
                        stop_all_sounds()
                        continue

                    # Check debounce
                    if not should_process_key(key_name):
                        continue

                    # Check if key has specific mapping
                    if key_name in key_mappings:
                        action = key_mappings[key_name]
                        if action.startswith('sound:'):
                            # Play specific sound
                            sound_file = os.path.join(sound_dir, action[6:])
                            play_sound(sound_file)
                        elif action == 'random':
                            # Play random sound
                            if sound_files:
                                sound_file = random.choice(sound_files)
                                play_sound(sound_file)
                    else:
                        # Default: play random sound
                        if sound_files:
                            sound_file = random.choice(sound_files)
                            play_sound(sound_file)

    except KeyboardInterrupt:
        print("\nStopping...", flush=True)
        mqtt_log("Service stopping (KeyboardInterrupt)")
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

