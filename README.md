# Microsoft Teams global mute shortcut for macOS

<p align="center">
  <img src="assets/app-icon.png" alt="Teams Mute Helper icon" width="220">
</p>

Toggle mute in Microsoft Teams from any macOS app with a global keyboard shortcut.

The setup uses the built-in Shortcuts app plus a tiny native helper compiled locally from the included Objective-C source. The helper owns Accessibility permission, so Chrome, Slack, and other foreground apps do not ask to control your computer.

No third-party runtime, background service, microphone access, or network access is required. The helper runs only when invoked and exits immediately.

## Requirements

- macOS 13 or later with the Shortcuts app
- Xcode Command Line Tools (`xcode-select --install`)
- The current Microsoft Teams desktop app (`com.microsoft.teams2`)
- Teams' **Toggle mute** command assigned to **Shift-Command-M**

## Set up

### 1. Install the background helper

Clone or download this repository, then run:

```sh
./install-helper.sh
```

The installer compiles and ad-hoc signs `Teams Mute Helper.app` locally and installs it in `~/Applications`. It sets the helper to run without a window or Dock icon.

Open **System Settings → Privacy & Security → Accessibility**, add `~/Applications/Teams Mute Helper.app`, and enable it.

If Accessibility access is not active after reinstalling, turn the helper's entry off and on again.

### 2. Create the global shortcut

1. Open **Shortcuts** and create a shortcut named `Toggle Teams Mute`.
2. Add the **Run AppleScript** action.
3. Paste the contents of [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript) into the action.
4. Set the shortcut to receive **no input**.
5. Open the shortcut's **Details** panel.
6. Enable **Use as Quick Action** and **Services Menu**.
7. Add **Control-Shift-Command-A** as its keyboard shortcut.

Join a Teams meeting and use the keyboard shortcut from another app. Teams should toggle mute and return focus to the previous app.

## How it works

macOS implements a global Shortcuts key combination through the Services system. Running Accessibility automation directly inside that Service can make the foreground app appear to be the requester.

This project separates the responsibilities:

1. The global Shortcut executes the installed helper and waits for its result.
2. The helper finds the active meeting window and reads whether its control says **Mute mic** or **Unmute mic**.
3. It raises Teams, waits for the global shortcut's physical modifier keys to be released, and sends Teams' **Shift-Command-M** shortcut.
4. It verifies that Teams' mic state changed, restores the previous app, and exits.

The helper tries a system HID event first. If Teams does not change state, it retries with process-targeted key delivery. Verification prevents a successful first attempt from being toggled a second time.

The Shortcut runs the helper executable directly instead of asking Launch Services to open its bundle. This avoids stale app registrations silently swallowing a launch request.

Only the helper performs Accessibility automation, so it is the only component that needs Accessibility permission.

## Troubleshooting

### Every foreground app asks for Accessibility permission

The Shortcut is probably running the Teams automation directly. Replace its AppleScript with [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript), install the helper, and grant Accessibility permission only to **Teams Mute Helper**.

### Teams Mute Helper is not allowed to send keystrokes

Open **System Settings → Privacy & Security → Accessibility** and enable **Teams Mute Helper**. If it is already enabled, turn it off and on again.

Reinstalling rebuilds and re-signs the helper. Refresh its Accessibility toggle if macOS does not retain the grant.

### The shortcut works once, then stops

Replace the Shortcut's AppleScript with the current [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript). Older versions launched the helper through Launch Services, which could silently reuse a stale registration. The current launcher executes the installed helper directly.

### A Run/Quit window appears

Pull the latest version, re-run `./install-helper.sh`, and replace the Shortcut's AppleScript. The current helper is a native background app and cannot display AppleScript's Run/Quit startup screen.

### Teams focuses but mute does not change

Open **Teams → Settings and more → Keyboard shortcuts** and confirm **Toggle mute** is assigned to **Shift-Command-M**. Fully quit and reopen Teams after changing its shortcut preset.

The helper waits for the keys used by the global shortcut to be released before sending Teams' shortcut.

Microsoft documents **Shift-Command-M** as the macOS mute toggle in its [Teams keyboard shortcut reference](https://support.microsoft.com/en-us/accessibility/teams/keyboard-shortcuts-for-microsoft-teams).

### Teams asks macOS to locate an application

Use the current helper from this repository. It restores the previous app by process ID instead of treating the process name as an application name.

### Collect a local diagnostic

Run the helper without toggling the microphone:

```sh
~/Applications/Teams\ Mute\ Helper.app/Contents/MacOS/TeamsMuteHelper --diagnose
tail -20 ~/Library/Logs/Teams\ Mute\ Helper.log
```

For a logged mute toggle, replace `--diagnose` with `--verbose`. Normal shortcut runs do not write a log. Each diagnostic or verbose run replaces the previous log.

The log contains helper status, delivery modes, mic state, timestamps, and process identifiers. It does not contain meeting titles, messages, participant names, or audio.

## Files

- [`install-helper.sh`](install-helper.sh): builds, signs, and installs the background helper.
- [`assets/app-icon.svg`](assets/app-icon.svg), [`assets/app-icon.png`](assets/app-icon.png), and [`assets/AppIcon.icns`](assets/AppIcon.icns): vector source, README image, and macOS bundle icon.
- [`TeamsMuteHelper.m`](TeamsMuteHelper.m): activates Teams, sends its mute shortcut, and verifies the state change.
- [`TeamsMuteHelper-Info.plist`](TeamsMuteHelper-Info.plist): defines the native background app bundle.
- [`toggle-teams-mute.applescript`](toggle-teams-mute.applescript): launches the helper from Shortcuts.

## Limitations

- Teams must be running with a meeting or call open.
- Teams briefly receives focus because it does not expose a system-wide mute API on macOS.
- The helper targets the current Teams desktop app. Classic Teams uses a different bundle ID.
- The global keyboard shortcut is configured in Shortcuts, not in the helper.

## Privacy

The helper does not access audio, files, or the network. Accessibility permission is used to search Teams' local accessibility hierarchy for the microphone control, send Teams' mute shortcut, verify the control changed, and restore focus. Normal shortcut runs retain no activity data; local diagnostic logging is explicit and contains no meeting content. Nothing is transmitted. The complete helper source is readable in this repository and is compiled locally during installation.

## License

[MIT](LICENSE)
