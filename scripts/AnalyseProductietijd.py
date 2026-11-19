"""Berekent productietijden uit GET /web/npp/productietijd.

Gebruik:
    python AnalyseProductietijd.py [json-bestand] [uitvoermap]

Zonder argumenten wordt http://localhost:8080/web/npp/productietijd opgehaald
(AUTH_TOKEN env var wordt als X-Auth-Token meegestuurd indien gezet).

Per (programma, bonnr, groepnr, id) loopt een interval van Start/Herstart tot
de eerstvolgende Pauze/Stop/Afgewerkt/Afgebroken. Een interval zonder einde
(of > MAX_UUR) wordt als "open" geteld en niet in de netto tijd opgenomen.
"""
import csv
import json
import os
import sys
import urllib.request
from collections import defaultdict
from datetime import datetime
from statistics import median

URL = "http://localhost:8080/web/npp/productietijd"
BEGIN = {"Start", "Herstart"}
EINDE = {"Pauze", "Stop", "Afgewerkt", "Afgebroken"}
MAX_UUR = 12


def load(path):
    if path:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(URL)
    if os.environ.get("AUTH_TOKEN"):
        req.add_header("X-Auth-Token", os.environ["AUTH_TOKEN"])
    with urllib.request.urlopen(req, timeout=280) as r:
        return json.load(r)


def ts(i):
    return datetime.fromisoformat(f"{i['datum']}T{i['uur'] or '00:00:00'}")


def main():
    data = load(sys.argv[1] if len(sys.argv) > 1 else None)
    out = sys.argv[2] if len(sys.argv) > 2 else "."
    groups = defaultdict(list)
    for i in data["items"]:
        if i["actie"] in BEGIN | EINDE:
            groups[(i["programma"], i["bonnr"], i["groepnr"], i["id"])].append(i)

    rows, open_count = [], 0
    for (prog, bon, groep, uid), items in groups.items():
        items.sort(key=lambda x: (ts(x), x["volgnr"]))
        start, net, pauzes, first, last, klaar = None, 0.0, 0, None, None, False
        for i in items:
            t = ts(i)
            if i["actie"] in BEGIN:
                if start is not None:
                    open_count += 1
                start = t
                first = first or t
            else:
                if start is not None:
                    sec = (t - start).total_seconds()
                    if 0 <= sec <= MAX_UUR * 3600:
                        net += sec
                    else:
                        open_count += 1
                    start = None
                    last = t
                if i["actie"] == "Pauze":
                    pauzes += 1
                if i["actie"] == "Afgewerkt":
                    klaar = True
        if start is not None:
            open_count += 1
        artnr = next((i["artnr"] for i in items if i["artnr"]), "") or items[0].get("montageArtnr", "")
        aantal = items[0].get("montageAantal", 0) or 0
        rows.append({
            "programma": prog, "bonnr": bon, "groepnr": groep, "id": uid,
            "artnr": artnr, "aantal": aantal,
            "maand": first.strftime("%Y-%m") if first else "",
            "eerste_start": first.isoformat() if first else "",
            "laatste_einde": last.isoformat() if last else "",
            "netto_minuten": round(net / 60, 1), "pauzes": pauzes,
            "afgewerkt": int(klaar),
        })

    rows.sort(key=lambda r: (r["programma"], r["eerste_start"]))
    path = os.path.join(out, "productietijd_per_bon.csv")
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), delimiter=";")
        w.writeheader()
        w.writerows(rows)

    print(f"{path}: {len(rows)} rijen, {open_count} open/ongeldige intervallen")
    per_prog = defaultdict(list)
    for r in rows:
        if r["netto_minuten"] > 0:
            per_prog[r["programma"]].append(r["netto_minuten"])
    print(f"{'programma':20} {'#':>6} {'mediaan min':>12} {'gem min':>9} {'totaal uur':>11}")
    for p, v in sorted(per_prog.items()):
        print(f"{p:20} {len(v):6} {median(v):12.1f} {sum(v)/len(v):9.1f} {sum(v)/60:11.1f}")

    per_art = defaultdict(list)
    for r in rows:
        if r["netto_minuten"] > 0:
            per_art[(r["programma"], r["artnr"] or "(geen artikel)")].append(r)
    art_rows = []
    for (p, a), rs in per_art.items():
        mins = [r["netto_minuten"] for r in rs]
        per_eenheid = [r["netto_minuten"] / r["aantal"] for r in rs if r["aantal"]]
        art_rows.append({
            "programma": p, "artnr": a, "bon_groepen": len(rs),
            "totaal_uur": round(sum(mins) / 60, 1),
            "mediaan_min": round(median(mins), 1),
            "gem_min": round(sum(mins) / len(mins), 1),
            "mediaan_min_per_eenheid": round(median(per_eenheid), 2) if per_eenheid else "",
        })
    art_rows.sort(key=lambda r: (r["programma"], -r["totaal_uur"]))
    apath = os.path.join(out, "productietijd_per_artikel.csv")
    with open(apath, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(art_rows[0]), delimiter=";")
        w.writeheader()
        w.writerows(art_rows)
    print(f"\n{apath}: {len(art_rows)} artikelen. Top 15 PRODUCTIE naar totaaltijd:")
    print(f"{'artnr':28} {'#':>5} {'tot uur':>8} {'med min':>8} {'min/eenh':>9}")
    for r in [x for x in art_rows if x["programma"] == "PRODUCTIE"][:15]:
        print(f"{r['artnr'][:28]:28} {r['bon_groepen']:5} {r['totaal_uur']:8} {r['mediaan_min']:8} {str(r['mediaan_min_per_eenheid']):>9}")

    per_art_user = defaultdict(list)
    for r in rows:
        if r["netto_minuten"] > 0:
            per_art_user[(r["programma"], r["artnr"] or "(geen artikel)", r["id"])].append(r)
    au_rows = []
    for (p, a, u), rs in per_art_user.items():
        mins = [r["netto_minuten"] for r in rs]
        per_eenheid = [r["netto_minuten"] / r["aantal"] for r in rs if r["aantal"]]
        au_rows.append({
            "programma": p, "artnr": a, "id": u, "bon_groepen": len(rs),
            "totaal_uur": round(sum(mins) / 60, 1),
            "mediaan_min": round(median(mins), 1),
            "mediaan_min_per_eenheid": round(median(per_eenheid), 2) if per_eenheid else "",
        })
    au_rows.sort(key=lambda r: (r["programma"], r["artnr"], -r["totaal_uur"]))
    aupath = os.path.join(out, "productietijd_per_artikel_operator.csv")
    with open(aupath, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(au_rows[0]), delimiter=";")
        w.writeheader()
        w.writerows(au_rows)
    print(f"\n{aupath}: {len(au_rows)} rijen. PRODUCTIE top-6 artikelen per operator (n>=5, mediaan min/eenheid):")
    top = [x["artnr"] for x in art_rows if x["programma"] == "PRODUCTIE"][:6]
    for a in top:
        parts = [f"{r['id']}: {r['mediaan_min_per_eenheid']} (n={r['bon_groepen']})"
                 for r in au_rows if r["programma"] == "PRODUCTIE" and r["artnr"] == a and r["bon_groepen"] >= 5]
        print(f"  {a[:26]:26} " + " | ".join(parts))

    per_maand = defaultdict(list)
    for r in rows:
        if r["netto_minuten"] > 0 and r["maand"]:
            per_maand[(r["programma"], r["artnr"] or "(geen artikel)", r["maand"])].append(r)
    m_rows = []
    for (p, a, m), rs in per_maand.items():
        mins = [r["netto_minuten"] for r in rs]
        per_eenheid = [r["netto_minuten"] / r["aantal"] for r in rs if r["aantal"]]
        m_rows.append({
            "programma": p, "artnr": a, "maand": m, "bon_groepen": len(rs),
            "totaal_uur": round(sum(mins) / 60, 1),
            "mediaan_min": round(median(mins), 1),
            "mediaan_min_per_eenheid": round(median(per_eenheid), 2) if per_eenheid else "",
        })
    m_rows.sort(key=lambda r: (r["programma"], r["artnr"], r["maand"]))
    mpath = os.path.join(out, "productietijd_per_artikel_maand.csv")
    with open(mpath, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(m_rows[0]), delimiter=";")
        w.writeheader()
        w.writerows(m_rows)
    print(f"\n{mpath}: {len(m_rows)} rijen. PRODUCTIE per maand (aantal bon/groepen | mediaan min per eenheid), top-3 artikelen:")
    maanden = sorted({r["maand"] for r in m_rows if r["programma"] == "PRODUCTIE"})
    print(f"{'maand':8}" + "".join(f"{a[:22]:>26}" for a in top[:3]))
    for m in maanden:
        cells = []
        for a in top[:3]:
            r = next((x for x in m_rows if x["programma"] == "PRODUCTIE" and x["artnr"] == a and x["maand"] == m), None)
            cells.append(f"{r['bon_groepen']:>5} | {str(r['mediaan_min_per_eenheid']):>8}" if r else "")
        print(f"{m:8}" + "".join(f"{c:>26}" for c in cells))

    per_user = defaultdict(float)
    for r in rows:
        if r["programma"] == "PRODUCTIE":
            per_user[r["id"]] += r["netto_minuten"]
    print("\nPRODUCTIE netto uren per operator:")
    for u, m in sorted(per_user.items(), key=lambda x: -x[1]):
        print(f"  {u:12} {m/60:8.1f}")


if __name__ == "__main__":
    main()
