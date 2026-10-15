"""MCP server exposing the Luna OpenEdge backend's read-only REST endpoints.

Wraps the PASOE WebHandlers under {base}/<path> (default base
http://localhost:8080/web, override with the LUNA_API_BASE_URL env var) as
MCP tools so a language model can query live Luna data via the existing
API surface - no direct database access.

Register in Devin via .devin/mcp_config.local.json:

    {
      "mcpServers": {
        "luna-data": {
          "command": "python3",
          "args": ["luna_backend/mcp/luna_data_server.py"]
        }
      }
    }
"""

import os
from urllib.parse import quote, urlencode

import httpx
from fastmcp import FastMCP

BASE_URL = os.environ.get("LUNA_API_BASE_URL", "http://localhost:8080/web").rstrip("/")

mcp = FastMCP("luna-data")


def _get(path: str, params: dict | None = None):
    """GET {BASE_URL}{path} with an optional query string.

    Query values are percent-encoded with quote_via=quote (spaces -> "%20",
    never "+") because OpenEdge's query-value decoder does not treat "+" as
    a space - a "+" would silently break naam/omschrijving matches.
    """
    qs = ""
    if params:
        qs = "?" + urlencode(
            {k: v for k, v in params.items() if v is not None},
            quote_via=quote,
        )
    url = f"{BASE_URL}{path}{qs}"
    try:
        resp = httpx.get(url, headers={"Accept": "application/json"}, timeout=90.0)
    except httpx.HTTPError as e:
        return {"error": f"Kan de Luna backend niet bereiken op {BASE_URL}: {e}"}
    if resp.status_code == 404:
        return {"error": "Niet gevonden (404)", "status": 404}
    if not resp.is_success:
        try:
            body = resp.json()
            msg = body.get("error", {}).get("message") or str(body)
        except Exception:
            msg = resp.text[:500]
        return {"error": msg, "status": resp.status_code}
    return resp.json()


def _post(path: str, payload: dict):
    url = f"{BASE_URL}{path}"
    try:
        resp = httpx.post(url, json=payload, timeout=90.0)
    except httpx.HTTPError as e:
        return {"error": f"Kan de Luna backend niet bereiken op {BASE_URL}: {e}"}
    if not resp.is_success:
        try:
            body = resp.json()
            msg = body.get("error", {}).get("message") or str(body)
        except Exception:
            msg = resp.text[:500]
        return {"error": msg, "status": resp.status_code}
    return resp.json()


@mcp.tool
def backend_status() -> dict:
    """Controleer of de Luna backend (PASOE) bereikbaar is via GET /test."""
    try:
        resp = httpx.get(f"{BASE_URL}/test", timeout=10.0)
        return {"reachable": True, "baseUrl": BASE_URL, "status": resp.status_code,
                "body": resp.text[:500]}
    except httpx.HTTPError as e:
        return {"reachable": False, "baseUrl": BASE_URL, "error": str(e)}


@mcp.tool
def get_klanten(
    naam: str | None = None,
    nomaled: bool = False,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van klanten (customers). `naam` filtert op deelwoorden in
    naam/naam1 (case-insensitive, elke spatie-gescheiden term moet matchen).
    `nomaled=True` beperkt tot Nomaled-dealer klanten. Gepagineerd; gebruik
    `hasMore` om te zien of er meer pagina's zijn. GET /klant."""
    params = {"page": page, "pageSize": page_size, "naam": naam}
    if nomaled:
        params["nomaled"] = "true"
    return _get("/klant", params)


@mcp.tool
def get_klant(klnr: int) -> dict:
    """Eén klant op klantnummer (klnr): adres, contact, saldo, btw-nr,
    geblokkeerd, ... GET /klant/{klnr}."""
    return _get(f"/klant/{klnr}")


@mcp.tool
def get_klant_adressen(klnr: int) -> dict:
    """Leverings-/facturatieadressen van een klant. GET /klant/{klnr}/adres."""
    return _get(f"/klant/{klnr}/adres")


@mcp.tool
def get_klant_contacten(klnr: int) -> dict:
    """Contactpersonen van een klant. GET /klant/{klnr}/contact."""
    return _get(f"/klant/{klnr}/contact")


@mcp.tool
def get_klant_kortingen(klnr: int) -> dict:
    """Kortingen van een klant. GET /klant/{klnr}/korting."""
    return _get(f"/klant/{klnr}/korting")


@mcp.tool
def get_offertes(
    klnr: int | None = None,
    offnr: str | None = None,
    naam: str | None = None,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van offertes (quotes), nieuwste offnr/versie eerst - elke rij is
    één revisie. Filters: `klnr` (exact klantnummer), `offnr` (prefix op
    offertenummer), `naam` (deelstring klantnaam). GET /offerte."""
    return _get("/offerte", {"klnr": klnr, "offnr": offnr, "naam": naam,
                             "page": page, "pageSize": page_size})


@mcp.tool
def get_offerte(offnr: int, versie: int) -> dict:
    """Eén offerte-revisie op offnr+versie (kopgegevens incl. bedrag, btw,
    status, stempel "O"=open/"D"=omgezet). GET /offerte/{offnr}/{versie}."""
    return _get(f"/offerte/{offnr}/{versie}")


@mcp.tool
def get_offerte_lijnen(offnr: int, versie: int) -> dict:
    """Alle offerte-lijnen (artikelen, aantallen, prijzen) van één
    offerte-revisie. GET /offerte/{offnr}/{versie}/lijn."""
    return _get(f"/offerte/{offnr}/{versie}/lijn")


@mcp.tool
def get_bonnen(
    klnr: int | None = None,
    type: str | None = None,
    bonnr: str | None = None,
    naam: str | None = None,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van bonnen (klantorders, "Orders & Productie"). Filters:
    `klnr` (exact), `type` (exact, bv. "ORDERBEVESTIGING"), `bonnr` (prefix),
    `naam` (deelstring klantnaam). GET /bon."""
    return _get("/bon", {"klnr": klnr, "type": type, "bonnr": bonnr,
                         "naam": naam, "page": page, "pageSize": page_size})


@mcp.tool
def get_bon(bonnr: int) -> dict:
    """Eén bon (klantorder) op bonnr: klant, bedrag, geparkeerd, verzonden,
    leverdatum, ... GET /bon/{bonnr}."""
    return _get(f"/bon/{bonnr}")


@mcp.tool
def get_bon_lijnen(bonnr: int) -> dict:
    """Alle orderlijnen (bonlijn) van één bon: artikelen, aantallen,
    prijzen, te leveren. GET /bon/{bonnr}/lijn."""
    return _get(f"/bon/{bonnr}/lijn")


@mcp.tool
def get_facturen(
    klnr: int | None = None,
    naam: str | None = None,
    datum: str | None = None,
    projectnr: int | None = None,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van facturen (invoices). Filters: `klnr` (exact), `naam`
    (deelstring klantnaam), `datum` (exact, ISO "YYYY-MM-DD"), `projectnr`
    (exact). GET /factuur."""
    return _get("/factuur", {"klnr": klnr, "naam": naam, "datum": datum,
                             "projectnr": projectnr, "page": page,
                             "pageSize": page_size})


@mcp.tool
def get_factuur(facnr: int) -> dict:
    """Eén factuur op facnr: totalen incl/excl btw, betaald-status,
    betaaldatum, voorschot, ... GET /factuur/{facnr}."""
    return _get(f"/factuur/{facnr}")


@mcp.tool
def get_artikelen(
    artnr: str | None = None,
    omschrijving: str | None = None,
    lage_voorraad: bool = False,
    geblokkeerd: bool | None = None,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van artikelen (producten/voorraad). Filters: `artnr` (prefix),
    `omschrijving` (deelstring), `lage_voorraad=True` (zelfde set als het
    dashboard), `geblokkeerd` True/False. GET /artikel.

    Let op: omschrijving-filter scant veel rijen; gebruik bij voorkeur
    artnr."""
    params = {"page": page, "pageSize": page_size, "artnr": artnr,
              "omschrijving": omschrijving}
    if lage_voorraad:
        params["lageVoorraad"] = "true"
    if geblokkeerd is not None:
        params["geblokkeerd"] = str(geblokkeerd).lower()
    return _get("/artikel", params)


@mcp.tool
def get_bestelorders(
    levnr: int | None = None,
    ordnr: str | None = None,
    naam: str | None = None,
    sort_field: str | None = None,
    sort_dir: str | None = None,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van bestelorders (inkooporders naar leveranciers). Filters:
    `levnr` (exact), `ordnr` (prefix), `naam` (deelstring leveranciersnaam).
    Sorteerbaar via `sort_field` ("ordnr"|"datum"|"naam"|"stempel",
    default "ordnr") en `sort_dir` ("asc"|"desc", default "desc").
    GET /bestelorder."""
    return _get("/bestelorder", {"levnr": levnr, "ordnr": ordnr, "naam": naam,
                                 "sortField": sort_field, "sortDir": sort_dir,
                                 "page": page, "pageSize": page_size})


@mcp.tool
def get_bestelorder(ordnr: int) -> dict:
    """Eén bestelorder op ordnr. GET /bestelorder/{ordnr}."""
    return _get(f"/bestelorder/{ordnr}")


@mcp.tool
def get_bestelorder_lijnen(ordnr: int) -> dict:
    """Alle ordlijn-rijen van één bestelorder. GET /bestelorder/{ordnr}/lijn."""
    return _get(f"/bestelorder/{ordnr}/lijn")


@mcp.tool
def get_leveranciers(
    naam: str | None = None,
    page: int = 1,
    page_size: int = 25,
) -> dict:
    """Lijst van leveranciers (suppliers). `naam` filtert op deelwoorden
    (case-insensitive). GET /leverancier."""
    return _get("/leverancier", {"naam": naam, "page": page,
                                 "pageSize": page_size})


@mcp.tool
def get_leverancier(levnr: int) -> dict:
    """Eén leverancier op levnr. GET /leverancier/{levnr}."""
    return _get(f"/leverancier/{levnr}")


@mcp.tool
def get_dashboard() -> dict:
    """Dashboard-samenvatting: statistiekkaarten (open offertes, orders in
    productie, omzet deze maand, lage voorraad), recente activiteit en
    productie deze week. GET /dashboard.

    Let op: eerste aanroep kan ~45s duren (lage-voorraad-statistiek scant
    ~1.8M artikel-rijen)."""
    return _get("/dashboard")


@mcp.tool
def get_lakproductie() -> dict:
    """Lakproductie-overzicht: open klantorderregels die nog gelakt/
    geanodiseerd moeten worden en nog niet besteld zijn bij de externe
    verwerker. GET /lakproduktie."""
    return _get("/lakproduktie")


@mcp.tool
def get_verkoop_fur() -> dict:
    """Rolling-12-maanden overzicht van dealers met NOMALED.FUR*-orderregels,
    gesorteerd op totaal aantal stuks. GET /rapportage/verkoop-fur."""
    return _get("/rapportage/verkoop-fur")


@mcp.tool
def ai_search(prompt: str) -> dict:
    """Natural-language zoekopdracht in het Nederlands over bon/offerte/
    klant/artikel/factuur/bestelorder-data (bv. "toon open offertes van
    CONE LIGHTING"). De backend vertaalt de prompt via Gemini naar een
    gefilterde query. POST /ai-search.

    Let op: vereist GEMINI_API_KEY op de PASOE-agent; anders een 502-
    fout ("De AI-zoekfunctie is momenteel niet beschikbaar")."""
    return _post("/ai-search", {"prompt": prompt})


if __name__ == "__main__":
    mcp.run()
