# Pacing research: challenge versus quiet periods

> Status: research and a proposal (2026-11-23). Nothing is built or decided. The recommendation in section 8 is for the
> user to accept, change or reject. Related docs: [mission-objectives.md](mission-objectives.md) (section 5, waves),
> [mission-section.md](mission-section.md) (section 16, encounter pacing).

## 1. The answer first

- **Pressure comes in cycles, and the cycles react to the crew.** Every co-op shooter that paces well runs some
  version of Left 4 Dead's loop: **build up** pressure until the players are visibly stressed, **hold** the peak a few
  seconds, let the fight **play out**, then give a **short** rest (30 to 45 s in L4D), then build up again. Valve's own
  rule of thumb, taken from watching Counter-Strike: "constant, unchanging combat is fatiguing" and "long periods of
  inactivity are boring" ([Booth, GDC 2009][booth]).
- **babamech's 130 s gaps are three to four times longer than L4D's whole rest phase.** Fixed waves ordered *after* an
  objective completes put the pressure where the player has just finished working. That matches the designer's
  verdict, "too little too late". The pressure should be ordered **by how stressed the crew is, and when they start an
  objective**, not when they finish one.
- **The quiet stretch is part of the fight, not time off.** A lull is tense when (a) the damage from the last fight is
  still on the mech and healing is scarce, (b) something can still find you (a scout, a patrol, a distant gunship), and
  (c) you can see or hear the next threat coming. L4D, Deep Rock Galactic and Helldivers 2 all do this with persistent
  damage, priced or limited healing, and enemies that call for help.
- **The director changes *when* threats arrive, not how strong they are.** "Amplitude (difficulty) is not changed,
  frequency (pacing) is" ([Booth][booth]). Difficulty stays in deck budgets and unit mix; the director only schedules.

## 2. What the sources do

### 2.1 Left 4 Dead: the AI Director (the reference model)

From Mike Booth's GDC 2009 slides ([AI systems of L4D][booth]):

| Part | How it works |
|---|---|
| **Survivor intensity** | One number per player. Goes up with damage taken (proportional), being incapacitated, being pulled or pushed off a ledge, and a nearby infected dying (inversely proportional to distance). Decays toward zero over time, **but does not decay while infected are actively engaging the player** |
| **Crew intensity** | The **maximum** of the four players' intensities, not the average: the most stressed player sets the pace |
| **Build Up** | Full threat population until crew intensity crosses a peak threshold |
| **Sustain Peak** | Full threat for **3 to 5 s** after the peak, so a build-up has a minimum length |
| **Peak Fade** | Minimal threat (no new spawns), but the current fight is allowed to finish; the rest does not start until "a natural break in the action occurs" |
| **Relax** | Minimal threat for **30 to 45 s**, or until the team has travelled far enough, then back to Build Up |
| **Full vs minimal threat** | Full: wanderers, mobs, specials. Minimal: no new mobs or specials (existing ones may still attack) |
| **Not modulated** | Boss encounters and scripted finales: "overall pacing affected too much if they are missing" |
| **Structured unpredictability** | Mobs of 20 to 30 every **90 to 180 s** (randomised) on Normal, 75 % of them from behind; specials on their own random timers, spawned out of sight; a boomer hit forces a mob |

Booth's conclusion: the intensity estimate "is crude, yet the resulting pacing works". Secondary accounts add that the
Director also moves health and items based on player state ([Game Developer, "The discomfort zone"][discomfort]).
Evolve (made by former L4D developers) kept the idea, aiming for four or five confrontations a match with quiet hunting
in between: "You can't appreciate the action unless you have some inaction" ([Shacknews][evolve]).

### 2.2 Helldivers 2: patrols, calls for help, and a finite budget

From the community-tested spawn data ([Helldivers wiki, spawn mechanics archive][hd2spawn]; treat it as measured by
players, not documented by Arrowhead):

- **Patrols** spawn on a timer per player group, about **125 m** away (never inside about 85 m). Solo intervals run
  from about **255 s at low difficulty to about 100 s at the top** (Automatons 110 s, Terminids 99 s at difficulty 9).
- **Player count shortens the timer**: x0.83 at 2 players, x0.75 at 3. Players **75 m or more apart form separate
  groups**, each with its own patrols, so a split crew draws more pressure.
- **Objectives heat the map.** Objective areas raise the local patrol rate by up to 50 %; completing the primary
  multiplies the threshold by 0.75 map-wide; the **extraction area spawns patrols up to about 5.4x faster** within
  100 m.
- **Reinforcements are called by enemies, and the call is a diegetic tell.** An Automaton fires a red flare (about 2 s
  of wind-up, by one guide's measure) and a dropship comes; Terminids emit orange smoke and open a breach. Kill the
  caller first and nothing comes ([Game8 reinforcements][hd2game8], [Steam discussion][hd2breach]). Only one
  enemy-called reinforcement runs at a time, with a 2 to 5 minute map-wide cooldown; **objective-triggered
  reinforcements ignore that cooldown** ([Helldivers wiki][hd2spawnwiki]).
- **Lives are a shared budget**: 5 reinforcements per player per mission (20 for four), then one more every 120 s
  ([Helldivers wiki, Reinforcement][hd2reinf]). Stims are limited (about 4 to 6) and refill only from resupply
  ([Destructoid][hd2stims]). Dying is cheap in the moment and expensive for the mission.

### 2.3 Deep Rock Galactic: swarms on a timer, healing that costs a mission resource

- **Swarms** arrive on timers that shorten with difficulty: from about 350 to 500 s at Hazard 1 down to about 250 to
  350 s at Hazard 3 (sometimes 180 to 200 s), with smaller "normal waves" in between and objectives that trigger their
  own swarms ([DRG wiki, Swarm (older)][drgswarm], [Update 21 notes][drgu21]).
- **Player count** scales enemy count, not just HP. At Hazard 3: solo 0.50, two 0.50, three 0.80, four 1.10. Solo
  gets the drone Bosco instead of a teammate, so solo is close to the 2-player count ([DRG wiki, Hazard Level][drghaz]).
- **Healing is a purchase.** A resupply pod costs **80 Nitra** (a resource mined during the mission) and each rack
  gives half your ammo and half your health ([DRG wiki, Resupply][drgresup]). Every heal is a choice against the next
  heal, so damage stays meaningful between swarms.

### 2.4 Halo: the 30-second loop and territorial enemies

Jaime Griesemer's "30 seconds of fun": get one short loop right and repeat it in new spaces with new weapons and
enemies ([Engadget interview][halo30]). Damian Isla (Bungie AI) splits it into **enter a space, plan, execute**, and made
enemies **territorial** so opening fire does not pull the whole room: encounters become puzzles, and the recharging
shield needs a safe zone the player expands as they win ([Game Developer, Bungie on Halo AI][haloai]). For babamech:
a single engagement should last about 30 s to a minute; the director decides how many of them overlap.

### 2.5 Doom 2016 / Eternal: resources pull you into the fight

id's "push forward combat": no regenerating health, no cover, health and ammo come **from killing enemies**
([GDC Vault, Embracing Push Forward Combat][doomgdc]). "As long as there are demons on the battlefield, you've got the
resources you need" and "When you're bored, you're not thinking" ([Game Developer, Doom Eternal resources][doometernal]).
The lesson for babamech is narrow: scarce repair is tense, but if the *only* way to recover is to fight, lulls turn
into dead time. A small reward for aggression (salvage from heavy kills) keeps the crew moving toward the next fight.

### 2.6 Others

- **Vermintide 2 / Darktide** (Fatshark): a director builds hordes and specials from team state; terror events switch
  off normal pacing to make room for the scripted fight, exactly like L4D's finales ([Reddit analysis of V2
  events][v2events]). Community figures for Darktide: specials capped at 3, spawning every 140 to 300 s
  ([KOSGames][darktide]).
- **Back 4 Blood** (Turtle Rock): the director deals visible "corruption cards" at mission start, so players can plan
  against what it will do ([Game Developer][b4b]). Telling the crew *what kind* of pressure is coming helps.
- **Alien: Isolation**: a hidden "menace" gauge rises while the alien is near the player; at its peak the director sends
  the alien away into the vents ([Game Developer, "The Perfect Organism"][alien]). Tension from proximity, not damage.
- **Armored Core 6**: three repair kits per mission, refilled only at resupply points and checkpoints
  ([Fextralife][ac6]). A small fixed count, visible all the time, makes every hit count.
- **MechWarrior 5**: armor damage costs money to repair after a mission, and back-to-back missions carry damage
  forward ([Sarna][mw5], [Steam discussion][mw5steam]).
- **Titanfall 2**: AI grunts exist so the Titan meter fills at a steady rate; without them Titans took much longer
  ([EA tech-test notes][tf2]). Fodder that feeds a resource keeps the tempo even.
- **Hamlet** (Hunicke and Chapman): a dynamic-difficulty system for Half-Life that watches for **"inventory
  shortfalls"** (health, ammo running low) and adjusts supply, intervening "just enough" to stay predictable
  ([Hamlet paper][hamlet]).
- **Pacing graphs**: Mark Davies separates **threat** (actual danger) from **tension** (perceived danger) and **tempo**
  (amount of action). In his CoD4 breakdown, first contact is Threat Medium, Tension High, Tempo Low: a tense lull
  ([Game Developer, "Examining game pace"][davies]). Mike Birkhead's combat scale defines a "normal fight" as one that
  leaves the player at about half health, a hard one at almost none ([Game Developer, pacing graphs][birkhead]).

## 3. Numbers the sources give

| Quantity | Value | Source |
|---|---|---|
| Peak hold after intensity crosses threshold | 3 to 5 s | L4D [booth] |
| Relax length | 30 to 45 s (or until the team has moved on) | L4D [booth] |
| Big pressure event interval | 90 to 180 s (mobs, Normal) | L4D [booth] |
| Patrol interval, solo | 255 s (easy) to about 100 s (hardest) | Helldivers 2 [hd2spawn] |
| Player-count speed-up | x0.83 (2), x0.75 (3) | Helldivers 2 [hd2spawn] |
| Extraction pressure | up to 5.4x patrol rate within 100 m | Helldivers 2 [hd2spawn] |
| Enemy-called reinforcement tell | about 2 s flare wind-up; kill the caller to cancel | Helldivers 2 [hd2game8] |
| Swarm interval | 250 to 500 s by hazard, plus normal waves between | DRG [drgswarm] |
| Enemy count, solo to 4 players | x1.0 / 1.0 / 1.6 / 2.2 (Hazard 3, relative) | DRG [drghaz] |
| Healing price | 80 Nitra for half health and ammo per player | DRG [drgresup] |
| Lives | 5 per player per mission, then 1 per 120 s | Helldivers 2 [hd2reinf] |
| Healing count | 3 repair kits per mission | AC6 [ac6] |
| Specials | max 3 alive, every 140 to 300 s | Darktide (community) [darktide] |
| Core loop length | about 30 s | Halo [halo30] |
| "Normal" fight cost | about half the player's health | Birkhead [birkhead] |

**What no source gives:** a measured "players get bored after N seconds" figure. The closest evidence is that every
game above keeps its full rest under a minute (L4D's 30 to 45 s), and the long timers (Helldivers patrols, DRG swarms)
sit on top of a constant layer of smaller threats, so the player is never actually alone for minutes.

## 4. How intensity is computed

All directors use a crude, cheap estimate; none model emotion directly.

| Input | L4D | Others |
|---|---|---|
| Damage taken | yes, proportional | Hamlet: inventory shortfall |
| Incapacitated / downed | yes, big bump | Helldivers: lives as a budget |
| Knocked off a ledge | yes | (babamech: fall damage) |
| Nearby enemy deaths | yes, inverse to distance | Titanfall: kills feed a meter |
| Proximity of threat | indirectly (no decay while engaged) | Alien: menace from proximity |
| Decay | toward zero, paused while engaged | Alien: peak too long forces a retreat |
| Aggregation | max over players | Helldivers: per player group |

## 5. Stress between fights (attrition)

The pattern that makes a lull tense instead of empty:

1. **Damage persists.** L4D health carries across the level and the Director places kits by player state; MW5 carries
   damage between back-to-back missions. If a fight's damage is gone 10 s later, the fight did not matter.
2. **Healing is scarce and visible.** AC6's three kits, Helldivers' 4 to 6 stims, DRG's 80-Nitra pods. The player
   always knows the count and spends each one as a decision.
3. **Healing is partial.** DRG pods give half. A partial heal leaves the mech scarred, so the next fight starts behind.
4. **Death costs the mission, not just time.** Helldivers' shared lives; DRG revives at a hazard-set reduced health
   ([DRG wiki][drghaz]).
5. **Something can still find you.** Patrols (Helldivers), wanderers (L4D), roaming specials. And they can *call for
   help*: the flare is the most effective lull-tension device in the list, because it gives the player a reason to act
   fast in a quiet moment and a visible, interruptible tell.
6. **The next threat is announced in the world.** Helldivers dropships come after a flare the player saw; Back 4 Blood
   shows its director's cards up front; Davies' "tension" is exactly this perceived, not-yet-actual danger. (L4D does
   the opposite on purpose for mobs, 75 % from behind, to surprise; babamech's telegraph rule points the other way.)
7. **Time pressure grows.** Helldivers' patrol rate rises as objectives complete and is fastest at extraction. Staying
   still is never fully safe.

## 6. Co-op scaling

- **Aggregate by the most stressed player** (L4D's max), so one struggling pilot calms the director for everyone.
- **Scale enemy count less than linearly**: DRG goes about 1.0 / 1.0 / 1.6 / 2.2 for 1 to 4 players; Helldivers speeds
  timers by 17 to 25 %. Solo needs help (DRG gives Bosco).
- **Split crews draw more pressure**: Helldivers runs patrols per group of players 75 m apart.
- **Rubber-band supply, not damage.** L4D and Hamlet move health and items toward struggling players. Lowering enemy
  damage or accuracy on the fly is the version players notice and resent; changing when and where supplies show up is
  the version they do not.

## 7. Where babamech is today

| | Playtest (solo, 10 to 14 min, 37 kills) | What the sources suggest |
|---|---|---|
| Average kill interval | about 22 s | fine as an average; the problem is the spread |
| Longest quiet gap | up to 130 s | under 45 s of rest; under 60 s with no threat at all |
| What triggers pressure | objective completion, fixed waves | crew intensity, and objective **start** |
| Wave size | 2 to 3 units | enough to push a solo pilot to about half structure |
| Pressure in a lull | none (wave units hunt only when released) | patrols, scouts that call waves, visible incoming |

## 8. Recommendation for babamech

### 8.1 Intensity model (host-run director)

The director is a host-owned world system (AGENTS.md rule 6, host-arbitrated): it reads facts the owners already report
(damage, knockdowns), schedules releases, and rolls with the mission-seed generator (rule 4). It decides **when and
where**; deck budgets decide **how much**.

**Per-pilot intensity `I` (0 to 100), updated on the host:**

| Event | Change |
|---|---|
| Structure damage taken | +1 per 1 % of the mech's total structure lost (any component) |
| Component destroyed (arm, leg) | +15 |
| Mech disabled (needs revive) | +40 (straight to peak) |
| Fall damage | +8 |
| Heat at or past shutdown threshold | +5 per second there |
| Enemy killed within 40 m | +4 x (1 - dist / 40) |
| Decay | -4 per second, **only when no enemy has fired at or come within 60 m of the pilot for 4 s** |

**Crew intensity** = max over pilots on the deck. Pilots on another deck count toward their own deck's director.

**States:**

| State | Rule | Threat |
|---|---|---|
| **Build Up** | until crew `I` >= 70, or 90 s have passed | release pressure: the next wave, patrols active, scouts can call waves |
| **Sustain** | 6 s after the peak (longer than L4D's 3 to 5 s: mech fights resolve slower) | keep releasing whatever was queued |
| **Fade** | no new releases; ends when crew `I` < 35 **and** nobody has been engaged for 5 s | the current fight plays out |
| **Relax** | 25 s (first deck) to 15 s (lowest deck), matching the existing wave lull | no releases; garrison stays where it is; ambient threat only (8.4) |

**Hard rules on top:**
- **Maximum quiet**: if no enemy has engaged any pilot for **45 s** and the director is not in Relax, it releases the
  next wave (or a patrol if the pool is empty) from the source nearest the crew. 130 s gaps become impossible.
- **Minimum build-up**: never jump from Relax to a heavy wave; the first release after Relax is the lightest left.
- **Objectives override** (8.3), as L4D finales and Helldivers objective calls do.

### 8.2 Target numbers (tune in playtest)

| Target | Solo | 4 pilots |
|---|---|---|
| One full cycle (build up to end of relax) | 75 to 120 s | 75 to 120 s |
| Peak engagement (build up + sustain + fade) | 45 to 90 s | 45 to 90 s |
| Relax | 15 to 25 s (by deck) | same |
| Longest stretch with no enemy engaging anyone | <= 45 s (hard cap) | <= 45 s |
| Share of deck time with someone engaged | 60 to 75 % | 65 to 80 % |
| Enemies engaging the crew at a peak | 4 to 6 | 8 to 12 (about x1.0 / 1.4 / 1.8 / 2.2 by crew size, after DRG) |
| Kill interval during a peak | 6 to 12 s | 3 to 6 s (crew total) |
| Kill interval averaged over a deck | 12 to 18 s | 6 to 10 s |
| Structure at the end of a peak (worst pilot) | 40 to 65 % | same |
| Lowest component in a deck | dips under 35 % at least once | for at least one pilot |
| Lowest structure in a mission | under 25 % at least once (a "close call") | same |
| Mechs disabled per mission (normal difficulty) | 0 to 1 | 1 to 3 across the crew |
| Peaks per deck | 3 to 4, the last one the departure fight | same |

Wave sizes follow from this: a solo peak at 4 to 6 engaged means waves of 3 to 5 units on top of what the garrison
contributes, larger than today's 2 to 3. The deck budgets in mission-objectives.md section 5.2 are the numbers to raise.

### 8.3 Objectives spike the pressure

Starting an objective is a commitment; that is the moment the enemy should answer.

| Objective | On start | During | On finish |
|---|---|---|---|
| **Raise the flag** (hold zone) | force **Build Up** whatever the state; first wave released at once, arriving within 10 to 15 s from a named source, with its diegetic tell (8.4) | a second wave at 50 % raise progress; **no Relax** while the raise is running (Fade only) | normal director resumes, starting in Fade |
| **Defend the relay** | force Build Up; first wave at once | waves every 25 to 35 s regardless of intensity (the asset is the clock, as in L4D finales and Helldivers objective calls); relax only between waves, never longer than 15 s | a Relax of the deck's full length: the crew has earned it |
| **Sweep** | no spike; normal director | the 45 s cap keeps it moving; the last wave is the departure fight | Relax |
| **Extraction hold (60 s)** | force Build Up; two sources at once | waves every 20 s, no Relax, no Fade; the biggest fight of the mission (Helldivers' extraction runs at up to 5.4x) | mission ends |

Rule of thumb: objective waves **ignore** the director's state and the crew's intensity (L4D: "boss encounters NOT
affected by adaptive pacing"); everything else respects it.

### 8.4 Stress between fights

**Make damage stick and repair scarce:**
- **Damage persists across the whole mission.** Decks do not reset structure.
- **Repair is partial and counted.** The repair drone restores structure to at most 70 % of a component's maximum and
  cannot rebuild a destroyed component. A small fixed number of repair charges per pilot per mission (AC6 uses 3), shown
  on the HUD at all times.
- **Full repair only at a resupply point between decks**, and only half-way (DRG pods give 50 %). Arriving on a new deck
  at 70 % is the intended normal.
- **Revive costs something lasting**: a revived mech returns with its legs at 30 % and one weapon offline until the next
  resupply. Being disabled hurts the mission, not just the minute.
- **Salvage from heavy kills** (tank, strider, gunship): a small structure patch on the wreck. Pushing forward pays
  (Doom), but a lull without fighting does not refill you.

**Keep the lull dangerous (all diegetic, no icons, no beeps):**
- **Scouts that call waves** (Helldivers' flare): a scout drone or trooper that sees the crew starts a call, visible as a
  flare, a beacon light or an antenna unfolding, lasting at least **2 s** (well over the 0.3 s rule). Kill it in time and
  nothing comes; miss it and the next wave is released now, Relax or not. This turns quiet moments into "find it first".
- **A patrol layer** on the host, separate from waves: one light group walks the deck's roads on a 60 to 120 s cycle
  (shorter with crew size, x0.83 / 0.75 / 0.7 after Helldivers), out of sight of the crew when it spawns.
- **Visible incoming**: dropship engines heard before they are seen, lift doors grinding, gate doors opening, a gunship
  crossing the far end of the deck. The crew should see or hear a wave 5 to 10 s before contact. (In-world sounds from
  the unit or door fit the no-indicator rule; a siren on a gate is a question for the user.)
- **Rising heat over time**: after the primary objective completes on a deck, shorten the patrol cycle by 25 % (the
  Helldivers rule). Lingering costs.

### 8.5 Co-op scaling

- Crew intensity = **max** over pilots on the deck.
- Enemies engaged at a peak scale about **x1.0 / 1.4 / 1.8 / 2.2** for 1 to 4 pilots (more units per wave, not more HP).
- Pilots more than **120 m apart** are separate groups for patrols and scouts.
- A disabled pilot puts the director in Fade around them (no new releases aimed at that spot) except objective waves.
- Rubber-band **supply only**: when the crew's average structure is under 40 % at the start of a Relax, the next
  salvage drop or resupply is a little richer. Never change enemy accuracy or damage on the fly.

### 8.6 What the combat log should capture

Every line timestamped on the shared clock, with deck and pilot.

**Events:**

| Event | Fields |
|---|---|
| Damage taken | pilot, component, amount, structure % after, source unit type, distance, weapon |
| Damage dealt | pilot, target type, amount, weapon, distance |
| Kill | pilot, target type, distance, time alive since its release |
| Component destroyed, mech disabled, revived, died | pilot, cause |
| Fall damage, heat shutdown, ammo empty | pilot, amount |
| Repair used | pilot, charges left, structure restored |
| Wave released | wave id, source, size, unit types, reason (director / objective / scout call / quiet cap) |
| First contact for a wave | seconds from release to first shot at the crew |
| Scout call | started, cancelled (killed) or completed |
| Objective | started, progress steps, done or failed |
| Director state change | old state, new state, crew intensity |

**Sampled at 1 Hz:** each pilot's intensity, structure % (total and lowest component), heat, enemies engaging them
(fired at them or within 60 m), enemies alive on the deck.

**Per-deck summary (printed at deck end and mission end):**
- time in each director state, and share of time with anyone engaged;
- longest stretch with nobody engaged (target <= 45 s), and every stretch over 30 s listed with its time;
- number of peaks (crew intensity crossing 70);
- kill intervals: median, 90th percentile, longest;
- damage taken per minute and damage dealt per minute, per pilot;
- lowest structure and lowest component reached, and when;
- repairs used, disables, deaths, fall damage total;
- time from objective start to first enemy contact.

These summaries map one to one onto the targets in 8.2, so a bot run or a playtest says directly which numbers are off.

## Sources

[booth]: https://cdn.fastly.steamstatic.com/apps/valve/2009/ai_systems_of_l4d_mike_booth.pdf
[discomfort]: https://www.gamedeveloper.com/design/the-discomfort-zone-the-hidden-potential-of-valve-s-ai-director
[evolve]: https://shacknews.com/article/82787/how-evolve-assures-action-peaks-and-valleys
[hd2spawn]: https://helldivers.wiki.gg/wiki/Spawn_Mechanics/Archive
[hd2spawnwiki]: https://helldivers.fandom.com/wiki/Spawn_Mechanics
[hd2game8]: https://game8.co/games/Helldivers-2/archives/446201
[hd2breach]: https://steamcommunity.com/app/553850/discussions/0/4302697906482532775
[hd2reinf]: https://helldivers.wiki.gg/wiki/Reinforcement
[hd2stims]: https://www.destructoid.com/one-helldivers-2-player-just-survived-a-mission-by-using-with-an-unbelievable-number-of-stims/
[drgswarm]: https://deeprockgalactic.gamepedia.com/Swarm
[drgu21]: https://deeprockgalactic.wiki.gg/wiki/Update_21
[drghaz]: https://deeprockgalactic.wiki.gg/wiki/Hazard_Level
[drgresup]: https://deeprockgalactic.wiki.gg/wiki/Resupply
[halo30]: https://www.engadget.com/2011-07-14-half-minute-halo-an-interview-with-jaime-griesemer.html
[haloai]: https://www.gamedeveloper.com/game-platforms/in-depth-bungie-on-eight-years-of-i-halo-i-ai
[doomgdc]: https://gdcvault.com/play/1024940/Embracing-Push-Forward-Combat-in
[doometernal]: https://www.gamedeveloper.com/design/the-aggressive-resource-management-of-i-doom-eternal-i-
[v2events]: https://r.enesgenc.dev/r/Vermintide/comments/aj9fvx/the_events_of_vermintide_2_and_their_inner
[darktide]: https://kosgames.com/?p=37473
[b4b]: https://gamedeveloper.com/design/behind-back-4-bloods-ingenious-card-system
[alien]: https://www.gamedeveloper.com/design/the-perfect-organism-the-ai-of-alien-isolation
[ac6]: https://armoredcore6.wiki.fextralife.com/Repair+Kit
[mw5]: https://www.sarna.net/wiki/MW5
[mw5steam]: https://steamcommunity.com/app/784080/discussions/0/3061871374464363658
[tf2]: https://ea.com/games/titanfall/titanfall-2/amp/news/tech-test-and-feedback
[hamlet]: https://users.cs.northwestern.edu/~hunicke/pubs/Hamlet.pdf
[davies]: https://www.gamedeveloper.com/design/examining-game-pace-how-single-player-levels-tick
[birkhead]: https://gamedeveloper.com/design/opinion-pacing-graphs-and-tips-from-a-combat-designer

- Mike Booth, "The AI Systems of Left 4 Dead", GDC 2009 (Valve): <https://cdn.fastly.steamstatic.com/apps/valve/2009/ai_systems_of_l4d_mike_booth.pdf>
- "The discomfort zone: the hidden potential of Valve's AI Director", Game Developer: <https://www.gamedeveloper.com/design/the-discomfort-zone-the-hidden-potential-of-valve-s-ai-director>
- "How Evolve assures action peaks and valleys", Shacknews: <https://shacknews.com/article/82787/how-evolve-assures-action-peaks-and-valleys>
- Helldivers 2 spawn mechanics (archive, community-tested): <https://helldivers.wiki.gg/wiki/Spawn_Mechanics/Archive> and <https://helldivers.fandom.com/wiki/Spawn_Mechanics>
- Helldivers 2 reinforcements and flares: <https://game8.co/games/Helldivers-2/archives/446201>, <https://steamcommunity.com/app/553850/discussions/0/4302697906482532775>, <https://helldivers.wiki.gg/wiki/Reinforcement>, <https://www.destructoid.com/one-helldivers-2-player-just-survived-a-mission-by-using-with-an-unbelievable-number-of-stims/>
- Deep Rock Galactic wiki: Swarm (older) <https://deeprockgalactic.gamepedia.com/Swarm>, Update 21 <https://deeprockgalactic.wiki.gg/wiki/Update_21>, Hazard Level <https://deeprockgalactic.wiki.gg/wiki/Hazard_Level>, Resupply <https://deeprockgalactic.wiki.gg/wiki/Resupply>
- "Half-Minute Halo: an interview with Jaime Griesemer", Engadget: <https://www.engadget.com/2011-07-14-half-minute-halo-an-interview-with-jaime-griesemer.html>
- "In-depth: Bungie on eight years of Halo AI" (Damian Isla), Game Developer: <https://www.gamedeveloper.com/game-platforms/in-depth-bungie-on-eight-years-of-i-halo-i-ai>
- Kurt Loudy and Jake Campbell, "Embracing Push Forward Combat in DOOM", GDC 2018: <https://gdcvault.com/play/1024940/Embracing-Push-Forward-Combat-in>
- "The aggressive resource management of Doom Eternal", Game Developer: <https://www.gamedeveloper.com/design/the-aggressive-resource-management-of-i-doom-eternal-i->
- "The events of Vermintide 2 and their inner workings" (community analysis): <https://r.enesgenc.dev/r/Vermintide/comments/aj9fvx/the_events_of_vermintide_2_and_their_inner>
- Darktide horde, special and monster spawn times (community): <https://kosgames.com/?p=37473>
- "Behind Back 4 Blood's ingenious card system", Game Developer: <https://gamedeveloper.com/design/behind-back-4-bloods-ingenious-card-system>
- Tommy Thompson, "The Perfect Organism: the AI of Alien: Isolation", Game Developer: <https://www.gamedeveloper.com/design/the-perfect-organism-the-ai-of-alien-isolation>
- Armored Core 6 repair kits, Fextralife: <https://armoredcore6.wiki.fextralife.com/Repair+Kit>
- MechWarrior 5: Sarna <https://www.sarna.net/wiki/MW5>, Steam discussion <https://steamcommunity.com/app/784080/discussions/0/3061871374464363658>
- Titanfall 2 tech test feedback, EA: <https://ea.com/games/titanfall/titanfall-2/amp/news/tech-test-and-feedback>
- Robin Hunicke and Vernell Chapman, "AI for Dynamic Difficulty Adjustment in Games" (Hamlet): <https://users.cs.northwestern.edu/~hunicke/pubs/Hamlet.pdf>
- Mark Davies, "Examining game pace: how single-player levels tick", Game Developer: <https://www.gamedeveloper.com/design/examining-game-pace-how-single-player-levels-tick>
- Mike Birkhead, "Pacing graphs and tips from a combat designer", Game Developer: <https://gamedeveloper.com/design/opinion-pacing-graphs-and-tips-from-a-combat-designer>
