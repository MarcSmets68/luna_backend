/*------------------------------------------------------------------------
    File        : NPPPlanningBE.cls
    Purpose     : Business Entity for GET /npp/planning - read-only list
                  of LED-montage lines awaiting assembly, sorted by
                  delivery date (bon.lev-dat) with undated rows last.
    Note        : Eligibility filter intentionally duplicated from
                  NPPKwaliteitscontroleBE:GetQueue/IsEligible. Keep the two
                  in sync; if one changes, change both (or extract a shared
                  include in a follow-up).
    Author(s)   : Devin (backend-coder)
    Created     : 2026-10-05
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.NPPPlanningBE:

    DEFINE TEMP-TABLE ttPlanning NO-UNDO
        FIELD bonnr        AS INTEGER
        FIELD groepnr      AS INTEGER
        FIELD lijnnr       AS INTEGER
        FIELD klant        AS CHARACTER
        FIELD artnr        AS CHARACTER
        FIELD omschrijving AS CHARACTER
        FIELD aantal       AS DECIMAL
        FIELD levDatum     AS DATE
        FIELD noDate       AS INTEGER
        INDEX idx-sort noDate levDatum bonnr groepnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Returns {"items": [...]} of eligible bonlijn rows, rows with
                 a levDatum first (ascending), undated rows last.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetQueue():

        DEFINE VARIABLE oResult AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oItem   AS JsonObject NO-UNDO.

        EMPTY TEMP-TABLE ttPlanning.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.ledmontage    EQ TRUE
              AND bonlijn.gereserv      EQ 0
              AND bonlijn.montage-datum EQ ?
              AND bonlijn.stempel       NE "D":u
              AND bonlijn.montage       EQ TRUE
              AND bonlijn.swLed         EQ TRUE:

            FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ bonlijn.bonnr NO-ERROR.

            CREATE ttPlanning.
            ASSIGN
                ttPlanning.bonnr        = bonlijn.bonnr
                ttPlanning.groepnr      = bonlijn.groepnr
                ttPlanning.lijnnr       = bonlijn.lijnnr
                ttPlanning.artnr        = (IF bonlijn.artnr EQ ? THEN "":u ELSE bonlijn.artnr)
                ttPlanning.omschrijving = (IF bonlijn.omschr EQ ? THEN "":u ELSE bonlijn.omschr)
                ttPlanning.aantal       = bonlijn.aantal
                ttPlanning.klant        = (IF AVAILABLE bon AND bon.naam NE ? THEN bon.naam ELSE "":u)
                ttPlanning.levDatum     = (IF AVAILABLE bon THEN bon.lev-dat ELSE ?)
                ttPlanning.noDate       = (IF ttPlanning.levDatum EQ ? THEN 1 ELSE 0)
                .
        END.

        oItems = NEW JsonArray().

        FOR EACH ttPlanning NO-LOCK BY noDate BY levDatum BY bonnr BY groepnr BY lijnnr:

            oItem = NEW JsonObject().
            oItem:Add("bonnr":u, ttPlanning.bonnr).
            oItem:Add("groepnr":u, ttPlanning.groepnr).
            oItem:Add("lijnnr":u, ttPlanning.lijnnr).
            oItem:Add("klant":u, ttPlanning.klant).
            oItem:Add("artnr":u, ttPlanning.artnr).
            oItem:Add("omschrijving":u, ttPlanning.omschrijving).
            oItem:Add("aantal":u, ttPlanning.aantal).

            IF ttPlanning.levDatum EQ ? THEN
                oItem:AddNull("levDatum":u).
            ELSE
                oItem:Add("levDatum":u,
                    STRING(YEAR(ttPlanning.levDatum), "9999":u) + "-":u
                  + STRING(MONTH(ttPlanning.levDatum), "99":u) + "-":u
                  + STRING(DAY(ttPlanning.levDatum), "99":u)).

            oItems:Add(oItem).
        END.

        oResult = NEW JsonObject().
        oResult:Add("items":u, oItems).

        RETURN oResult.

    END METHOD.

END CLASS.
