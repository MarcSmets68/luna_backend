/*------------------------------------------------------------------------
    File        : DashboardBE.cls
    Purpose     : Business Entity that aggregates data from offerte, bon,
                  factuur and artikel into the summary shown on the
                  dashboard: stat cards, a recent-activity feed and the
                  open orders due this week ("productie deze week").
                  There is no dedicated activity-log or production-stage
                  table in the schema (confirmed 2026-08-12: bonlijn_productie
                  only tracks material reservation per orderlijn, not a
                  workflow stage) - both features are derived from existing
                  offerte/bon/factuur data instead.
    Business rules (confirmed with Marc, 2026-08-12):
                  - "Open offertes": latest versie per offnr (offerte rows
                    are one per offnr+versie - see Luna.BusinessLogic.
                    OfferteBE), where NOT passief AND NOT verkocht AND NOT
                    verloren, AND datum is within the last
                    cOpenOfferteWindowDays days (see constant below).
                    Confirmed by inspecting production data 2026-08-12:
                    passief/verkocht/verloren are not consistently
                    maintained on old rows - 27457 of 28405 "not passief/
                    verkocht/verloren" rows dated before 2025-01-01 (oldest:
                    2000-02-29), so that check alone massively overcounts.
                    The date window keeps the stat meaningful as "open
                    offertes from recent activity" until/unless a more
                    reliable status field is identified. Bedrag = sum of
                    b-bedrag over those rows.
                  - "Orders in productie": bon rows where geparkeerd = FALSE
                    AND verzonden = FALSE - a bon-level "open order" proxy
                    (there is no production-stage field on bon itself; see
                    the note above). This is NOT the same rule as
                    Luna.BusinessLogic.LakproductieBE, which works at the
                    bonlijn level (te-leveren NE 0, excluding lines already
                    fully Gereserveerd/Besteld) - the two happen to serve a
                    similar "still open" purpose but are separate,
                    independently-confirmed business rules. "Leveren deze
                    week" is the subset of those with lev-dat in the current
                    Monday-Sunday week.
                  - "Omzet deze maand": sum of factuur.totaal (type EQ TRUE,
                    i.e. invoices only - credit notes excluded, same rule as
                    Luna.BusinessLogic.FactuurBE) with datum from the 1st of
                    the current month through today. Compared against the
                    same day-range in the previous month for the trend
                    percentage.
                  - "Lage voorraad": artikel rows where stock = TRUE, NOT
                    blokkeerd, minv > 0 (rows with no minimum configured are
                    not "low") and aantal <= minv. No index exists on
                    stock/aantal/minv (artikel has ~1.8M rows) so this is a
                    full table scan - accepted as a known performance
                    tradeoff (confirmed with Marc 2026-08-12) until a
                    dedicated index or precomputed figure exists.
                  - "Recente activiteit": the most recent offerte/bon/
                    factuur rows (by date) across all three tables, newest
                    first. There is no activity-log table, so this reflects
                    row creation/status dates, not literal user actions.
                  - "Omzet 6 maanden trend": 6 monthly data points - the 5
                    full prior calendar months plus the current month from
                    the 1st through today - using the same revenue rule as
                    "Omzet deze maand" above (factuur.type EQ TRUE, sum
                    factuur.totaal). The last (current-month) point is
                    flagged isPartial since it doesn't cover a full month.
                    Months with no matching invoices return total 0.00, not
                    null.
                  - "Top 5 klanten" / "Top 5 artikelen" (netto omzet deze
                    maand, excl. BTW): period = 1st of current month through
                    TODAY, compared against the same day-range in the
                    previous month (capped, see GetVergelijkPeriodes). Both
                    factuur.type values count (credit notes net against the
                    customer/article), swFactuur = TRUE (voorschot) is
                    excluded. Klanten: SUM(factuur.n-bedrag) per klnr.
                    Artikelen: per faclijn (subtotaal/kolomtitel/infolijn and
                    blank artnr excluded) aantal * vprijs * (1 - korting/100),
                    grouped on exact artnr; faclijn.bedrag is NOT used (it is
                    0 for groepnr NE 0 lines). korting precedence mirrors
                    OmzetanalyseDealersBE: own line korting NE 0, else (in a
                    group) korting of the subtotaal line of the same
                    facnr+groepnr (found-flag: also when 0), else
                    factuur.korting. Only entities with net omzet > 0 are
                    ranked (max 5; ties: omzet, then aantalFacturen/aantal
                    DESC, then klnr/artnr ASC). aandeelPct denominator = net
                    total over ALL klanten/artikelen of the period.
                    vsVorigeMaandPct = ? (null) when omzetVorigeMaand <= 0.
                    CREDIT-NOTE SIGN (verified live on LunaNew, read-only,
                    NO-LOCK, 2026-10): all 106 factuur rows with type = FALSE
                    since 2022 (TODAY - 1500 days) have n-bedrag > 0 (0
                    negative), faclijn.vprijs > 0 on 127 lines (0 negative),
                    faclijn.aantal > 0 on 128 lines and < 0 on 9 lines. The 9
                    negative-aantal lines are legitimate correction pairs
                    inside one credit note (e.g. +1 x 4173.60 @50% and
                    -1 x 750 -> n-bedrag 1336.80 = sum of the lines), not a
                    sign convention. Conclusion: credit notes are stored
                    POSITIVE, so type = FALSE multiplies both omzet and
                    aantal by -1 (line's own sign preserved, so corrections
                    net out correctly). Types verified: klant.klnr,
                    factuur.klnr INTEGER; faclijn.aantal DECIMAL.
                  - "Voorraadbewegingen" (artlog, month-to-date): window = 1st
                    of current month through TODAY on artlog.datum (index
                    artlog-x2, leading component datum - verified live
                    2026-10). aantalIn / aantalUit = number of artlog BOOKINGS
                    (not quantity sums) with aantal > 0 / < 0; aantal = 0
                    rows ignored. Both counters INCLUDE beweging = "S"
                    (stocktelling) rows; aantalArtikelen = unique artnr with
                    at least one non-zero booking (incl. S-only articles).
                    topDalers (max 5): per artnr SUM(aantal) EXCLUDING
                    beweging = "S", only netto < 0 ranked (ties: netto asc,
                    aantalBewegingen desc, artnr asc). aantalBewegingen counts
                    only the non-S rows behind netto - deliberately NOT the
                    same number as the IN/UIT counters. Post-filter, after
                    ranking, one artikel lookup per negative candidate:
                    articles without an artikel row, with stock = FALSE or
                    blokkeren = TRUE are skipped and the walk continues until
                    5 winners. SIGN RULE (verified live): artlog.aantal is
                    always the exact signed stock delta (stock(n) = stock(n-1)
                    + aantal(n)), so direction is derived purely from the sign
                    of aantal - no beweging-specific sign logic. Failures are
                    isolated via VoorraadBewegingenFailed.
    Syntax      : Called from Luna.Web.DashboardHandler (GET /web/dashboard)
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK reads only.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.DashboardBE:

    /* See "Open offertes" business rule in the class header. */
    DEFINE PRIVATE VARIABLE iOpenOfferteWindowDays AS INTEGER NO-UNDO INITIAL 90.

    /* Single-row result - the WebHandler unwraps items[1] into a plain
       JSON object, same convention as the single-get methods on
       Luna.BusinessLogic.OfferteBE/FactuurBE. */
    DEFINE TEMP-TABLE ttStatCards NO-UNDO SERIALIZE-NAME "items":u
        FIELD openOffertesCount             AS INTEGER SERIALIZE-NAME "openOffertesCount":u
        FIELD openOffertesBedragPotentieel  AS DECIMAL SERIALIZE-NAME "openOffertesBedragPotentieel":u
        FIELD ordersInProductieCount        AS INTEGER SERIALIZE-NAME "ordersInProductieCount":u
        FIELD ordersInProductieLevDezeWeek  AS INTEGER SERIALIZE-NAME "ordersInProductieLeverenDezeWeek":u
        FIELD omzetDezeMaand                AS DECIMAL SERIALIZE-NAME "omzetDezeMaand":u
        FIELD omzetVsVorigeMaandPct         AS DECIMAL SERIALIZE-NAME "omzetVsVorigeMaandPct":u
        FIELD lageVoorraadCount             AS INTEGER SERIALIZE-NAME "lageVoorraadCount":u.

    DEFINE TEMP-TABLE ttActivity NO-UNDO SERIALIZE-NAME "recentActivity":u
        FIELD activityText AS CHARACTER SERIALIZE-NAME "text":u
        FIELD datum        AS DATE      SERIALIZE-NAME "datum":u
        FIELD activityType AS CHARACTER SERIALIZE-NAME "type":u
        FIELD sortSeq      AS INTEGER   SERIALIZE-HIDDEN.

    DEFINE TEMP-TABLE ttProduction NO-UNDO SERIALIZE-NAME "productionThisWeek":u
        FIELD bonnr      AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD klant      AS CHARACTER SERIALIZE-NAME "klant":u
        FIELD leverdatum AS DATE      SERIALIZE-NAME "leverdatum":u
        FIELD bedrag     AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD geparkeerd AS LOGICAL   SERIALIZE-NAME "geparkeerd":u.

    /* NOTE: the field holding the display label is named labelText, not
       label - LABEL is an ABL reserved word (used by the FIELD phrase
       itself) and cannot be used as a temp-table field name; confirmed by
       isolating a minimal COMPILE of "FIELD label AS CHARACTER ..." which
       fails with "Could not understand line N. (198)" even fully
       buffer-qualified. SERIALIZE-NAME keeps the JSON contract as
       "label" per the approved design - this is a purely internal ABL
       identifier rename forced by the reserved word, not an API change. */
    DEFINE TEMP-TABLE ttOmzetTrend NO-UNDO SERIALIZE-NAME "omzetTrend":u
        FIELD maand     AS INTEGER   SERIALIZE-NAME "month":u
        FIELD jaar      AS INTEGER   SERIALIZE-NAME "year":u
        FIELD labelText AS CHARACTER SERIALIZE-NAME "label":u
        FIELD totaal    AS DECIMAL   SERIALIZE-NAME "total":u
        FIELD isPartial AS LOGICAL   SERIALIZE-NAME "isPartial":u.

    /* Top 5 widgets - public, serialized. omschrijving/rang used instead of
       omschr/rank (reserved-word/abbreviation risk). */
    DEFINE TEMP-TABLE ttTopKlanten NO-UNDO SERIALIZE-NAME "topKlanten":u
        FIELD rang             AS INTEGER   SERIALIZE-NAME "rang":u
        FIELD klnr             AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam             AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD omzet            AS DECIMAL   SERIALIZE-NAME "omzet":u
        FIELD aantalFacturen   AS INTEGER   SERIALIZE-NAME "aantalFacturen":u
        FIELD aandeelPct       AS DECIMAL   SERIALIZE-NAME "aandeelPct":u
        FIELD omzetVorigeMaand AS DECIMAL   SERIALIZE-NAME "omzetVorigeMaand":u
        FIELD vsVorigeMaandPct AS DECIMAL   SERIALIZE-NAME "vsVorigeMaandPct":u.

    DEFINE TEMP-TABLE ttTopArtikelen NO-UNDO SERIALIZE-NAME "topArtikelen":u
        FIELD rang             AS INTEGER   SERIALIZE-NAME "rang":u
        FIELD artnr            AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving     AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD omzet            AS DECIMAL   SERIALIZE-NAME "omzet":u
        FIELD aantal           AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD aandeelPct       AS DECIMAL   SERIALIZE-NAME "aandeelPct":u
        FIELD omzetVorigeMaand AS DECIMAL   SERIALIZE-NAME "omzetVorigeMaand":u
        FIELD vsVorigeMaandPct AS DECIMAL   SERIALIZE-NAME "vsVorigeMaandPct":u.

    /* Private working tables - never serialized. */
    DEFINE PRIVATE TEMP-TABLE ttKlantAgg NO-UNDO
        FIELD klnr       AS INTEGER
        FIELD naamSnap   AS CHARACTER
        FIELD omzetNu    AS DECIMAL INITIAL 0
        FIELD omzetVorig AS DECIMAL INITIAL 0
        FIELD aantalFac  AS INTEGER INITIAL 0
        INDEX idxKlnr IS PRIMARY UNIQUE klnr.

    DEFINE PRIVATE TEMP-TABLE ttArtAgg NO-UNDO
        FIELD artnr      AS CHARACTER
        FIELD omschrSnap AS CHARACTER
        FIELD omzetNu    AS DECIMAL INITIAL 0
        FIELD aantalNu   AS DECIMAL INITIAL 0
        FIELD omzetVorig AS DECIMAL INITIAL 0
        INDEX idxArtnr IS PRIMARY UNIQUE artnr.

    /* korting of the subtotaal line per groepnr, for the current factuur only. */
    DEFINE PRIVATE TEMP-TABLE ttFacGrp NO-UNDO
        FIELD groepnr  AS INTEGER
        FIELD gKorting AS DECIMAL
        INDEX idxGroep IS PRIMARY UNIQUE groepnr.

    /* Voorraadbewegingen widget - public, serialized (summary is always exactly 1 row). */
    DEFINE TEMP-TABLE ttVoorraadSamenvatting NO-UNDO SERIALIZE-NAME "voorraadSamenvatting":u
        FIELD aantalIn        AS INTEGER SERIALIZE-NAME "aantalIn":u
        FIELD aantalUit       AS INTEGER SERIALIZE-NAME "aantalUit":u
        FIELD aantalArtikelen AS INTEGER SERIALIZE-NAME "aantalArtikelen":u.

    DEFINE TEMP-TABLE ttVoorraadDalers NO-UNDO SERIALIZE-NAME "voorraadDalers":u
        FIELD rang             AS INTEGER   SERIALIZE-NAME "rang":u
        FIELD artnr            AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving     AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD netto            AS DECIMAL   SERIALIZE-NAME "netto":u
        FIELD aantalBewegingen AS INTEGER   SERIALIZE-NAME "aantalBewegingen":u
        FIELD huidigeVoorraad  AS DECIMAL   SERIALIZE-NAME "huidigeVoorraad":u
        FIELD voorraadMin      AS DECIMAL   SERIALIZE-NAME "voorraadMin":u.

    /* Private working table - never serialized. */
    DEFINE PRIVATE TEMP-TABLE ttVoorraadAgg NO-UNDO
        FIELD artnr       AS CHARACTER
        FIELD omschrSnap  AS CHARACTER
        FIELD nettoRank   AS DECIMAL INITIAL 0
        FIELD aantalRank  AS INTEGER INITIAL 0
        INDEX idxArtnr IS PRIMARY UNIQUE artnr.

    DEFINE PUBLIC PROPERTY TopKlantenFailed   AS LOGICAL NO-UNDO INITIAL FALSE GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY VoorraadBewegingenFailed AS LOGICAL NO-UNDO INITIAL FALSE GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY TopArtikelenFailed AS LOGICAL NO-UNDO INITIAL FALSE GET. PRIVATE SET.

    /*------------------------------------------------------------------------------
        Purpose: Returns the Monday (output 1) and Sunday (output 2) of the
                 week containing pdDate.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID GetWeekBounds( INPUT pdDate AS DATE, OUTPUT pdMonday AS DATE, OUTPUT pdSunday AS DATE ):

        DEFINE VARIABLE iDaysSinceMonday AS INTEGER NO-UNDO.

        /* WEEKDAY() is 1 (Sunday) .. 7 (Saturday); this maps it to "days
           since Monday" (Monday -> 0 .. Sunday -> 6). */
        iDaysSinceMonday = (WEEKDAY(pdDate) + 5) MODULO 7.

        pdMonday = pdDate - iDaysSinceMonday.
        pdSunday = pdMonday + 6.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns the first (output 1) and last (output 2) date of
                 the calendar month identified by piMonth/piYear.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID GetMonthBounds( INPUT piMonth AS INTEGER, INPUT piYear AS INTEGER, OUTPUT pdStart AS DATE, OUTPUT pdEnd AS DATE ):

        DEFINE VARIABLE iNextMonth AS INTEGER NO-UNDO.
        DEFINE VARIABLE iNextYear  AS INTEGER NO-UNDO.

        pdStart = DATE(piMonth, 1, piYear).

        iNextMonth = piMonth + 1.
        iNextYear  = piYear.
        IF iNextMonth GT 12 THEN
            ASSIGN
                iNextMonth = 1
                iNextYear  = iNextYear + 1.

        pdEnd = DATE(iNextMonth, 1, iNextYear) - 1.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Aggregates the four dashboard stat cards from offerte, bon,
                 factuur and artikel.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetStatCards():

        DEFINE VARIABLE iLastOffnr        AS INTEGER   NO-UNDO INITIAL ?.
        DEFINE VARIABLE dWeekStart        AS DATE      NO-UNDO.
        DEFINE VARIABLE dWeekEnd          AS DATE      NO-UNDO.
        DEFINE VARIABLE dMaandStart       AS DATE      NO-UNDO.
        DEFINE VARIABLE dVorigeMaandStart AS DATE      NO-UNDO.
        DEFINE VARIABLE dVorigeMaandEind  AS DATE      NO-UNDO.
        DEFINE VARIABLE iPrevMonth        AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iPrevYear         AS INTEGER   NO-UNDO.
        DEFINE VARIABLE dOmzetDezeMaand   AS DECIMAL   NO-UNDO INITIAL 0.
        DEFINE VARIABLE dOmzetVorigeMaand AS DECIMAL   NO-UNDO INITIAL 0.

        EMPTY TEMP-TABLE ttStatCards.
        CREATE ttStatCards.

        /* --- Open offertes: latest versie per offnr, not passief/verkocht/
               verloren, AND datum within the last iOpenOfferteWindowDays
               days - see the class header for why the date window is
               needed on top of the status flags. offerte-x1 (offnr,
               versie) is scanned in descending order so the first row seen
               per offnr is its latest versie. */
        FOR EACH offerte NO-LOCK
            BY offerte.offnr DESCENDING BY offerte.versie DESCENDING:

            IF offerte.offnr EQ iLastOffnr THEN NEXT.
            iLastOffnr = offerte.offnr.

            IF NOT offerte.passief AND NOT offerte.verkocht AND NOT offerte.verloren
                AND offerte.datum NE ? AND offerte.datum GE (TODAY - iOpenOfferteWindowDays) THEN
                ASSIGN
                    ttStatCards.openOffertesCount            = ttStatCards.openOffertesCount + 1
                    ttStatCards.openOffertesBedragPotentieel = ttStatCards.openOffertesBedragPotentieel + offerte.b-bedrag
                    .
        END.

        /* --- Orders in productie: open bon (not parked, not shipped). */
        GetWeekBounds(TODAY, OUTPUT dWeekStart, OUTPUT dWeekEnd).

        FOR EACH bon NO-LOCK USE-INDEX bon-x5
            WHERE bon.geparkeerd EQ FALSE
              AND bon.verzonden  EQ FALSE:

            ttStatCards.ordersInProductieCount = ttStatCards.ordersInProductieCount + 1.

            IF bon.lev-dat GE dWeekStart AND bon.lev-dat LE dWeekEnd THEN
                ttStatCards.ordersInProductieLevDezeWeek = ttStatCards.ordersInProductieLevDezeWeek + 1.
        END.

        /* --- Omzet deze maand vs. zelfde periode vorige maand. Invoices
               only (factuur.type EQ TRUE) - same rule as
               Luna.BusinessLogic.FactuurBE. factuur-x4 (datum) makes both
               ranges an index range scan. */
        dMaandStart = DATE(MONTH(TODAY), 1, YEAR(TODAY)).

        ASSIGN
            iPrevMonth = MONTH(TODAY) - 1
            iPrevYear  = YEAR(TODAY).
        IF iPrevMonth EQ 0 THEN
            ASSIGN iPrevMonth = 12 iPrevYear = iPrevYear - 1.

        dVorigeMaandStart = DATE(iPrevMonth, 1, iPrevYear).
        /* Cap the comparison period at the last day of the previous month,
           for months where today's day-of-month doesn't exist last month
           (e.g. comparing through Feb 30 is impossible). */
        dVorigeMaandEind = MINIMUM(dVorigeMaandStart + (DAY(TODAY) - 1), dMaandStart - 1).

        FOR EACH factuur NO-LOCK USE-INDEX factuur-x4
            WHERE factuur.datum GE dMaandStart
              AND factuur.datum LE TODAY
              AND factuur.type  EQ TRUE:
            dOmzetDezeMaand = dOmzetDezeMaand + factuur.totaal.
        END.

        FOR EACH factuur NO-LOCK USE-INDEX factuur-x4
            WHERE factuur.datum GE dVorigeMaandStart
              AND factuur.datum LE dVorigeMaandEind
              AND factuur.type  EQ TRUE:
            dOmzetVorigeMaand = dOmzetVorigeMaand + factuur.totaal.
        END.

        ASSIGN
            ttStatCards.omzetDezeMaand = dOmzetDezeMaand
            ttStatCards.omzetVsVorigeMaandPct = IF dOmzetVorigeMaand NE 0
                THEN ROUND((dOmzetDezeMaand - dOmzetVorigeMaand) / dOmzetVorigeMaand * 100, 1)
                ELSE ?
            .

        /* --- Lage voorraad: full table scan, ~1.8M rows - accepted
               performance tradeoff, see class header. */
        FOR EACH artikel NO-LOCK
            WHERE artikel.stock     EQ TRUE
              AND artikel.blokkeren EQ FALSE
              AND artikel.minv      GT 0
              AND artikel.aantal    LE artikel.minv:
            ttStatCards.lageVoorraadCount = ttStatCards.lageVoorraadCount + 1.
        END.

        RETURN TEMP-TABLE ttStatCards:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Adds up to piLimit candidate rows from one table to
                 ttActivity, tagged with pcType and a monotonically
                 decreasing sortSeq (used to break ties when two rows share
                 the same date - later query = smaller seq = sorts after
                 earlier queries once combined and re-sorted by the caller).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID AddOfferteActivity( INPUT piLimit AS INTEGER ):

        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        FOR EACH offerte NO-LOCK BY offerte.datum DESCENDING BY offerte.offnr DESCENDING:

            IF iTaken GE piLimit THEN LEAVE.

            CREATE ttActivity.
            ASSIGN
                ttActivity.datum       = offerte.datum
                ttActivity.activityType = "offerte":u
                ttActivity.sortSeq     = iTaken
                ttActivity.activityText = IF offerte.verkocht THEN
                                          SUBSTITUTE("Offerte &1 verkocht aan &2":u, offerte.offnr, offerte.naam)
                                      ELSE IF offerte.verloren THEN
                                          SUBSTITUTE("Offerte &1 verloren (&2)":u, offerte.offnr, offerte.naam)
                                      ELSE
                                          SUBSTITUTE("Nieuwe offerte &1 voor &2":u, offerte.offnr, offerte.naam)
                .
            iTaken = iTaken + 1.
        END.

    END METHOD.

    METHOD PRIVATE VOID AddBonActivity( INPUT piLimit AS INTEGER ):

        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        FOR EACH bon NO-LOCK BY bon.datum DESCENDING BY bon.bonnr DESCENDING:

            IF iTaken GE piLimit THEN LEAVE.

            CREATE ttActivity.
            ASSIGN
                ttActivity.datum       = bon.datum
                ttActivity.activityType = "bon":u
                ttActivity.sortSeq     = iTaken
                ttActivity.activityText = IF bon.verzonden THEN
                                          SUBSTITUTE("Order &1 verzonden naar &2":u, bon.bonnr, bon.naam)
                                      ELSE
                                          SUBSTITUTE("Nieuwe order &1 voor &2":u, bon.bonnr, bon.naam)
                .
            iTaken = iTaken + 1.
        END.

    END METHOD.

    METHOD PRIVATE VOID AddFactuurActivity( INPUT piLimit AS INTEGER ):

        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        FOR EACH factuur NO-LOCK USE-INDEX factuur-x4
            WHERE factuur.type EQ TRUE
            BY factuur.datum DESCENDING BY factuur.facnr DESCENDING:

            IF iTaken GE piLimit THEN LEAVE.

            CREATE ttActivity.
            ASSIGN
                ttActivity.datum       = factuur.datum
                ttActivity.activityType = "factuur":u
                ttActivity.sortSeq     = iTaken
                ttActivity.activityText = IF factuur.swBetaald THEN
                                          SUBSTITUTE("Factuur &1 betaald door &2":u, factuur.facnr, factuur.naam)
                                      ELSE
                                          SUBSTITUTE("Factuur &1 aangemaakt voor &2":u, factuur.facnr, factuur.naam)
                .
            iTaken = iTaken + 1.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns the piLimit most recent items across offerte, bon
                 and factuur (newest datum first), derived from each row's
                 own date/status fields - there is no activity-log table in
                 the schema (see class header).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetRecentActivity( INPUT piLimit AS INTEGER ):

        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttActivity.

        IF piLimit LE 0 THEN piLimit = 5.

        /* Gather up to piLimit candidates from each source, then keep only
           the overall top piLimit by date - cheap because piLimit is small
           (each source query stops after piLimit rows via its own index). */
        AddOfferteActivity(piLimit).
        AddBonActivity(piLimit).
        AddFactuurActivity(piLimit).

        iTaken = 0.
        FOR EACH ttActivity BY ttActivity.datum DESCENDING BY ttActivity.sortSeq DESCENDING:
            iTaken = iTaken + 1.
            IF iTaken GT piLimit THEN DELETE ttActivity.
        END.

        RETURN TEMP-TABLE ttActivity:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns open orders (bon: not parked, not shipped) with a
                 leverdatum in the current Monday-Sunday week, earliest
                 leverdatum first.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetProductionThisWeek():

        DEFINE VARIABLE dWeekStart AS DATE NO-UNDO.
        DEFINE VARIABLE dWeekEnd   AS DATE NO-UNDO.

        EMPTY TEMP-TABLE ttProduction.

        GetWeekBounds(TODAY, OUTPUT dWeekStart, OUTPUT dWeekEnd).

        FOR EACH bon NO-LOCK USE-INDEX bon-x5
            WHERE bon.geparkeerd EQ FALSE
              AND bon.verzonden  EQ FALSE
              AND bon.lev-dat    GE dWeekStart
              AND bon.lev-dat    LE dWeekEnd
            BY bon.lev-dat:

            CREATE ttProduction.
            ASSIGN
                ttProduction.bonnr      = bon.bonnr
                ttProduction.klant      = bon.naam
                ttProduction.leverdatum = bon.lev-dat
                ttProduction.bedrag     = bon.b-bedrag
                ttProduction.geparkeerd = bon.geparkeerd
                .
        END.

        RETURN TEMP-TABLE ttProduction:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns 12 monthly invoice-total data points for the dashboard
                 omzet trend: the 11 full prior calendar months plus the current
                 month from the 1st through TODAY. Uses the same revenue rule as
                 GetStatCards (factuur.type EQ TRUE, sum factuur.totaal via
                 factuur-x4).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOmzetTrend():

        DEFINE VARIABLE iOffset      AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTargetMonth AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTargetYear  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE dStart       AS DATE      NO-UNDO.
        DEFINE VARIABLE dEnd         AS DATE      NO-UNDO.
        DEFINE VARIABLE dTotal       AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cLabel       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cMaandNamen  AS CHARACTER NO-UNDO INITIAL "jan,feb,mrt,apr,mei,jun,jul,aug,sep,okt,nov,dec":u.

        EMPTY TEMP-TABLE ttOmzetTrend.

        /* Build months 11..0 months ago (oldest -> newest). */
        DO iOffset = 11 TO 0 BY -1:

            iTargetMonth = MONTH(TODAY) - iOffset.
            iTargetYear  = YEAR(TODAY).

            IF iTargetMonth LE 0 THEN
                ASSIGN
                    iTargetMonth = iTargetMonth + 12
                    iTargetYear  = iTargetYear - 1.

            GetMonthBounds(iTargetMonth, iTargetYear, OUTPUT dStart, OUTPUT dEnd).

            /* Current month is capped at TODAY and flagged as partial. */
            IF iOffset EQ 0 THEN
                dEnd = TODAY.

            dTotal = 0.
            FOR EACH factuur NO-LOCK USE-INDEX factuur-x4
                WHERE factuur.datum GE dStart
                  AND factuur.datum LE dEnd
                  AND factuur.type  EQ TRUE:
                dTotal = dTotal + factuur.totaal.
            END.

            cLabel = ENTRY(iTargetMonth, cMaandNamen) + " " + STRING(iTargetYear).

            CREATE ttOmzetTrend.
            ASSIGN
                ttOmzetTrend.maand     = iTargetMonth
                ttOmzetTrend.jaar      = iTargetYear
                ttOmzetTrend.labelText = cLabel
                ttOmzetTrend.totaal    = dTotal
                ttOmzetTrend.isPartial = (iOffset EQ 0)
                .
        END.

        RETURN TEMP-TABLE ttOmzetTrend:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Current period (1st of month through TODAY) and the comparison
                 period (same day-range in the previous month, capped at that
                 month's last day). NOTE: deliberately duplicates the inline
                 logic in GetStatCards (not refactored to reuse this, to avoid
                 regression risk on the existing stat cards) - keep both in sync.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID GetVergelijkPeriodes( OUTPUT pdNuVan AS DATE, OUTPUT pdNuTot AS DATE,
                                              OUTPUT pdVorigVan AS DATE, OUTPUT pdVorigTot AS DATE ):

        DEFINE VARIABLE iPrevMonth AS INTEGER NO-UNDO.
        DEFINE VARIABLE iPrevYear  AS INTEGER NO-UNDO.

        ASSIGN
            pdNuVan    = DATE(MONTH(TODAY), 1, YEAR(TODAY))
            pdNuTot    = TODAY
            iPrevMonth = MONTH(TODAY) - 1
            iPrevYear  = YEAR(TODAY).

        IF iPrevMonth EQ 0 THEN
            ASSIGN iPrevMonth = 12 iPrevYear = iPrevYear - 1.

        pdVorigVan = DATE(iPrevMonth, 1, iPrevYear).
        pdVorigTot = MINIMUM(pdVorigVan + (DAY(TODAY) - 1), pdNuVan - 1).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Effective discount % for a faclijn: own korting, else (in a group)
                 the subtotaal line's korting for the same groepnr of the current
                 factuur (ttFacGrp, found-flag semantics - also when 0), else
                 factuur.korting. Mirrors OmzetanalyseDealersBE:LineKorting.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL LineKorting( BUFFER pbLijn FOR faclijn, INPUT pdFacKorting AS DECIMAL ):

        IF pbLijn.korting NE 0 THEN
            RETURN pbLijn.korting.

        IF pbLijn.groepnr NE 0 THEN
        DO:
            FIND ttFacGrp WHERE ttFacGrp.groepnr EQ pbLijn.groepnr NO-ERROR.
            IF AVAILABLE ttFacGrp THEN
                RETURN ttFacGrp.gKorting.
        END.

        RETURN pdFacKorting.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Top 5 klanten by net omzet (SUM factuur.n-bedrag, credit notes
                 negated, voorschot excluded) this month, with share and
                 comparison vs. the same period last month. Always returns the
                 (possibly empty) handle; failures are isolated via
                 TopKlantenFailed.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetTopKlanten():

        DEFINE VARIABLE dNuVan    AS DATE    NO-UNDO.
        DEFINE VARIABLE dNuTot    AS DATE    NO-UNDO.
        DEFINE VARIABLE dVorigVan AS DATE    NO-UNDO.
        DEFINE VARIABLE dVorigTot AS DATE    NO-UNDO.
        DEFINE VARIABLE dBedrag   AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dTotaal   AS DECIMAL NO-UNDO INITIAL 0.
        DEFINE VARIABLE iRang     AS INTEGER NO-UNDO.

        TopKlantenFailed = FALSE.
        EMPTY TEMP-TABLE ttTopKlanten.
        EMPTY TEMP-TABLE ttKlantAgg.

        DO ON ERROR UNDO, THROW:

            GetVergelijkPeriodes(OUTPUT dNuVan, OUTPUT dNuTot, OUTPUT dVorigVan, OUTPUT dVorigTot).

            FOR EACH factuur NO-LOCK USE-INDEX factuur-x4
                WHERE factuur.datum GE dVorigVan
                  AND factuur.datum LE dNuTot:

                IF factuur.swFactuur THEN NEXT.
                IF NOT ((factuur.datum GE dNuVan AND factuur.datum LE dNuTot)
                     OR (factuur.datum GE dVorigVan AND factuur.datum LE dVorigTot)) THEN NEXT.

                dBedrag = factuur.n-bedrag * (IF factuur.type THEN 1 ELSE -1).

                FIND ttKlantAgg WHERE ttKlantAgg.klnr EQ factuur.klnr NO-ERROR.
                IF NOT AVAILABLE ttKlantAgg THEN
                DO:
                    CREATE ttKlantAgg.
                    ASSIGN
                        ttKlantAgg.klnr      = factuur.klnr
                        ttKlantAgg.naamSnap  = factuur.naam.
                END.

                IF factuur.datum GE dNuVan THEN
                    ASSIGN
                        ttKlantAgg.omzetNu   = ttKlantAgg.omzetNu + dBedrag
                        ttKlantAgg.aantalFac = ttKlantAgg.aantalFac + 1
                        dTotaal              = dTotaal + dBedrag.
                ELSE
                    ttKlantAgg.omzetVorig = ttKlantAgg.omzetVorig + dBedrag.
            END.

            iRang = 0.
            FOR EACH ttKlantAgg WHERE ttKlantAgg.omzetNu GT 0
                BY ttKlantAgg.omzetNu DESCENDING BY ttKlantAgg.aantalFac DESCENDING BY ttKlantAgg.klnr:

                iRang = iRang + 1.
                IF iRang GT 5 THEN LEAVE.

                CREATE ttTopKlanten.
                ASSIGN
                    ttTopKlanten.rang             = iRang
                    ttTopKlanten.klnr             = ttKlantAgg.klnr
                    ttTopKlanten.omzet            = ROUND(ttKlantAgg.omzetNu, 2)
                    ttTopKlanten.aantalFacturen   = ttKlantAgg.aantalFac
                    ttTopKlanten.aandeelPct       = IF dTotaal GT 0 THEN ROUND(ttKlantAgg.omzetNu / dTotaal * 100, 1) ELSE 0
                    ttTopKlanten.omzetVorigeMaand = ROUND(ttKlantAgg.omzetVorig, 2)
                    ttTopKlanten.vsVorigeMaandPct = IF ttKlantAgg.omzetVorig GT 0
                        THEN ROUND((ttKlantAgg.omzetNu - ttKlantAgg.omzetVorig) / ttKlantAgg.omzetVorig * 100, 1)
                        ELSE ?
                    .

                /* Name resolution only for the top 5: klant.naam, else the
                   factuur.naam snapshot, else "Onbekend (klnr)". */
                FIND klant NO-LOCK WHERE klant.klnr EQ ttKlantAgg.klnr NO-ERROR.
                IF AVAILABLE klant AND TRIM(klant.naam) NE "" THEN
                    ttTopKlanten.naam = TRIM(klant.naam).
                ELSE IF TRIM(ttKlantAgg.naamSnap) NE "" THEN
                    ttTopKlanten.naam = TRIM(ttKlantAgg.naamSnap).
                ELSE
                    ttTopKlanten.naam = SUBSTITUTE("Onbekend (&1)":u, ttKlantAgg.klnr).
            END.

            CATCH eErr AS Progress.Lang.Error:
                EMPTY TEMP-TABLE ttTopKlanten.
                TopKlantenFailed = TRUE.
                LOG-MANAGER:WRITE-MESSAGE(SUBSTITUTE("DashboardBE:GetTopKlanten failed: &1":u, eErr:GetMessage(1)), "DashboardBE":u).
            END CATCH.
        END.

        RETURN TEMP-TABLE ttTopKlanten:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Top 5 artikelen by net omzet (recomputed per faclijn, see class
                 header) this month. Always returns the (possibly empty) handle;
                 failures are isolated via TopArtikelenFailed.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetTopArtikelen():

        DEFINE VARIABLE dNuVan    AS DATE      NO-UNDO.
        DEFINE VARIABLE dNuTot    AS DATE      NO-UNDO.
        DEFINE VARIABLE dVorigVan AS DATE      NO-UNDO.
        DEFINE VARIABLE dVorigTot AS DATE      NO-UNDO.
        DEFINE VARIABLE iTeken    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE lNu       AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cArtnr    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dKort     AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dBedrag   AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dTotaal   AS DECIMAL   NO-UNDO INITIAL 0.
        DEFINE VARIABLE iRang     AS INTEGER   NO-UNDO.

        DEFINE BUFFER bLijn FOR faclijn.

        TopArtikelenFailed = FALSE.
        EMPTY TEMP-TABLE ttTopArtikelen.
        EMPTY TEMP-TABLE ttArtAgg.
        EMPTY TEMP-TABLE ttFacGrp.

        DO ON ERROR UNDO, THROW:

            GetVergelijkPeriodes(OUTPUT dNuVan, OUTPUT dNuTot, OUTPUT dVorigVan, OUTPUT dVorigTot).

            FOR EACH factuur NO-LOCK USE-INDEX factuur-x4
                WHERE factuur.datum GE dVorigVan
                  AND factuur.datum LE dNuTot:

                IF factuur.swFactuur THEN NEXT.
                IF NOT ((factuur.datum GE dNuVan AND factuur.datum LE dNuTot)
                     OR (factuur.datum GE dVorigVan AND factuur.datum LE dVorigTot)) THEN NEXT.

                ASSIGN
                    iTeken = (IF factuur.type THEN 1 ELSE -1)
                    lNu    = (factuur.datum GE dNuVan).

                /* Pass 1: subtotaal lines -> korting per groepnr (first wins). */
                EMPTY TEMP-TABLE ttFacGrp.
                FOR EACH bLijn NO-LOCK USE-INDEX faclijn-x1
                    WHERE bLijn.facnr EQ factuur.facnr
                      AND bLijn.subtotaal EQ TRUE
                      AND bLijn.groepnr NE 0:
                    FIND ttFacGrp WHERE ttFacGrp.groepnr EQ bLijn.groepnr NO-ERROR.
                    IF NOT AVAILABLE ttFacGrp THEN
                    DO:
                        CREATE ttFacGrp.
                        ASSIGN
                            ttFacGrp.groepnr  = bLijn.groepnr
                            ttFacGrp.gKorting = bLijn.korting.
                    END.
                END.

                /* Pass 2: normal article lines. */
                FOR EACH faclijn NO-LOCK USE-INDEX faclijn-x1
                    WHERE faclijn.facnr EQ factuur.facnr
                      AND faclijn.subtotaal EQ FALSE
                      AND faclijn.kolomtitel EQ FALSE
                      AND faclijn.infolijn EQ FALSE:

                    cArtnr = TRIM(faclijn.artnr).
                    IF cArtnr EQ "" THEN NEXT.

                    dKort   = LineKorting(BUFFER faclijn, factuur.korting).
                    dBedrag = faclijn.aantal * faclijn.vprijs * (1 - dKort / 100) * iTeken.

                    FIND ttArtAgg WHERE ttArtAgg.artnr EQ cArtnr NO-ERROR.
                    IF NOT AVAILABLE ttArtAgg THEN
                    DO:
                        CREATE ttArtAgg.
                        ttArtAgg.artnr = cArtnr.
                    END.
                    IF ttArtAgg.omschrSnap EQ "" OR ttArtAgg.omschrSnap EQ ? THEN
                        ttArtAgg.omschrSnap = faclijn.omschr.

                    IF lNu THEN
                        ASSIGN
                            ttArtAgg.omzetNu  = ttArtAgg.omzetNu + dBedrag
                            ttArtAgg.aantalNu = ttArtAgg.aantalNu + faclijn.aantal * iTeken
                            dTotaal           = dTotaal + dBedrag.
                    ELSE
                        ttArtAgg.omzetVorig = ttArtAgg.omzetVorig + dBedrag.
                END.
            END.

            iRang = 0.
            FOR EACH ttArtAgg WHERE ttArtAgg.omzetNu GT 0
                BY ttArtAgg.omzetNu DESCENDING BY ttArtAgg.aantalNu DESCENDING BY ttArtAgg.artnr:

                iRang = iRang + 1.
                IF iRang GT 5 THEN LEAVE.

                CREATE ttTopArtikelen.
                ASSIGN
                    ttTopArtikelen.rang             = iRang
                    ttTopArtikelen.artnr            = ttArtAgg.artnr
                    ttTopArtikelen.omzet            = ROUND(ttArtAgg.omzetNu, 2)
                    ttTopArtikelen.aantal           = ttArtAgg.aantalNu
                    ttTopArtikelen.aandeelPct       = IF dTotaal GT 0 THEN ROUND(ttArtAgg.omzetNu / dTotaal * 100, 1) ELSE 0
                    ttTopArtikelen.omzetVorigeMaand = ROUND(ttArtAgg.omzetVorig, 2)
                    ttTopArtikelen.vsVorigeMaandPct = IF ttArtAgg.omzetVorig GT 0
                        THEN ROUND((ttArtAgg.omzetNu - ttArtAgg.omzetVorig) / ttArtAgg.omzetVorig * 100, 1)
                        ELSE ?
                    .

                /* Name resolution only for the top 5: artikel.omschr-n, else
                   the faclijn.omschr snapshot. */
                FIND artikel NO-LOCK WHERE artikel.artnr EQ ttArtAgg.artnr NO-ERROR.
                IF AVAILABLE artikel AND TRIM(artikel.omschr-n) NE "" THEN
                    ttTopArtikelen.omschrijving = TRIM(artikel.omschr-n).
                ELSE
                    ttTopArtikelen.omschrijving = TRIM(ttArtAgg.omschrSnap).
            END.

            CATCH eErr AS Progress.Lang.Error:
                EMPTY TEMP-TABLE ttTopArtikelen.
                TopArtikelenFailed = TRUE.
                LOG-MANAGER:WRITE-MESSAGE(SUBSTITUTE("DashboardBE:GetTopArtikelen failed: &1":u, eErr:GetMessage(1)), "DashboardBE":u).
            END CATCH.
        END.

        RETURN TEMP-TABLE ttTopArtikelen:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Voorraadbewegingen widget (see class header). Returns the handle
                 of ttVoorraadDalers; phSamenvatting receives the handle of the
                 always-one-row ttVoorraadSamenvatting. Failures are isolated via
                 VoorraadBewegingenFailed (zero summary + empty list).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetVoorraadBewegingen( OUTPUT phSamenvatting AS HANDLE ):

        DEFINE VARIABLE dNuVan    AS DATE      NO-UNDO.
        DEFINE VARIABLE dNuTot    AS DATE      NO-UNDO.
        DEFINE VARIABLE dVorigVan AS DATE      NO-UNDO.
        DEFINE VARIABLE dVorigTot AS DATE      NO-UNDO.
        DEFINE VARIABLE iRang     AS INTEGER   NO-UNDO.

        VoorraadBewegingenFailed = FALSE.
        EMPTY TEMP-TABLE ttVoorraadDalers.
        EMPTY TEMP-TABLE ttVoorraadSamenvatting.
        EMPTY TEMP-TABLE ttVoorraadAgg.

        CREATE ttVoorraadSamenvatting.
        ASSIGN
            ttVoorraadSamenvatting.aantalIn        = 0
            ttVoorraadSamenvatting.aantalUit       = 0
            ttVoorraadSamenvatting.aantalArtikelen = 0.

        DO ON ERROR UNDO, THROW:

            /* Only dNuVan/dNuTot are used; no previous-month comparison in v1. */
            GetVergelijkPeriodes(OUTPUT dNuVan, OUTPUT dNuTot, OUTPUT dVorigVan, OUTPUT dVorigTot).

            /* Pass 1: single scan over the month-to-date window (artlog-x2 = datum). */
            FOR EACH artlog NO-LOCK USE-INDEX artlog-x2
                WHERE artlog.datum GE dNuVan
                  AND artlog.datum LE dNuTot:

                IF artlog.aantal EQ 0 THEN NEXT.

                IF artlog.aantal GT 0 THEN
                    ttVoorraadSamenvatting.aantalIn = ttVoorraadSamenvatting.aantalIn + 1.
                ELSE
                    ttVoorraadSamenvatting.aantalUit = ttVoorraadSamenvatting.aantalUit + 1.

                FIND ttVoorraadAgg WHERE ttVoorraadAgg.artnr EQ artlog.artnr NO-ERROR.
                IF NOT AVAILABLE ttVoorraadAgg THEN
                DO:
                    CREATE ttVoorraadAgg.
                    ASSIGN
                        ttVoorraadAgg.artnr = artlog.artnr
                        ttVoorraadSamenvatting.aantalArtikelen = ttVoorraadSamenvatting.aantalArtikelen + 1.
                END.

                IF artlog.beweging NE "S":u THEN
                DO:
                    ASSIGN
                        ttVoorraadAgg.nettoRank  = ttVoorraadAgg.nettoRank + artlog.aantal
                        ttVoorraadAgg.aantalRank = ttVoorraadAgg.aantalRank + 1.
                    IF ttVoorraadAgg.omschrSnap EQ "" OR ttVoorraadAgg.omschrSnap EQ ? THEN
                        ttVoorraadAgg.omschrSnap = artlog.omschr.
                END.
            END.

            /* Pass 2: bounded candidate walk - only net decliners, post-filtered
               on artikel (one indexed lookup per candidate). */
            iRang = 0.
            FOR EACH ttVoorraadAgg WHERE ttVoorraadAgg.nettoRank LT 0
                BY ttVoorraadAgg.nettoRank BY ttVoorraadAgg.aantalRank DESCENDING BY ttVoorraadAgg.artnr:

                FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ ttVoorraadAgg.artnr NO-ERROR.
                IF NOT AVAILABLE artikel OR NOT artikel.stock OR artikel.blokkeren THEN NEXT.

                iRang = iRang + 1.

                CREATE ttVoorraadDalers.
                ASSIGN
                    ttVoorraadDalers.rang             = iRang
                    ttVoorraadDalers.artnr            = ttVoorraadAgg.artnr
                    ttVoorraadDalers.netto            = ROUND(ttVoorraadAgg.nettoRank, 2)
                    ttVoorraadDalers.aantalBewegingen = ttVoorraadAgg.aantalRank
                    ttVoorraadDalers.huidigeVoorraad  = artikel.aantal
                    ttVoorraadDalers.voorraadMin      = artikel.minv
                    .

                IF TRIM(artikel.omschr-n) NE "" THEN
                    ttVoorraadDalers.omschrijving = TRIM(artikel.omschr-n).
                ELSE IF TRIM(ttVoorraadAgg.omschrSnap) NE "" THEN
                    ttVoorraadDalers.omschrijving = TRIM(ttVoorraadAgg.omschrSnap).
                ELSE
                    ttVoorraadDalers.omschrijving = ttVoorraadAgg.artnr.

                IF iRang GE 5 THEN LEAVE.
            END.

            CATCH eErr AS Progress.Lang.Error:
                EMPTY TEMP-TABLE ttVoorraadDalers.
                EMPTY TEMP-TABLE ttVoorraadSamenvatting.
                CREATE ttVoorraadSamenvatting.
                ASSIGN
                    ttVoorraadSamenvatting.aantalIn        = 0
                    ttVoorraadSamenvatting.aantalUit       = 0
                    ttVoorraadSamenvatting.aantalArtikelen = 0.
                VoorraadBewegingenFailed = TRUE.
                LOG-MANAGER:WRITE-MESSAGE(SUBSTITUTE("DashboardBE:GetVoorraadBewegingen failed: &1":u, eErr:GetMessage(1)), "DashboardBE":u).
            END CATCH.
        END.

        phSamenvatting = TEMP-TABLE ttVoorraadSamenvatting:HANDLE.
        RETURN TEMP-TABLE ttVoorraadDalers:HANDLE.

    END METHOD.

END CLASS.
