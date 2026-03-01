/**
 * Clock scene for AWTRIX 32x8 display
 * Shows current time with optional seconds
 * Uses AWTRIX drawCustom API for efficient rendering
 */

export default {
  name: "clock",
  description: "Digital clock with seconds",

  async render(device) {
    const now = new Date();
    const hours = String(now.getHours()).padStart(2, "0");
    const minutes = String(now.getMinutes()).padStart(2, "0");
    const seconds = String(now.getSeconds()).padStart(2, "0");

    // Format: HH:MM or HH:MM:SS (alternate every second)
    const showSeconds = now.getSeconds() % 2 === 0;
    const timeText = showSeconds
      ? `${hours}:${minutes}:${seconds}`
      : `${hours}:${minutes}`;

    // Use AWTRIX draw API with centered text
    await device.drawCustom({
      text: timeText,
      color: "#00FF00", // Green
      center: true,
      rainbow: false,
    });

    // Return 1000ms for next update
    return 1000;
  },
};
