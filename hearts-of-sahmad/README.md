# Hearts of Sahmad 4

A grand strategy game in one HTML file. Plain JavaScript and Canvas 2D, no build step and no dependencies apart from Google Fonts.

## Run

Open `index.html` in any modern browser. To serve it locally instead:

```sh
cd hearts-of-sahmad
python3 -m http.server 8000   # then open http://localhost:8000
```

## What's in it

- **Map.** About 130 provinces generated from a seed (noise heightmap plus warped Voronoi cells), with terrain, cities and five nations. Sahmad always gets the second-largest realm.
- **Time.** Hourly ticks, five speeds and pause. Battles and movement run every hour; the economy, research and AI planning run daily.
- **Land combat.**
  - Each terrain type has a battle width, and every extra direction an attack comes from adds 50%, up to double.
  - Attack splits into soft and hard by the target's hardness. Hits land at 10% until they get past the target's defense (or breakthrough when the target is the attacker), then at 40%.
  - A division with no organization left retreats, or is destroyed if it has nowhere to go.
  - Forts and terrain favor the defender.
- **Supply.** Supply flows from the capital and every connected city, falls off with distance, and is cut when the route is cut. Low supply slows movement, weakens attacks, stops recovery and causes attrition.
- **Economy.**
  - Civilian factories build (consumer goods take a share set by law). Military factories feed three production lines.
  - Each line's efficiency climbs toward a cap, and a newly added factory dilutes the line's average.
  - Stability scales output.
- **Politics.** Political power, stability, war support, conscription and economy laws, a ten-node national focus tree, twelve technologies in two research slots, and random events with choices.
- **Diplomacy.** Justifying a war goal takes 30 days. You can declare war or offer white peace, and a nation capitulates and is annexed when it loses its capital and most of its home provinces.
- **AI.** AI nations recruit, build, research, justify wars on weaker neighbors, hold their borders and push their fronts. The Auto-front button hands your selected divisions to the same logic.
- **Saves.** The game autosaves every 30 days to `localStorage`, and the Game panel also saves and loads by hand.

All rules, numbers, names, flags and art are original. Nothing is taken from Paradox's game files.
