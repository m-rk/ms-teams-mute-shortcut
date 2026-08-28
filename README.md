# Microsoft Teams global mute shortcut for macOS

<p align="center">
  <img src="assets/mute-mic.png" alt="Mute microphone control" width="180">
  &nbsp;&nbsp;
  <img src="assets/unmute-mic.png" alt="Unmute microphone control" width="180">
</p>

Toggle mute in Microsoft Teams from any macOS app with a global keyboard shortcut.

The setup uses the built-in Shortcuts app plus a tiny local AppleScript helper. The helper owns Accessibility permission, so Chrome, Slack, and other foreground apps do not ask to control your computer.

No third-party software, background service, microphone access, or network access is required. The helper runs only when invoked and exits immediately.

## Requirements

- macOS with the Shortcuts app
- The current Microsoft Teams desktop app (`com.microsoft.teams2`)
- Teams' **Toggle mute** shortcut set to **Shift-Command-M**

## Set up

### 1. Install the background helper

Clone or download this repository, then run:

```sh
./install-helper.sh
```

The installer builds and ad-hoc signs `Teams Mute Helper.app` locally, then installs it in `~/Applications`. It sets the helper to run without a window or Dock icon.

Open **System Settings → Privacy & Security → Accessibility**, add `~/Applications/Teams Mute Helper.app`, and enable it.

### 2. Create the global shortcut

1. Open **Shortcuts** and create a shortcut named `Toggle Teams Mute`.
2. Add the **Run AppleScript** action.
3. Paste the contents of [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript) into the action.
4. Set the shortcut to receive **no input**.
5. Open the shortcut's **Details** panel.
6. Enable **Use as Quick Action** and **Services Menu**.
7. Add a keyboard shortcut. For example, **Control-Shift-Command-A**.

Join a Teams meeting and use the keyboard shortcut from another app. Teams should toggle mute and return focus to the previous app.

## How it works

macOS implements a global Shortcuts key combination through the Services system. Running Accessibility automation directly inside that Service can make the foreground app appear to be the requester.

This project separates the responsibilities:

1. The global Shortcut launches `Teams Mute Helper.app` without bringing it forward.
2. The helper records the active app's process ID.
3. It activates Microsoft Teams and sends **Shift-Command-M**.
4. It restores the previous app by process ID and exits.

Only the helper performs Accessibility automation, so it is the only component that needs Accessibility permission.

## Troubleshooting

### Every foreground app asks for Accessibility permission

The Shortcut is probably running the Teams automation directly. Replace its AppleScript with [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript), install the helper, and grant Accessibility permission only to **Teams Mute Helper**.

### Teams Mute Helper is not allowed to send keystrokes

Open **System Settings → Privacy & Security → Accessibility** and enable **Teams Mute Helper**. If it is already enabled, turn it off and on again.

Reinstalling rebuilds and re-signs the helper. Refresh its Accessibility toggle after reinstalling so macOS recognises the new signature.

### The shortcut works once, then stops

An older helper build could remain running after the first toggle, causing later launch requests to reuse it without running the toggle again. Pull the latest version and re-run `./install-helper.sh`. The installer stops the stale helper, and the current helper quits after every toggle.

### A Run/Quit window appears

Re-run `./install-helper.sh`. The installer explicitly disables the AppleScript startup screen and configures the helper as a background-only app.

### Teams focuses but mute does not change

Open **Teams → Settings and more → Keyboard shortcuts** and confirm **Toggle mute** is assigned to **Shift-Command-M**. Shortcut presets can change Teams' key assignments. Fully quit and reopen Teams after changing the preset or shortcut.

Microsoft documents **Shift-Command-M** as the macOS mute toggle in its [Teams keyboard shortcut reference](https://support.microsoft.com/en-us/accessibility/teams/keyboard-shortcuts-for-microsoft-teams).

### Teams asks macOS to locate an application

Use the current helper from this repository. It restores the previous app by process ID instead of treating the process name as an application name.

## Files

- [`install-helper.sh`](install-helper.sh): builds, signs, and installs the background helper.
- [`teams-mute-helper.applescript`](teams-mute-helper.applescript): performs the Teams mute toggle.
- [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript): launches the helper from Shortcuts.

## Limitations

- Teams must be running with a meeting or call open.
- Teams briefly receives focus because it does not expose a system-wide mute API on macOS.
- The helper targets the current Teams desktop app. Classic Teams uses a different bundle ID.
- The global keyboard shortcut is configured in Shortcuts, not in the AppleScript.

## Privacy

The helper does not access audio, meeting content, files, or the network. macOS Accessibility permission is used only to identify the active app, send the Teams keystroke, and restore focus. The complete automation is readable in this repository and is compiled locally during installation.

## License

[MIT](LICENSE)
