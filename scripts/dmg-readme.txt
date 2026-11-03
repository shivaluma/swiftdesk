SwiftDesk — low-latency remote desktop between two Macs
=======================================================

Requires macOS 15 or later. Runs natively on Apple silicon and Intel Macs.

INSTALL
  Drag SwiftDesk.app onto the Applications folder in this window, then eject the disk image.
  Install it on both Macs: the one you share (Host) and the one you control it from (Viewer).

FIRST LAUNCH (this build is not notarized by Apple)
  macOS will block the first launch with a message that it cannot verify SwiftDesk. To open it anyway:
    1. Open SwiftDesk once and click Done (or OK) on the warning.
    2. Open System Settings > Privacy & Security, scroll down to the message about SwiftDesk, and click
       "Open Anyway". Confirm with your password or Touch ID.
  Or, in Terminal:   xattr -dr com.apple.quarantine /Applications/SwiftDesk.app

HOST (the Mac being controlled)
  1. Choose "Share this Mac".
  2. Grant Screen & System Audio Recording (required) and Accessibility (needed for control; without it the session is
     view-only) in System Settings > Privacy & Security. Reopen SwiftDesk if macOS asks you to.
  3. Allow Local Network access when asked.
  4. Pick the display and click "Start Listening". Note the address and the Identity fingerprint.

VIEWER (the Mac you control from)
  1. Choose "Control a Mac". Enter the Host's address (port 47800) or pick it under "Nearby", then Connect.
  2. Compare the fingerprint shown with the one on the Host screen, character by character, before trusting it.
  3. On the Host, click "Allow Control" in the approval sheet.
  4. Click into the video to take control. Press Control-Option-Escape to release the keyboard and mouse.

NETWORK
  Both Macs must be on the same local network, or both signed in to the same Tailscale tailnet (use the Host's
  100.x.y.z address). Never forward port 47800 on your router to the Internet.
