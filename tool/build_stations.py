"""Regenerate assets/stations/mumbai_suburban.json from OpenStreetMap.

Coordinates come from OSM railway=station elements (nodes, or the centroid of the
platform way where OSM maps the station as an area). Station names in Devanagari
come from the OSM name:hi / name:mr tags, with a local fallback table for the
stations OSM has not tagged.

The line orders below are the canonical thing: OSM is queried only for geometry
and names, never for sequence, because OSM route relations are patchy on the
Mumbai network. Every station is resolved by OSM `ref` (the railway station code)
where one exists, since names collide (Dadar is both a Central and a Western
station, Jogeshwari appears twice, Kurla has a junk duplicate).

Run:  python tool/build_stations.py
It rewrites assets/stations/mumbai_suburban.json and prints an audit report.
Nothing is written if any station fails to resolve.
"""

from __future__ import annotations

import json
import math
import pathlib
import sys
import urllib.parse
import urllib.request

OVERPASS = "https://overpass-api.de/api/interpreter"
BBOX = (18.6, 72.6, 20.0, 73.6)  # south, west, north, east: Dahanu to Karjat
UA = "commute-guardian/0.1 (station coord verification; github.com/ShashankBallaya/commute-guardian)"

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "stations" / "mumbai_suburban.json"
CACHE = ROOT / "tool" / ".osm_cache.json"

# ---------------------------------------------------------------------------
# Station table: id -> (english name, OSM ref, preferred radius in metres)
#
# The OSM ref is the Indian Railways station code and is the join key. `None`
# means OSM has no ref on that element and we fall back to matching on the exact
# OSM name given in NAME_OVERRIDE.
# ---------------------------------------------------------------------------

# OSM has no `ref` on Vadala Road, so it is matched by exact OSM name and its code
# is supplied here by hand.
NAME_ONLY = {
    "vadala_road": ("Vadala Road", "VDLR"),
}

# Some stations are mapped by more than one OSM element sharing the same ref: a
# node plus a platform way, a suburban plus a mainline element, or simply a
# duplicate. Where the copies disagree, name the one to trust.
PREFER_OSM_NAME = {
    # Two nodes, both ref=JOS, 563m apart: one mapper split the Western and Harbour
    # platform groups. Jogeshwari is one station. The Western node is the correct
    # one: it puts Andheri-Jogeshwari-Ram Mandir at 1.83km/1.66km, matching the real
    # spacing, where the Harbour node skews it to 2.39km/1.10km.
    "JOS": "Jogeshwari (Western Line)",
    # Panvel is mapped twice, 250m apart. This is a suburban app, so take the
    # suburban platform rather than the mainline one.
    "PNVL": "Panvel (Suburban)",
}

# id: (name, ref, preferred_radius_m)
STATIONS = {
    # --- Central Main: CSMT to Kalyan -------------------------------------
    "csmt": ("CSMT", "CSMT", 500),
    "masjid": ("Masjid", "MSD", 300),
    "sandhurst_road": ("Sandhurst Road", "SNRD", 300),
    "byculla": ("Byculla", "BY", 350),
    "chinchpokli": ("Chinchpokli", "CHG", 300),
    "currey_road": ("Currey Road", "CRD", 300),
    "parel": ("Parel", "PR", 350),
    "dadar": ("Dadar", "DR", 450),
    "matunga": ("Matunga", "MTN", 350),
    "sion": ("Sion", "SIN", 350),
    "kurla": ("Kurla", "CLA", 450),
    "vidyavihar": ("Vidyavihar", "VVH", 350),
    "ghatkopar": ("Ghatkopar", "GC", 400),
    "vikhroli": ("Vikhroli", "VK", 400),
    "kanjurmarg": ("Kanjurmarg", "KJRD", 400),
    "bhandup": ("Bhandup", "BND", 400),
    "nahur": ("Nahur", "NHU", 350),
    "mulund": ("Mulund", "MLND", 400),
    "thane": ("Thane", "TNA", 500),
    "kalwa": ("Kalwa", "KLVA", 400),
    "mumbra": ("Mumbra", "MBQ", 400),
    "diva": ("Diva Junction", "DIVA", 400),
    "kopar": ("Kopar", "KOPR", 400),
    "dombivli": ("Dombivli", "DI", 450),
    "thakurli": ("Thakurli", "THK", 400),
    "kalyan": ("Kalyan", "KYN", 500),
    # --- Central: Kalyan to Kasara ----------------------------------------
    "shahad": ("Shahad", "SHAD", 350),
    "ambivli": ("Ambivli", "ABY", 350),
    "titwala": ("Titwala", "TLA", 400),
    "khadavli": ("Khadavli", "KDV", 400),
    "vasind": ("Vasind", "VSD", 400),
    "asangaon": ("Asangaon", "ASO", 400),
    "atgaon": ("Atgaon", "ATG", 400),
    "thansit": ("Thansit", "THS", 400),
    "khardi": ("Khardi", "KE", 400),
    "umbermali": ("Umbermali", "OMB", 400),
    "kasara": ("Kasara", "KSRA", 500),
    # --- Central: Kalyan to Karjat ----------------------------------------
    "vithalwadi": ("Vithalwadi", "VLDI", 400),
    "ulhasnagar": ("Ulhasnagar", "ULNR", 400),
    "ambernath": ("Ambernath", "ABH", 400),
    "badlapur": ("Badlapur", "BUD", 400),
    "vangani": ("Vangani", "VGI", 400),
    "shelu": ("Shelu", "SHLU", 400),
    "neral": ("Neral Junction", "NRL", 450),
    "bhivpuri_road": ("Bhivpuri Road", "BVS", 400),
    "karjat": ("Karjat", "KJT", 500),
    # --- Western: Churchgate to Dahanu Road --------------------------------
    "churchgate": ("Churchgate", "CCG", 450),
    "marine_lines": ("Marine Lines", "MEL", 300),
    "charni_road": ("Charni Road", "CYR", 300),
    "grant_road": ("Grant Road", "GTR", 350),
    "mumbai_central": ("Mumbai Central", "MMCT", 450),
    "mahalaxmi": ("Mahalaxmi", "MX", 350),
    "lower_parel": ("Lower Parel", "PL", 350),
    "prabhadevi": ("Prabhadevi", "PBHD", 350),
    "dadar_western": ("Dadar", "DDR", 450),
    "matunga_road": ("Matunga Road", "MRU", 350),
    "mahim": ("Mahim Junction", "MM", 400),
    "bandra": ("Bandra", "BA", 450),
    "khar_road": ("Khar Road", "KHAR", 350),
    "santacruz": ("Santacruz", "STC", 400),
    "vile_parle": ("Vile Parle", "VLP", 400),
    "andheri": ("Andheri", "ADH", 500),
    "jogeshwari": ("Jogeshwari", "JOS", 400),
    "ram_mandir": ("Ram Mandir", "RMAR", 350),
    "goregaon": ("Goregaon", "GMN", 450),
    "malad": ("Malad", "MDD", 400),
    "kandivali": ("Kandivali", "KILE", 400),
    "borivali": ("Borivali", "BVI", 500),
    "dahisar": ("Dahisar", "DIC", 400),
    "mira_road": ("Mira Road", "MIRA", 400),
    "bhayandar": ("Bhayandar", "BYR", 450),
    "naigaon": ("Naigaon", "NIG", 400),
    "vasai_road": ("Vasai Road", "BSR", 500),
    "nallasopara": ("Nallasopara", "NSP", 450),
    "virar": ("Virar", "VR", 500),
    "vaitarna": ("Vaitarna", "VTN", 400),
    "saphale": ("Saphale", "SAH", 400),
    "kelve_road": ("Kelve Road", "KLV", 400),
    "palghar": ("Palghar", "PLG", 450),
    "umroli": ("Umroli", "UOI", 400),
    "boisar": ("Boisar", "BOR", 450),
    "vangaon": ("Vangaon", "VGN", 400),
    "dahanu_road": ("Dahanu Road", "DRD", 500),
    # --- Harbour: CSMT to Panvel -------------------------------------------
    "dockyard_road": ("Dockyard Road", "DKRD", 300),
    "reay_road": ("Reay Road", "RRD", 300),
    "cotton_green": ("Cotton Green", "CTGN", 300),
    "sewri": ("Sewri", "SVE", 350),
    "vadala_road": ("Vadala Road", None, 400),
    "gtb_nagar": ("GTB Nagar", "GTBN", 350),
    "chunabhatti": ("Chunabhatti", "CHF", 350),
    "tilak_nagar": ("Tilak Nagar", "TKNG", 350),
    "chembur": ("Chembur", "CMBR", 400),
    "govandi": ("Govandi", "GV", 400),
    "mankhurd": ("Mankhurd", "MNKD", 400),
    "vashi": ("Vashi", "VSH", 450),
    "sanpada": ("Sanpada", "SNCR", 400),
    "juinagar": ("Juinagar", "JNJ", 400),
    "nerul": ("Nerul", "NEU", 450),
    "seawoods": ("Seawoods Darave", "SWDV", 400),
    "belapur": ("CBD Belapur", "BEPR", 450),
    "kharghar": ("Kharghar", "KHAG", 400),
    "mansarovar": ("Mansarovar", "MANR", 400),
    "khandeshwar": ("Khandeshwar", "KNDS", 400),
    "panvel": ("Panvel", "PNVL", 500),
    # --- Harbour: Vadala Road to Goregaon ----------------------------------
    "kings_circle": ("King's Circle", "KCE", 350),
    # --- Trans-Harbour: Thane to Vashi/Panvel ------------------------------
    "digha": ("Digha Gaon", "DIGH", 350),
    "airoli": ("Airoli", "AIRL", 400),
    "rabale": ("Rabale", "RABE", 400),
    "ghansoli": ("Ghansoli", "GNSL", 400),
    "koparkhairane": ("Koparkhairane", "KPHN", 400),
    "turbhe": ("Turbhe", "TUH", 400),
    # --- Uran line: Nerul/Belapur to Uran ----------------------------------
    "targhar": ("Targhar", "TRGHR", 350),
    "bamandongri": ("Bamandongri", "BMDR", 350),
    "kharkopar": ("Kharkopar", "KARP", 400),
    "ranjanpada": ("Ranjanpada", "RJNPD", 400),
    "nhava_sheva": ("Nhava Sheva", "NHVSV", 400),
    "dronagiri": ("Dronagiri", "DRNGR", 400),
    "uran": ("Uran City", "UNCT", 450),
    # --- Vasai Road to Diva / Diva to Panvel -------------------------------
    "juichandra": ("Juichandra", "JCNR", 400),
    "kaman_road": ("Kaman Road", "KARD", 400),
    "kharbao": ("Kharbao", "KHBV", 400),
    "bhiwandi_road": ("Bhiwandi Road", "BIRD", 400),
    "dativali": ("Dativali", "DTVL", 400),
    "nilaje": ("Nilaje", "NIIJ", 400),
    "taloja": ("Taloja Panchanand", "TPND", 400),
    "navade_road": ("Navade Road", "NVRD", 400),
    "kalamboli": ("Kalamboli", "KLMC", 400),
}

# Fallbacks for stations OSM has not tagged with name:hi / name:mr. Each side is
# used independently: OSM wins where it has the tag, this table fills the hole.
DEVANAGARI_FALLBACK = {
    # id: (hindi, marathi)
    "gtb_nagar": ("जीटीबी नगर", "जीटीबी नगर"),
    "vadala_road": ("वडाला रोड", "वडाळा रोड"),
    "seawoods": ("सीवुड्स दारावे", "सीवूड्स दारावे"),
    "targhar": ("तरघर", "तरघर"),
    "bamandongri": ("बामणडोंगरी", "बामणडोंगरी"),
    "kharkopar": ("खारकोपर", "खारकोपर"),
    "ranjanpada": ("रांजणपाडा", "रांजणपाडा"),
    "nhava_sheva": ("न्हावा शेवा", "न्हावा शेवा"),
    "dronagiri": ("द्रोणागिरी", "द्रोणागिरी"),
    "uran": ("उरण सिटी", "उरण सिटी"),
    "juichandra": ("जुईचंद्र", "जुईचंद्र"),
    "kaman_road": ("कामण रोड", "कामण रोड"),
    "kharbao": ("खारबाव", "खारबाव"),
    "bhiwandi_road": ("भिवंडी रोड", "भिवंडी रोड"),
    "dativali": ("दातिवली", "दातिवली"),
    "nilaje": ("निळजे", "निळजे"),
    "taloja": ("तळोजा पंचानंद", "तळोजा पंचानंद"),
    "navade_road": ("नवडे रोड", "नवडे रोड"),
    "kalamboli": ("कळंबोली", "कळंबोली"),
    "umbermali": ("उंबरमाळी", "उंबरमाळी"),
    "ambivli": ("आंबिवली", "आंबिवली"),
    "thansit": ("थानसित", "थानसित"),
    "jogeshwari": ("जोगेश्वरी", "जोगेश्वरी"),
    "jogeshwari_harbour": ("जोगेश्वरी", "जोगेश्वरी"),
    "umroli": ("उमरोली", "उमरोळी"),
    "dahanu_road": ("डहाणू रोड", "डहाणू रोड"),
    "dockyard_road": ("डॉकयार्ड रोड", "डॉकयार्ड रोड"),
    "reay_road": ("रे रोड", "रे रोड"),
    "cotton_green": ("कॉटन ग्रीन", "कॉटन ग्रीन"),
    "sewri": ("शिवड़ी", "शिवडी"),
    "chembur": ("चेंबुर", "चेंबूर"),
    "govandi": ("गोवंडी", "गोवंडी"),
    "mankhurd": ("मानखुर्द", "मानखुर्द"),
    "vashi": ("वाशी", "वाशी"),
    "sanpada": ("सानपाडा", "सानपाडा"),
    "juinagar": ("जुईनगर", "जुईनगर"),
    "nerul": ("नेरुल", "नेरूळ"),
    "belapur": ("सीबीडी बेलापुर", "सी बी डी बेलापूर"),
    "kharghar": ("खारघर", "खारघर"),
    "mansarovar": ("मानसरोवर", "मानसरोवर"),
    "khandeshwar": ("खांदेश्वर", "खांदेश्वर"),
    "airoli": ("ऐरोली", "ऐरोली"),
    "rabale": ("रबाळे", "रबाळे"),
    "koparkhairane": ("कोपरखैरने", "कोपरखैरणे"),
    "turbhe": ("तुर्भे", "तुर्भे"),
    # The mainline Panvel node carries name:hi/name:mr, but PREFER_OSM_NAME points
    # us at the suburban platform element, which does not.
    "panvel": ("पनवेल", "पनवेल"),
}

# ---------------------------------------------------------------------------
# Lines, in travel order. These are the canonical sequences.
# ---------------------------------------------------------------------------

LINES = [
    (
        "central_csmt_kalyan",
        "Central Main: CSMT - Kalyan",
        ["csmt", "masjid", "sandhurst_road", "byculla", "chinchpokli", "currey_road",
         "parel", "dadar", "matunga", "sion", "kurla", "vidyavihar", "ghatkopar",
         "vikhroli", "kanjurmarg", "bhandup", "nahur", "mulund", "thane", "kalwa",
         "mumbra", "diva", "kopar", "dombivli", "thakurli", "kalyan"],
    ),
    (
        "central_kalyan_kasara",
        "Central: Kalyan - Kasara",
        ["kalyan", "shahad", "ambivli", "titwala", "khadavli", "vasind", "asangaon",
         "atgaon", "thansit", "khardi", "umbermali", "kasara"],
    ),
    (
        "central_kalyan_karjat",
        "Central: Kalyan - Karjat",
        ["kalyan", "vithalwadi", "ulhasnagar", "ambernath", "badlapur", "vangani",
         "shelu", "neral", "bhivpuri_road", "karjat"],
    ),
    (
        "western_churchgate_dahanu",
        "Western: Churchgate - Dahanu Road",
        ["churchgate", "marine_lines", "charni_road", "grant_road", "mumbai_central",
         "mahalaxmi", "lower_parel", "prabhadevi", "dadar_western", "matunga_road",
         "mahim", "bandra", "khar_road", "santacruz", "vile_parle", "andheri",
         "jogeshwari", "ram_mandir", "goregaon", "malad", "kandivali", "borivali",
         "dahisar", "mira_road", "bhayandar", "naigaon", "vasai_road", "nallasopara",
         "virar", "vaitarna", "saphale", "kelve_road", "palghar", "umroli", "boisar",
         "vangaon", "dahanu_road"],
    ),
    (
        "harbour_csmt_panvel",
        "Harbour: CSMT - Panvel",
        ["csmt", "masjid", "sandhurst_road", "dockyard_road", "reay_road",
         "cotton_green", "sewri", "vadala_road", "gtb_nagar", "chunabhatti", "kurla",
         "tilak_nagar", "chembur", "govandi", "mankhurd", "vashi", "sanpada",
         "juinagar", "nerul", "seawoods", "belapur", "kharghar", "mansarovar",
         "khandeshwar", "panvel"],
    ),
    (
        "harbour_csmt_goregaon",
        "Harbour: CSMT - Goregaon",
        ["csmt", "masjid", "sandhurst_road", "dockyard_road", "reay_road",
         "cotton_green", "sewri", "vadala_road", "kings_circle", "mahim", "bandra",
         "khar_road", "santacruz", "vile_parle", "andheri", "jogeshwari",
         "ram_mandir", "goregaon"],
    ),
    (
        "trans_harbour_thane_panvel",
        "Trans-Harbour: Thane - Panvel",
        ["thane", "digha", "airoli", "rabale", "ghansoli", "koparkhairane", "turbhe",
         "juinagar", "nerul", "seawoods", "belapur", "kharghar", "mansarovar",
         "khandeshwar", "panvel"],
    ),
    (
        "trans_harbour_thane_vashi",
        "Trans-Harbour: Thane - Vashi",
        ["thane", "digha", "airoli", "rabale", "ghansoli", "koparkhairane", "turbhe",
         "sanpada", "vashi"],
    ),
    (
        "uran_nerul_uran",
        "Uran: Nerul - Uran",
        ["nerul", "seawoods", "targhar", "bamandongri", "kharkopar", "ranjanpada",
         "nhava_sheva", "dronagiri", "uran"],
    ),
    (
        "vasai_diva",
        "Vasai Road - Diva",
        ["vasai_road", "juichandra", "kaman_road", "kharbao", "bhiwandi_road",
         "dativali", "kopar", "diva"],
    ),
    (
        "diva_panvel",
        "Diva - Panvel",
        ["diva", "dativali", "nilaje", "taloja", "navade_road", "kalamboli", "panvel"],
    ),
    # The 11 Jul 2026 field-ride chain. Kept verbatim so past rides stay reproducible.
    (
        "harbour_ride_kalyan_digha",
        "Ride: Kalyan - Digha (Central to Thane, change to Trans-Harbour)",
        ["kalyan", "thakurli", "dombivli", "kopar", "diva", "mumbra", "kalwa", "thane",
         "digha", "airoli"],
    ),
]

MIN_RADIUS_M = 200
CLEARANCE_M = 100  # required gap between two adjacent stations' fences


def fetch_osm() -> list[dict]:
    if CACHE.exists():
        print(f"using cached OSM dump: {CACHE}")
        return json.loads(CACHE.read_text(encoding="utf-8"))["elements"]

    s, w, n, e = BBOX
    query = (
        f"[out:json][timeout:90];"
        f'(nwr["railway"~"^(station|halt)$"]({s},{w},{n},{e}););'
        f"out tags center;"
    )
    print("querying Overpass...")
    req = urllib.request.Request(
        OVERPASS,
        data=urllib.parse.urlencode({"data": query}).encode(),
        headers={"User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read().decode("utf-8")
    CACHE.write_text(body, encoding="utf-8")
    print(f"cached to {CACHE}")
    return json.loads(body)["elements"]


def clean(name: str | None) -> str | None:
    if not name:
        return None
    return name.replace("‍", "").replace("‌", "").strip() or None


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = math.radians(b[0] - a[0])
    dl = math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def resolve() -> tuple[dict, list[str]]:
    elements = fetch_osm()
    by_ref: dict[str, list[dict]] = {}
    by_name: dict[str, list[dict]] = {}
    for el in elements:
        tags = el.get("tags", {})
        if "Metro" in tags.get("operator", "") or "MMRDA" in tags.get("operator", ""):
            continue
        lat = el.get("lat") or el.get("center", {}).get("lat")
        lon = el.get("lon") or el.get("center", {}).get("lon")
        if lat is None or lon is None:
            continue
        rec = {"lat": lat, "lon": lon, "tags": tags}
        if tags.get("ref"):
            by_ref.setdefault(tags["ref"], []).append(rec)
        if tags.get("name"):
            by_name.setdefault(tags["name"], []).append(rec)

    resolved: dict[str, dict] = {}
    problems: list[str] = []

    for sid, (name, ref, radius) in STATIONS.items():
        if ref:
            code = ref
            cands = by_ref.get(ref, [])
            # A code can appear on several OSM elements: a node plus a platform way,
            # a suburban plus a mainline element, or an outright duplicate. Prefer a
            # railway=station element, then the copy named in PREFER_OSM_NAME.
            cands = [c for c in cands if c["tags"].get("railway") == "station"] or cands
            if ref in PREFER_OSM_NAME and len(cands) > 1:
                cands = [c for c in cands
                         if c["tags"].get("name") == PREFER_OSM_NAME[ref]] or cands
            elif len(cands) > 1:
                # Duplicate elements that sit on top of each other are harmless,
                # take either. Duplicates that disagree about where the station is
                # need a human to pick, so say so.
                spread = max(
                    haversine_m((a["lat"], a["lon"]), (b["lat"], b["lon"]))
                    for a in cands for b in cands
                )
                if spread > 100:
                    problems.append(
                        f"AMBIGUOUS {sid}: {len(cands)} OSM elements carry ref={ref} "
                        f"and they disagree by {spread:.0f}m; took "
                        f"{cands[0]['tags'].get('name')!r}. Add {ref!r} to "
                        f"PREFER_OSM_NAME to choose."
                    )
            rec = cands[0] if cands else None
        else:
            osm_name, code = NAME_ONLY[sid]
            cands = by_name.get(osm_name, [])
            rec = cands[0] if cands else None

        if rec is None:
            problems.append(f"UNRESOLVED {sid} (name={name!r} ref={ref!r})")
            continue

        tags = rec["tags"]
        # OSM tags some Devanagari names with zero-width joiners (Jogeshwari is
        # जोगेश्<ZWJ>वरी). They are a rendering hint, they carry no meaning, and
        # they are noise inside a TTS string.
        hi = clean(tags.get("name:hi"))
        mr = clean(tags.get("name:mr"))
        fb = DEVANAGARI_FALLBACK.get(sid)
        if not hi:
            hi = fb[0] if fb else None
        if not mr:
            mr = fb[1] if fb else None
        if not hi or not mr:
            problems.append(f"NO DEVANAGARI for {sid} ({name}): hi={hi!r} mr={mr!r}")

        resolved[sid] = {
            "id": sid,
            "code": code,
            "name": name,
            "nameHi": hi or name,
            "nameMr": mr or name,
            "lat": round(rec["lat"], 7),
            "lng": round(rec["lon"], 7),
            "radiusM": radius,
        }

    # Two stations sharing a code means one real station has been split in two.
    # That is how the Jogeshwari duplicate (Western and Harbour platform groups
    # mapped as separate nodes, both ref=JOS) got into the data in the first place.
    seen: dict[str, str] = {}
    for sid, s in resolved.items():
        clash = seen.get(s["code"])
        if clash:
            problems.append(
                f"DUPLICATE CODE {s['code']}: {clash} and {sid} are the same "
                f"station. Merge them."
            )
        seen[s["code"]] = sid

    return resolved, problems


def shrink_radii(resolved: dict) -> list[str]:
    """Shrink radii until no two adjacent stations on any line have overlapping
    fences. A commuter crossing into two fences at once gets two announcements,
    and the geofence engine cannot say which station they are actually at."""
    notes: list[str] = []
    for _, _, ids in LINES:
        for a, b in zip(ids, ids[1:]):
            sa, sb = resolved[a], resolved[b]
            d = haversine_m((sa["lat"], sa["lng"]), (sb["lat"], sb["lng"]))
            budget = d - CLEARANCE_M
            if sa["radiusM"] + sb["radiusM"] <= budget:
                continue
            if budget < 2 * MIN_RADIUS_M:
                notes.append(
                    f"TOO CLOSE {a}-{b}: {d:.0f}m apart, cannot fit two "
                    f"{MIN_RADIUS_M}m fences with {CLEARANCE_M}m clearance"
                )
                sa["radiusM"] = sb["radiusM"] = MIN_RADIUS_M
                continue
            total = sa["radiusM"] + sb["radiusM"]
            ra = max(MIN_RADIUS_M, int(budget * sa["radiusM"] / total // 10 * 10))
            rb = max(MIN_RADIUS_M, int(budget * sb["radiusM"] / total // 10 * 10))
            notes.append(
                f"shrink {a} {sa['radiusM']}->{ra}, {b} {sb['radiusM']}->{rb} "
                f"(gap {d:.0f}m)"
            )
            sa["radiusM"], sb["radiusM"] = ra, rb
    return notes


def sanity_check(resolved: dict) -> list[str]:
    """Catch a mis-ordered line or a station pinned to the wrong place. On a real
    rail line consecutive stops are never under 400m apart, and on this network
    never more than about 13km: the widest genuine gap is Vangaon to Dahanu Road
    at 12.2km on the far-north Western line, so the ceiling sits just above it."""
    problems: list[str] = []
    for lid, _, ids in LINES:
        for a, b in zip(ids, ids[1:]):
            sa, sb = resolved[a], resolved[b]
            d = haversine_m((sa["lat"], sa["lng"]), (sb["lat"], sb["lng"]))
            if d < 400:
                problems.append(f"SUSPECT {lid}: {a}-{b} only {d:.0f}m apart")
            if d > 13000:
                problems.append(f"SUSPECT {lid}: {a}-{b} {d/1000:.1f}km apart")
    return problems


def main() -> int:
    resolved, problems = resolve()

    fatal = [p for p in problems
             if p.startswith(("UNRESOLVED", "DUPLICATE CODE"))]
    if fatal:
        print("\n".join(problems))
        print(f"\nABORT: {len(fatal)} fatal problem(s); nothing written.")
        return 1

    shrink_notes = shrink_radii(resolved)
    suspects = sanity_check(resolved)

    for note in problems:
        print("  warn:", note)
    for note in shrink_notes:
        print("  radius:", note)
    for note in suspects:
        print("  SUSPECT:", note)

    stations = [{k: v for k, v in s.items() if not k.startswith("_")}
                for s in resolved.values()]
    doc = {
        "note": (
            "Generated by tool/build_stations.py from OpenStreetMap railway=station "
            "elements. Do not hand-edit: rerun the script. Coordinates are OSM station "
            "nodes, or the centroid of the platform way where OSM maps the station as "
            "an area (most of Navi Mumbai). Radii start from a per-station preferred "
            "value and are shrunk automatically so no two adjacent stations on a line "
            "have overlapping fences (100m minimum clearance). Devanagari names are OSM "
            "name:hi / name:mr where tagged, else a hand-filled fallback table in the "
            "script. Coordinates are map-accurate but NOT field-verified: only the "
            "Kalyan-Digha ride chain has been crossed with a real GPS trace."
        ),
        "stations": stations,
        "lines": [{"id": lid, "name": name, "stationIds": ids}
                  for lid, name, ids in LINES],
    }
    OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")

    print(f"\nwrote {OUT.relative_to(ROOT)}")
    print(f"  {len(stations)} stations, {len(LINES)} lines")
    if suspects:
        print(f"  {len(suspects)} geometry suspect(s) above: check before trusting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
