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
                    AND verzonden = FALSE (same "open order" rule as
                    Luna.BusinessLogic.LakproductieBE). "Leveren deze week"
                    is the subset of those with lev-dat in the current
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

END CLASS.
