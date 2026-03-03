v0.1 technically a game
+ motorcycle-only movement
  + akira slide bake
  + turning
  + accelerating
  + continue moving while shooting
  + shift movement
+ ui
  + 5 movement reticles
    + shows where you'd end up after:
      + firing (center)
      + wasd
+ 1 enemy (3x3)
+ really dumb mapgen
  + 1 zone (not fully fleshed out)
  + features:
    + rubble
    + debris
  + terrain:
    + asphalt
    + wall
    + interior
    + door
+ 1 weapon (gun)
+ can attack
+ can be attacked
+ enemy behavior:
  + chase player
    + kaiju can take partial steps
    + pathfinding
      + we don't need to be clever if they can smash through walls
      + they get stuck behind eggs (if we even add them)
  + smack player
    + if the player has 1 hp, you lose turkey
    + if the player has >1 hp, go to 1hp and get flung 10 spaces
    + destroy interveining walls
  + break obstacles
    + kaiju must spend a turn getting to the wall before tearing it down
  + spawning
  + kaiju obstruct each other's movement
+ no vision restrictions
v0.2 core features
- motorcycle destruction
  - if the motorcycle is destroyed when the player is on it, it becomes debris/rubble and the player
    is flung at speed
- vision (fov, reveal terrain)
- progression
  - gain inventory limit based on largest kaiju killed
- ui
  - death
  - title screen
  - combat log
  - legend
  - inventory
    - pick up item
    - replace item (item in inventory slot is destroyed to accomodate new item)
  - select weapon
    - indicate selected weapon
  - projectile indicator
- trinkets
  - damage bonuses
  - motorcycle bonuses
  - crit clocks
  - autoconsumable heal
+ animation
- audio
- enemy behavior
  - a-star to path around eggs? (maybe not eggs seem eh)
  - broken obstacles turn into things to dodge
  + sleep
+ dismounting/mounting motorcycles
- weapons
  - motorcycle
  - radioactive
  - explosive
- mapgen:
  - varying street sizes
    - alleys
  - zones
    + multiple zones of the same type can abut in a not grid-aligned way
    - commercial
    - nest
  - mechanical map features
    - vending machines
    - items
    - eggs
    - money
    - alternate motorcycles
  - terrain types
    - glass wall/door
    - painted asphalt (road stripes)
    - sidewalks
- more sizes/kinds of kaiju
  - kauji density map
  - big mama kaiju
  - kaiju spawn limit
- ability to win
- falling obstacles
  - warnings
  - animation
v0.3 stretch
- trinkets
  - detectors and map related things
  - vending luck
  - other stuff
  - dna sequencer
- mouse hover for info
- weapons
  - psychic
  - poison
- zones
  - residential
  - industrial
- flavorful map features
  - even more varieties of alternate motorcycles
  - trails of destruction
  - abandoned cars
  - potholes
  - fire hydrants
  - trees
  - grass
  - downed aircraft
- flavorful terrain stuff
  - broken glass
  - tire streaks
    - brake sounds
  - scorch marks
  - burn marks
  - blood
  - corpses (terrain type: viscera)
    - colliding with this terrain destroys it but makes you stop
      - leaves streaks of red when this happens
- enemy behavior
  - special attacks
    - beam
    - fire
    - leap
- consolidate orthogonal raycasting
