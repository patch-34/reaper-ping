<p align="center">
  <img src="reaper-ping-icon.png" alt="Reaper Ping" width="220">
</p>

# Reaper Ping

Telegram notifications for REAPER renders.

Reaper Ping opens REAPER’s native Render dialog and sends you a Telegram message when the render is finished.

## How to use

1. Download the script:

`Patch34 - Render with Telegram notification.lua`

2. In REAPER, open:

`Actions → Show action list → New action → Load ReaScript`

3. Load the script file.

4. Run the action:

`Patch34: Render with Telegram notification`

5. Open the Telegram bot:

`@reaper_ping_bot`

6. Send `/start` and copy the pairing code.

7. Paste the pairing code into REAPER when the script asks for it.

After pairing, use the Patch34 action whenever you want a render notification.

Regular REAPER Render does not send notifications.
Only renders started through the Patch34 action will ping you.

## Author

Aleksei Vorobev / Patch34
https://github.com/patch-34
