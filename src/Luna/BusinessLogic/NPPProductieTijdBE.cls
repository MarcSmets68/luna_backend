/*------------------------------------------------------------------------
    File        : NPPProductieTijdBE.cls
    Purpose     : Business Entity for GET /npp/productietijd - read-only
                  export of the raw "productietijd" rows (written by the
                  legacy NPP TijdRegistratie.p on every Start/Pauze/Herstart/
                  Stop/Afgewerkt click) for the last 12 months, for
                  duration analysis outside Luna.
    Note        : One row = one timestamp, not a duration. Durations must be
                  derived from consecutive rows per bonnr+groepnr+id.
    Author(s)   : Devin
    Created     : 2026-10-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.NPPProductieTijdBE:

    DEFINE TEMP-TABLE ttMontage NO-UNDO
        FIELD bonnr   AS INTEGER
        FIELD groepnr AS INTEGER
        FIELD artnr   AS CHARACTER
        FIELD aantal  AS DECIMAL
        FIELD lijnen  AS INTEGER
        INDEX idx-key IS UNIQUE PRIMARY bonnr groepnr.

    /*------------------------------------------------------------------------------
        Purpose: Cached lookup of the montage article of a bon/groep: the first
                 bonlijn with montage AND swLed (same selection as the legacy
                 NPPAssemblage vul-montage), regardless of stempel so finished
                 bons are included. Unknown bon/groep -> unavailable ttMontage.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID FindMontage( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        FIND FIRST ttMontage WHERE ttMontage.bonnr EQ piBonnr AND ttMontage.groepnr EQ piGroepnr NO-ERROR.
        IF AVAILABLE ttMontage THEN
            RETURN.

        CREATE ttMontage.
        ASSIGN ttMontage.bonnr = piBonnr ttMontage.groepnr = piGroepnr ttMontage.artnr = "":u.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.bonnr   EQ piBonnr
              AND bonlijn.groepnr EQ piGroepnr
              AND bonlijn.montage EQ TRUE
              AND bonlijn.swLed   EQ TRUE
            BY bonlijn.lijnnr:

            ttMontage.lijnen = ttMontage.lijnen + 1.
            IF ttMontage.lijnen EQ 1 THEN
                ASSIGN
                    ttMontage.artnr  = (IF bonlijn.artnr EQ ? THEN "":u ELSE bonlijn.artnr)
                    ttMontage.aantal = bonlijn.aantal.
        END.

    END METHOD.

    METHOD PRIVATE CHARACTER IsoDate( INPUT pdDatum AS DATE ):

        RETURN STRING(YEAR(pdDatum), "9999":u) + "-":u
             + STRING(MONTH(pdDatum), "99":u) + "-":u
             + STRING(DAY(pdDatum), "99":u).

    END METHOD.

    DEFINE TEMP-TABLE ttTijd NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr         AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD volgnr        AS INTEGER   SERIALIZE-NAME "volgnr":u
        FIELD datum         AS CHARACTER SERIALIZE-NAME "datum":u
        FIELD uur           AS CHARACTER SERIALIZE-NAME "uur":u
        FIELD bonnr         AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD groepnr       AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD programma     AS CHARACTER SERIALIZE-NAME "programma":u
        FIELD actie         AS CHARACTER SERIALIZE-NAME "actie":u
        FIELD id            AS CHARACTER SERIALIZE-NAME "id":u
        FIELD montageArtnr  AS CHARACTER SERIALIZE-NAME "montageArtnr":u
        FIELD montageAantal AS DECIMAL   SERIALIZE-NAME "montageAantal":u
        FIELD montageLijnen AS INTEGER   SERIALIZE-NAME "montageLijnen":u
        INDEX idx-sort IS PRIMARY datum uur artnr volgnr.

    /*------------------------------------------------------------------------------
        Purpose: Returns {"from": "yyyy-mm-dd", "count": n, "items": [...]} with
                 all productietijd rows since 12 months ago, in datum/uur/
                 artnr/volgnr order. pcProgramma filters on
                 productietijd.programma ("" = all programs). plAlleenTijd
                 limits the rows to the timing actions (Start, Herstart,
                 Pauze, Stop, Afgewerkt, Afgebroken) - roughly half of the
                 rows, enough to derive durations. Rows are serialized with
                 the temp-table WRITE-JSON (much faster than a JsonObject
                 per row for tens of thousands of rows).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetProductieTijden( INPUT pcProgramma AS CHARACTER, INPUT plAlleenTijd AS LOGICAL ):

        DEFINE VARIABLE oResult AS JsonObject NO-UNDO.
        DEFINE VARIABLE oRows   AS JsonObject NO-UNDO.
        DEFINE VARIABLE dtFrom  AS DATE       NO-UNDO.
        DEFINE VARIABLE iCount  AS INTEGER    NO-UNDO.

        EMPTY TEMP-TABLE ttMontage.
        EMPTY TEMP-TABLE ttTijd.

        dtFrom = DATE(ADD-INTERVAL(TODAY, -12, "months":u)).

        FOR EACH productietijd NO-LOCK
            WHERE productietijd.datum GE dtFrom
              AND (pcProgramma EQ "":u OR productietijd.programma EQ pcProgramma):

            IF plAlleenTijd AND LOOKUP(productietijd.actie, "Start,Herstart,Pauze,Stop,Afgewerkt,Afgebroken":u) EQ 0 THEN
                NEXT.

            FindMontage( productietijd.bonnr, productietijd.groepnr ).

            CREATE ttTijd.
            ASSIGN
                ttTijd.artnr         = (IF productietijd.artnr EQ ? THEN "":u ELSE productietijd.artnr)
                ttTijd.volgnr        = productietijd.volgnr
                ttTijd.datum         = IsoDate(productietijd.datum)
                ttTijd.uur           = (IF productietijd.uur EQ ? THEN "":u ELSE productietijd.uur)
                ttTijd.bonnr         = productietijd.bonnr
                ttTijd.groepnr       = productietijd.groepnr
                ttTijd.programma     = (IF productietijd.programma EQ ? THEN "":u ELSE productietijd.programma)
                ttTijd.actie         = (IF productietijd.actie EQ ? THEN "":u ELSE productietijd.actie)
                ttTijd.id            = (IF productietijd.id EQ ? THEN "":u ELSE productietijd.id)
                ttTijd.montageArtnr  = ttMontage.artnr
                ttTijd.montageAantal = ttMontage.aantal
                ttTijd.montageLijnen = ttMontage.lijnen
                iCount               = iCount + 1.
        END.

        oRows = NEW JsonObject().
        TEMP-TABLE ttTijd:HANDLE:WRITE-JSON("JsonObject":u, oRows).

        oResult = NEW JsonObject().
        oResult:Add("from":u, IsoDate(dtFrom)).
        oResult:Add("count":u, iCount).
        oResult:Add("items":u, oRows:GetJsonArray("items":u)).

        RETURN oResult.

    END METHOD.

END CLASS.
