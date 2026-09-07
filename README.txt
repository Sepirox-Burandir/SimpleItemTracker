SimpleItemTracker
=================
Vanilla World of Warcraft addon for client 1.12.1 (Interface 11200, Build 5875).

Install
-------
1. Copy the folder "SimpleItemTracker" into:
   World of Warcraft\Interface\AddOns\
2. The result must look like:
   Interface\AddOns\SimpleItemTracker\SimpleItemTracker.toc
   Interface\AddOns\SimpleItemTracker\SimpleItemTracker.lua
3. Restart the game (or /reload after enabling it at character select).

What it does
------------
Shows a small movable bar of item icons. Each icon is the item's bag
artwork with the TOTAL amount you currently carry in backpack + bags
printed on top (like a WeakAura icon).

Minimap button
--------------
- Left-click  : show / hide the tracker bar
- Right-click : open settings (Edit Mode + scale)
- Drag        : move the button around the minimap

Settings
--------
- Scale slider: 50% to 150% in 10% steps
- Edit Mode:
    * A lock mark (L) on the top-left of each icon. Click to lock or
      unlock. Locked items are kept when you press Clear All.
    * A red X on unlocked icons. Click X to remove that item.
      Locked icons hide the X until you unlock them.
    * An empty slot at the end of the bar. Drag an item from your
      bags onto that slot (or click it while the item is on your
      cursor) to start tracking it.
- Clear All: removes every UNLOCKED item. Locked items stay.

The bar itself can be dragged with the left mouse button.

Slash commands
--------------
/sit                Toggle the tracker bar
/sit settings       Open the settings window
/sit edit           Toggle Edit Mode (shows the bar if it was hidden)
/sit scale 100      Set scale to 100 (allowed: 50-150)

Saved data (per character)
--------------------------
Tracked item list (including lock flags), bar position, scale and
minimap-button angle.
