# Route Optimization Backend (Indonesia)

An open-source, Docker-deployable backend that provides **car route optimization**
for Indonesia. It combines two battle-tested open-source engines:

- **[OSRM](https://github.com/Project-OSRM/osrm-backend)** — fast routing engine
  that computes routes and distance matrices on **car-accessible roads only**.
- **[VROOM](https://github.com/VROOM-Project/vroom)** — a vehicle routing problem
  (VRP) solver that decides *which* vehicle visits *which* jobs in *what order*,
  using OSRM as its routing backend.

The "car-accessible roads only" constraint is enforced by OSRM's `car.lua`
profile, **not** by the optimizer. VROOM simply consumes the routes OSRM gives it.

> This is the repo other agents read when they need route optimization for
> Indonesia (e.g. WIM Driver APP delivery routing).

---

## 1. Plan / Architecture

```
                 +---------------------------+
   App / Agent   |   VROOM (port 3080)     |
   (HTTP)  ----> |  vroom-express server   |
                 +-----------+-------------+
                               |  (OSRM router)
                               v
                 +---------------------------+
                 |   OSRM (port 5000)       |
                 |  osrm-routed (car.lua)   |
                 |  MLD algorithm           |
                 +---------------------------+
                               |
                               v
                 pre-built routing data
                 (osrm-data/indonesia-latest.osrm)
                 built once from OSM PBF
```

**Two-layer design:**

1. **OSRM** owns the map. It holds the pre-processed road network for all of
   Indonesia and answers:
   - `GET /route` — fastest car route between two points (with geometry).
   - `GET /table` — N×N distance/duration matrix (used by VROOM).
   - `POST /match` — snap a GPS trace to the road network.

2. **VROOM** owns the optimization. Given vehicles, jobs (pickups/deliveries),
   and OSRM as its router, it solves the VRP and returns the optimal visit
   order per vehicle, including arrival times and total cost.

**Why this split?** OSRM is the fastest open routing engine for point-to-point
and matrix queries. VROOM is the reference open-source VRP solver with first-class
OSRM integration. Neither needs to be modified — the whole stack is stock,
Docker-deployable images.

### Car-accessible roads only

OSRM's `car.lua` profile already:
- Excludes `footway`, `path`, `pedestrian`, `cycleway`, `steps`.
- Excludes ways with `motorcar=no`, `access=no`, `access=private`.
- Applies a heavy penalty to `highway=service` (service roads).

For Indonesia-specific tuning (e.g. reject `maxwidth < 2.0 m`, block
`bollard`/`cycle_barrier`/`motorcycle_barrier`, penalize unpaved `track`), you
can copy `/opt/car.lua` out of the image, edit it, and mount it back — see
[Customizing the profile](#customizing-the-car-profile).

---

## 2. Setup

### Prerequisites
- Docker + Docker Compose
- **8 GB RAM**, **2+ vCPU**, **~25 GB disk** (full Indonesia)
- For Java-island-only (smaller footprint, ~4 GB RAM): use
  `https://download.geofabrik.de/asia/indonesia/java-latest.osm.pbf` instead.

### Step 1 — Download the OSM data

```bash
cd route-optimization-backend
curl -sL -o osm-indonesia-latest.osm.pbf \
  https://download.geofabrik.de/asia/indonesia-latest.osm.pbf
```

(For Java only, smaller: `.../asia/indonesia/java-latest.osm.pbf`)

### Step 2 — Pre-process into an OSRM database (one-time)

```bash
./preprocess-osrm.sh
```

This runs `osrm-extract` → `osrm-partition` → `osrm-customize` and writes
`osrm-data/indonesia-latest.osrm*`. **This is the slow step (20–60 min)** and
the most memory-hungry. You only re-run it when you update the OSM data.

### Step 3 — Start the services

```bash
docker compose up -d
```

- OSRM: `http://localhost:5000`
- VROOM: `http://localhost:3080`

### Step 4 — Verify

```bash
# OSRM is up:
curl "http://localhost:5000/health"

# VROOM is up (POST API; a GET / returns 404 by design):
curl -s -X POST http://localhost:3080/ \
  -H "Content-Type: application/json" \
  -d '{"vehicles":[{"id":1,"start_index":0,"end_index":0,"capacity":[10]}],
       "jobs":[{"id":1,"location_index":1,"delivery":[1],"service":10}],
       "matrices":{"car":{"durations":[[0,100],[100,0]]}}}'
```

---

## 3. Usage

### 3.1 VROOM — the main optimization endpoint

`POST http://localhost:3080/`

Request body (JSON):

```json
{
  "vehicles": [
    { "id": 1, "start_index": 0, "end_index": 0, "capacity": [10] }
  ],
  "jobs": [
    { "id": 1, "location_index": 1, "delivery": [1], "service": 10 },
    { "id": 2, "location_index": 2, "delivery": [1], "service": 10 },
    { "id": 3, "location_index": 3, "delivery": [1], "service": 10 }
  ],
  "locations": [
    { "lat": -6.2000, "lon": 106.8166 },
    { "lat": -6.1750, "lon": 106.8250 },
    { "lat": -6.1500, "lon": 106.8400 },
    { "lat": -6.1300, "lon": 106.8600 }
  ],
  "geometries": false
}
```

- `locations` — the list of coordinates. `start_index`/`end_index` and each
  job's `location_index` refer into this list.
- When `locations` is provided, VROOM asks **OSRM** for the real travel times
  (no `matrices` block needed). Omit `locations` and provide `matrices` instead
  to use a pre-computed matrix.
- `delivery`/`pickup` are arrays of goods; `capacity` must be at least as long.

**Response** (abridged):

```json
{
  "code": 0,
  "summary": { "cost": 650, "routes": 1, "unassigned": 0 },
  "routes": [
    {
      "vehicle": 1,
      "steps": [
        { "type": "start", "location_index": 0, "arrival": 0 },
        { "type": "job", "id": 3, "arrival": 300 },
        { "type": "job", "id": 2, "arrival": 410 },
        { "type": "job", "id": 1, "arrival": 550 },
        { "type": "end", "location_index": 0, "arrival": 680 }
      ]
    }
  ]
}
```

`code: 0` = success. `routes[].steps[]` is the optimized visit order with
arrival times.

### 3.2 OSRM — direct routing endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /route/v1/car/{lon1},{lat1};{lon2},{lat2}?overview=full&geometries=geojson` | Fastest car route + geometry |
| `GET /table/v1/car/{lon1},{lat1};{lon2},{lat2};...?annotations=duration,distance` | N×N distance/duration matrix |
| `POST /match/v1/car` | Map-match a GPS trace to roads |
| `GET /nearest/v1/car/{lon},{lat}?number=5` | Nearest routable nodes |

Example (route with geometry):

```bash
curl "http://localhost:5000/route/v1/car/106.8166,-6.2000;106.8453,-6.1956?overview=full&geometries=geojson"
```

Example (distance matrix):

```bash
curl "http://localhost:5000/table/v1/car/106.8166,-6.2000;106.8453,-6.1956;106.8650,-6.1800?annotations=duration,distance"
```

---

## 4. Deployment

### Local / single machine
```bash
./preprocess-osrm.sh        # one-time
docker compose up -d
```

### Production notes
- **OSRM data is read-only at runtime.** Build it once (`preprocess-osrm.sh`),
  then `osrm-routed` just serves it. Rebuild only on OSM data updates.
- **Memory:** OSRM extract needs ~8 GB peak. At runtime `osrm-routed` needs
  ~2–4 GB. VROOM needs ~1–2 GB.
- **Disk:** the `.osrm` files are ~15–25 GB for full Indonesia.
- **Ports:** OSRM `5000`, VROOM `3080` (change in `docker-compose.yml` if needed).
- **Scaling:** run multiple `osrm-routed` replicas behind a load balancer if
  query volume is high; VROOM is stateless per-request and scales horizontally.
- **Data updates:** re-download the PBF and re-run `preprocess-osrm.sh`, then
  `docker compose up -d` again.

### Customizing the car profile
To apply Indonesia-specific rules, extract the profile, edit it, and mount it:

```bash
docker run --rm -v "$PWD:/work" ghcr.io/project-osrm/osrm-backend:latest \
  cp /opt/car.lua /work/car-indonesia.lua
# edit car-indonesia.lua, then in preprocess use:
#   osrm-extract -p /data/car-indonesia.lua ...
```

---

## 5. Repository layout

```
route-optimization-backend/
├── README.md                  # this file
├── docker-compose.yml         # OSRM + VROOM services
├── preprocess-osrm.sh         # one-time OSM -> OSRM build
├── osm-indonesia-latest.osm.pbf   # (gitignored) downloaded OSM data
├── osrm-data/                 # (gitignored) built OSRM routing data
└── vroom-conf/
    └── config.yml             # VROOM express config (points to osrm-car)
```

## 6. References
- OSRM: https://github.com/Project-OSRM/osrm-backend
- VROOM: https://github.com/VROOM-Project/vroom
- vroom-express: https://github.com/VROOM-Project/vroom-express
- Geofabrik Indonesia: https://download.geofabrik.de/asia/indonesia.html
