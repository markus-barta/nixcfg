# Global Zellij configuration for all (mba) servers
{ username, hostName, ... }:

{
  # Home Manager configuration for custom Zellij keybindings and themes
  home-manager.users.${username} = {
    home.file."/home/${username}/.config/zellij/config.kdl".text = ''

      /***********************************************
       *    WARNING: CRITICAL INDENTATION SECTION    *
       * KDL config below MUST be properly indented. *
       ***********************************************/

      // Zellij keybindings configuration
      keybinds {
          unbind "Ctrl o"
          normal {
              bind "Ctrl a" { MoveTab "Left"; }
              bind "Ctrl e" { SwitchToMode "Session"; }
          }
          session {
              bind "Ctrl e" { SwitchToMode "Normal"; }
          }
          tab {
              bind "c" {
                  NewTab {
                      cwd "~"
                  }
                  SwitchToMode "normal";
              }
          }
      }

      // Zellij themes configuration
      themes {
          catppuccin-latte {
              bg "#acb0be" // Surface2
              fg "#acb0be" // Surface2
              red "#d20f39"
              green "#40a02b"
              blue "#1e66f5"
              yellow "#df8e1d"
              magenta "#ea76cb" // Pink
              orange "#fe640b" // Peach
              cyan "#04a5e5" // Sky
              black "#dce0e8" // Crust
              white "#4c4f69" // Text
          }

          catppuccin-frappe {
              bg "#626880" // Surface2
              fg "#c6d0f5"
              red "#e78284"
              green "#a6d189"
              blue "#8caaee"
              yellow "#e5c890"
              magenta "#f4b8e4" // Pink
              orange "#ef9f76" // Peach
              cyan "#99d1db" // Sky
              black "#292c3c" // Mantle
              white "#c6d0f5"
          }

          catppuccin-macchiato {
              bg "#5b6078" // Surface2
              fg "#cad3f5"
              red "#ed8796"
              green "#a6da95"
              blue "#8aadf4"
              yellow "#eed49f"
              magenta "#f5bde6" // Pink
              orange "#f5a97f" // Peach
              cyan "#91d7e3" // Sky
              black "#1e2030" // Mantle
              white "#cad3f5"
          }

          catppuccin-mocha {
              bg "#585b70" // Surface2
              fg "#cdd6f4"
              red "#f38ba8"
              green "#a6e3a1"
              blue "#89b4fa"
              yellow "#f9e2af"
              magenta "#f5c2e7" // Pink
              orange "#fab387" // Peach
              cyan "#89dceb" // Sky
              black "#181825" // Mantle
              white "#cdd6f4"
          }

          // cloud server csb0 theme
          csb0 {
              bg "#9999ff"  // + Text Selection
              fg "#6666af"  // + Footer Buttons
              red "#f0f0f0" // + Shortcuts in Buttons (best: white)
              green "#9999ff" // + Frame
              blue "#00d9e3" // Electric Blue
              yellow "#aae600" // Neon Yellow
              magenta "#aa00ff" // Neon Purple
              orange "#006611" // Retro Red
              cyan "#00e5e5" // Cyan
              black "#00000f" // + Header and Footer bg (Black)
              white "#ffffff" // White
          }

          // cloud server csb1 theme
          csb1 {
              bg "#c45fc0"       // + Text Selection
              fg "#cb54e3"       // + Footer Buttons
              red "#f5f5f5"      // + Shortcuts in Buttons (best: white)
              green "#cb54e3"    // + Frame
              blue "#0000ff"     // -
              yellow "#ffff00"   // -
              magenta "#ff00ff"  // -
              orange "#ed94ff"   // + Highlight Text (eg. Alt)
              cyan "#00ffff"     // -
              black "#00000f"    // + Header and Footer bg (Black)
              white "#ffffff"    // -
          }

          // miniserver24 theme
          miniserver24 {
              bg "#585b70" // Surface2
              fg "#d5f4cd" // pastell green
              red "#2a9e00" // dark green
              green "#a6e3a1"
              blue "#89b4fa"
              yellow "#f9e2af"
              magenta "#f5c2e7" // Pink
              orange "#fab387" // Peach
              cyan "#89dceb" // Sky
              black "#181825" // Mantle
              white "#cdd6f4"
          }

          // miniserver theme
          ms {
              bg "#9f9f9f"  // + Text Selection
              fg "#6f6f6f"  // + Footer Buttons
              red "#f0f0f0" // + Shortcuts in Buttons (best: white)
              green "#9f9f9f" // + Frame
              blue "#00d9e3" // Electric Blue
              yellow "#aae600" // Neon Yellow
              magenta "#aa00ff" // Neon Purple
              orange "#006611" // Retro Red
              cyan "#00e5e5" // Cyan
              black "#00000f" // + Header and Footer bg (Black)
              white "#ffffff" // White
          }
      }

      // Session configuration (optionally restores terminated sessions on start)
      session_serialization true

      // Theme to be used
      theme "${hostName}"
    '';
  };
}
