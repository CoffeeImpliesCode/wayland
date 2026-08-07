# Dynamicland (Bret Victor / CDG) — research note for a canvas compositor

Date: 2026-08-07. Sources fetched live with the read tool; no web_search used.
Repo context: wayland compositor project, zig 0.16.0, jj. This note extracts
ideas from Dynamicland that map to a virtual large-canvas compositor usage layer.

## Source verification log

- https://dynamicland.org — OK (front shelf page).
- https://dynamicland.org/research — HTTP 404. /gallery — HTTP 404.
  https://dynamicland.org/Realtalk — HTTP 404. Current site has no such paths.
  [VERIFIED missing]
- https://web.archive.org/web/2023|2024/https://dynamicland.org/research — 404,
  no snapshot at that URL form. [UNVERIFIED whether an older /research page existed]
- https://en.wikipedia.org/wiki/Dynamicland — 404; Wikipedia search API confirms
  no article titled "Dynamicland" exists (only mentions inside other articles).
- https://en.wikipedia.org/wiki/Bret_Victor — OK (via Wikipedia API).
- https://cdg.co — connection failed; archived captures (2018, 2025) show a parked
  "for sale" page. Domain dead. [VERIFIED]
- https://dynamicland.org/2024/FAQ — OK, rich primary source.
- https://dynamicland.org/2024/Is_Realtalk_open_source — OK.
- https://dynamicland.org/archive/2017/Realtalk — OK.
- https://dynamicland.org/2014/CDG_research_agendas — OK.

## What Dynamicland is

- A nonprofit (501(c)(3)) research lab founded by Bret Victor, based in
  Oakland then Berkeley, California. Victor was a human-interface inventor at
  Apple 2007-2011 and joined the Communications Design Group (CDG) as a
  researcher in 2014. Source: https://en.wikipedia.org/wiki/Bret_Victor
- Self-description: "a prototype of a humane dynamic medium" — a computer that
  is a place, where people work together in the real world.
  Source: https://dynamicland.org
- 2017 to Covid: community workspace in Oakland. About a thousand participants
  created hundreds of projects through community hours, open houses, workshops,
  residencies. Next space: a "dynamic library" in Berkeley, not yet open
  (hoped for 2027). Source: https://dynamicland.org/2024/FAQ/
- Goals: universal literacy in a humane dynamic medium; a medium on par with
  literacy needs four things — a literate culture, a body of literature, a
  form of education, and technologies. Nonprofit narrative (2020):
  https://dynamicland.org/2020/Nonprofit_narrative.pdf
- Founding document: "The Humane Representation of Thought" (2014), a talk,
  poster, and 35-page CDG Research Agenda, all hosted at dynamicland.org:
  https://dynamicland.org/2014/CDG_research_agendas

## Realtalk — the live object system

- Realtalk is a computing environment (operating system, programming
  languages, philosophy) invented by the lab. It is made in itself and the
  lab does all day-to-day work in it. Even the website is made in Realtalk.
  Source: https://dynamicland.org/2024/FAQ/
- Working model: "rulecards all the way down". Objects make statements about
  the physical world (e.g. how close two objects are) and react to the
  statements of others: "When you see this, say that". An object can wish the
  world different (illuminate this, move that); a projector or robot arm
  performs the change. People are in the loop: Realtalk does not track
  people; people move stuff with their hands. Source: FAQ.
- Realtalk is a coordination language (Linda-style), with process languages
  plugged in: currently Lua, C, C++, Python, JavaScript, Julia, Haskell.
  Realtalk-2024 will add its own readable process language. Source: FAQ.
- All programs, in any language, are live-editable, recompile instantaneously,
  live-display their state, and can be physically picked up and pointed to.
  Source: FAQ.
- Iterations: Hypercard in the World (2016) -> La Tabla / Token table Realtalk /
  Realtalk Toys (2016) -> Realtalk-2017 (ran the community space for years) ->
  Realtalk-2020 (completeness, generality: virtual state, side effects,
  multiple recognizers/languages/sites) -> Realtalk-2024 (revising languages
  and physical forms). Source: FAQ and https://dynamicland.org/archive/2017/Realtalk
- Influences: Sketchpad, Smalltalk, Lisp machines, Self, HyperCard, Etoys,
  Inform 7, Linda, Datalog; plus Erlang, Clojure, Haskell, Forth. Related:
  STEPS project at Viewpoints Research Institute (VPRI). Source: FAQ.

## How it works technically (per public material)

- Environment sensing + actuation, not a virtual world. Projectors display
  text/images on real objects; cameras recognize objects. Current sensors are
  "off-the-shelf webcams" (research prototypes); the ideal sensor would sense
  material with high fidelity but be blind to people. Source: FAQ.
- Not just projection mapping: any sensors ("recognizers") and any actuators
  (projectors, a robotic table "Dragglebot", small robots "Pi bots").
  Source: FAQ.
- Physical failure modes are understood in physical terms: a creased paper, a
  covered corner, a bright sunbeam. This is presented as a feature (visible,
  fixable with sticky tape) versus opaque software bugs. Source: FAQ.
- Hardware: originally bolted to the ceiling in Oakland; today portable
  "dynalamps" (floor/desk lamps from commodity parts). Realtalk has run from a
  suitcase at conferences and a backpack in classrooms. Source: FAQ.
- Snapshots: physical arrangements can be snapshotted (including hand-drawn
  features) and reconstituted via printers/cutters/3D printers, placed
  robotically or "by hand with guidance". Robust reconstitution is a
  Realtalk-2024 goal. Source: FAQ.
- Complexity strategy: offload as much as possible to the physical world so
  the computing system stays small. "We accomplish most of our needs with
  zero lines of code, by using physical tools and just moving stuff around."
  Source: FAQ.

## Public vs not public

- No detailed technical report on how Realtalk works has been published:
  "We have not yet published a report about how Realtalk works in detail",
  intended after Realtalk-2024. The 2017 archive page repeats this.
  Sources: FAQ, https://dynamicland.org/archive/2017/Realtalk
- Not conventional open source. The essay "Is Realtalk open source?" splits
  the term into four: agency (maximally open — every running program is
  physically present and editable), publishing (intended later), product
  distribution (deliberately avoided — "We must carefully avoid anything that
  leads to product distribution"), and collaboration (in-person, physical).
  A Realtalk system "is not, and cannot be, represented as a directory tree
  of files". Source: https://dynamicland.org/2024/Is_Realtalk_open_source
- Long-term distribution: "kits+games" guiding communities to build their own
  environments; long long term, computing built into infrastructure "as
  electric light is today". Source: FAQ.
- All narrative material is public: progress reports (2014-2019 photo-comic,
  2020 video, 2021 handwritten letter, 2022 photo-comic), the 2017 zine, The
  Library (2019 fiction), the communal science lab booklet (2024), a large
  project archive. Index: https://dynamicland.org
- Third-party inspired projects exist, but the FAQ says studying them will
  not give insight into Realtalk. Source: FAQ.

## Stated direction and critiques

- Direction: the Berkeley dynamic library; communal science lab (bionano-
  technology, protein and nanostructure design in Realtalk, wet-lab
  integration); Realtalk-2024; education and community practice rather than
  products. Source: FAQ, https://dynamicland.org/2024/The_communal_science_lab.pdf
- Scale: "When we envision a humane dynamic medium at scale, we imagine a
  decentralized network of local communities, not a database serving millions
  of customers." Each site keeps an independent physical copy of Realtalk; no
  centralized official version. Source: FAQ.
- Anti-AI stance: visibility, agency (minimize what the computer knows),
  human connection, and "outsourcing understanding" are cited as reasons
  current AI is incompatible with Realtalk values. Source: FAQ.
- External critiques (cost of a dedicated room, in-person-only scaling,
  cameras/privacy) are addressed only in-house; I found no neutral third-party
  evaluation because there is no Wikipedia article. Cost facts available:
  hardware is commodity parts (webcams, projectors, lamps); a dedicated room
  was once required but is no longer. [UNVERIFIED for independent critiques]
- Privacy: no user accounts, "the stuff doesn't know whose stuff it is";
  most personal information never enters the system. Source: FAQ.

## CDG (Communications Design Group)

- Victor joined CDG in 2014 (Wikipedia). The 2014 humane-representation work
  was produced there; the 35-page "CDG Research Agenda" is hosted on
  dynamicland.org. Source: https://dynamicland.org/2014/CDG_research_agendas
- The cdg.co domain is dead (parked "for sale" in 2018 and 2025 archive
  captures). The common statement that CDG was a research lab at SAP is not
  confirmed by the sources I fetched. [UNVERIFIED: SAP affiliation]

## Mapping to a virtual large-canvas compositor

Maps well (conceptual transfer):

- Spatial persistence. "Every program is somewhere, all data is somewhere" —
  a core value. On a canvas, an object's position on the infinite plane is
  state; layout IS memory. Spatial relations between objects are meaningful
  and readable (grouping, adjacency as scoping). Source: FAQ core values.
- Live objects. Realtalk objects recompile instantaneously and live-display
  their state; nothing is hidden, "no black box". A canvas compositor layer
  can render every object from its live state, always current.
  Source: FAQ.
- Zoom/pan as spatial memory. Core value "Spatial ... multi-scale,
  walk-aroundable, gather-aroundable". Navigation of a large space at
  multiple scales replaces file/folder retrieval; place matters.
  Source: FAQ.
- Authorable, symmetric reading/writing, "no apps, no users", scratch-paper
  programs. Canvas objects should be inspectable and editable in place, not
  opaque app windows. Source: FAQ.
- Communal / multiplayer for free. In Realtalk, collocation makes sharing
  automatic; on a shared canvas, presence and shared state approximate this.
  Source: FAQ.
- Improvisational composition: simple objects with rich interactions,
  continuous combining and remixing. Fits a compositor whose primitives are
  composable surfaces. Source: FAQ.

Does not map (physical substrate is the point):

- Physical tokens, paper cards, cameras, projectors. "We do not think of the
  object as an 'interface' to a program running on a 'computer'." A screen
  canvas must simulate what Realtalk gets free from physics.
- Real-world embodiment and its failure modes (creasing, sunbeams) are
  deliberately cited as simplicity wins; a virtual canvas has no such
  grounding.
- Face-to-face in-person collaboration, "no head-mounted displays", no user
  accounts, minimal system knowledge. A software compositor necessarily knows
  a lot (windows, focus, permissions).
- Deliberate non-distribution and anti-product stance conflict with shipping
  software; the compositor takes the opposite route (a product others run).
- Complexity reduction via physical offload is unavailable in software: the
  canvas must pay the simulation cost Realtalk avoids. Source: FAQ.

## Bottom line for the compositor

- Take: spatial persistence, live always-current objects, multi-scale
  navigation as memory, in-place authorability, shared presence.
- Leave: paper/camera/projector substrate, deliberate opacity-free physical
  debugging, the no-product/no-accounts philosophy.
- Realtalk's actual implementation details are not public; anything beyond
  the FAQ-level description is [UNVERIFIED].
