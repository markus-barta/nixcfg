(function () {
  "use strict";

  window.JoeVersion = Object.freeze({
    APP_VERSION: "0.2.0",
    VERSION_HISTORY: [
      {
        version: "0.2.0",
        date: "2026-09-10",
        title: "Board UX polish",
        changes: [
          "All three desks can show in history at once, with an All bots toggle and clearer Desks vs Range controls.",
          "Named layout save, load, rename, and delete; default layout stays available.",
          "Footer version history, US RTH shading, today marker, and more comfortable grid spacing.",
        ],
      },
      {
        version: "unversioned milestone",
        date: "2026-09-09",
        title: "Configurable GridStack household board",
        changes: [
          "Draggable and resizable widget grid with automatic layout persistence across reloads.",
          "Canonical host gate extended for cs0, Tailscale mesh, and localhost.",
        ],
      },
      {
        version: "unversioned milestone",
        date: "2026-09-09",
        title: "History time axis and zoom",
        changes: [
          "Chart.js history with real timestamps, wheel or pinch zoom, and shift-drag pan.",
        ],
      },
      {
        version: "unversioned milestone",
        date: "2026-09-08",
        title: "Household history chart",
        changes: [
          "Inbox-backed equity history from /joe/history.json with desk series and sparklines.",
          "Private split-flap household board replacing the public drill card.",
        ],
      },
      {
        version: "unversioned milestone",
        date: "2026-09-02",
        title: "Household money page",
        changes: [
          "English household money view with Tabler layout for the three desks.",
        ],
      },
      {
        version: "unversioned milestone",
        date: "2026-08-27",
        title: "Joe board at /joe/",
        changes: [
          "First static Joe paper-trading board shipped on hostdash.",
        ],
      },
    ],
  });
}());
