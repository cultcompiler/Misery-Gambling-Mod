# misery gambling mod

a blackjack gambling minigame for **misery** (platypus entertainment /
ytopia, 2025), built on ue4ss. spawns a standalone gambling npc next
to the real bartender in the bunker, with 3 listings in his shop ui:
BLACKJACK / HIT / STAND.

by **@cultcompiler**

## what it does

a gambling npc auto-spawns next to the real bartender every time u
load ur save. zero setup, install the mod, load ur game, walk to
the bunker, he's there.

the real bartender is NOT touched. this is a separate npc w/ its
own gambling-only shop.

walk up to him, press E, his menu opens w/ 3 entries:

- **BLACKJACK** -- pay 25 rubles to deal a fresh hand. while ur in
  play the label flips to a live scoreboard like `YOU: 14 | DEALER: 7`
- **HIT** -- draw another card
- **STAND** -- end ur turn + collect winnings if u won

after the hand ends BLACKJACK briefly shows the result, e.g.
`GAME END | YOU: 19 | DEALER: 18 | +25 RUBLES`

**real casino rules:** dealer hits soft 17, blackjack pays 3:2, push
refunds the bet, bust = auto-loss, infinite-deck shuffle. dealer's
full hand is committed at deal time (u js dont see the whole card
until u stand) -- same as a real table.

## prerequisites

1. **misery** on steam.
2. **ue4ss installed** in misery. if u havent done this already:
   - download `UE4SS_v*.zip` from
     [the ue4ss github releases](https://github.com/UE4SS-RE/RE-UE4SS/releases).
   - extract its contents into
     `...\steamapps\common\MISERY\MISERY\Binaries\Win64\` (alongside
     `MISERY-Win64-Shipping.exe`).
   - launch misery once + quit, so ue4ss finishes its first-run
     setup + creates its folders.

## install

1. download this repo as a zip (green "Code" button → Download ZIP).
   extract it anywhere.
2. **double-click `install.bat`.**
3. wait ~2 seconds. when u see "Install complete." press any key to
   close the window.

thats it. no prompts, no path entering -- the installer auto-finds
misery via steam.

if windows blocks the script, right-click `install.bat` → properties →
tick **unblock** → ok, then double-click it again.

## how to play

1. launch misery + load ur save.
2. head to the bunker. the gambler auto-spawns next to the real
   bartender a few seconds after the world loads.
3. walk up to him + press E. his shop opens w/ BLACKJACK / HIT /
   STAND.
4. u need at least **25 rubles** to start a hand. click `BLACKJACK`,
   read ur live total off the same label, then HIT or STAND.

## known limitation: main menu button is hidden

the mod hides the **main menu** button in the pause menu. heres why:

the gambler is a dynamically-spawned actor in the persistent level.
when the engine tears down the world (which happens when u click
main menu), it does a leaked-actor check before unloading. our
spawned actor cant be destroyed cleanly fast enough cuz ue4ss
script hooks fire AFTER the engine starts the teardown, not before.
the result is a `Fatal world leaks detected` crash every time u
tried to leave to main menu.

after testing every hook + watchdog approach, the cleanest fix is
to remove the main menu button entirely so u cant trigger the
teardown that way. resume / save game / quick save / settings all
still work normally. to actually quit the game, **ALT+F4** or close
the window. its handled by windows directly so the engine
teardown doesnt run.

## uninstall

double-click `uninstall.bat`. removes the mod folder from ue4ss's
`Mods\` directory. ue4ss itself stays installed.

## credits

- **@cultcompiler** -- mod author
