/*------------------------------------------------------------------------
    File        : QueryParamHelper.cls
    Purpose     : Static utility for reading query-string params off an
                  IWebRequest, correctly singly percent-decoded.
    Description : OpenEdge.Net.HTTP.URI:GetQueryValue() percent-decodes its
                  result, but the query string it parses from has already
                  been percent-decoded once by the framework by the time it
                  reaches URI:QueryString - so GetQueryValue() double-decodes.
                  Standard single percent-encoding (e.g. a literal "%" in a
                  value encoded as "%25") survives one decode pass intact
                  (e.g. "TEST%2550PCT" -> "TEST%50PCT") but gets mangled by
                  a second pass (the literal "%50" left over is re-decoded
                  as the byte 0x50, "P", yielding "TESTPPCT").
                  This class reads OpenEdge.Net.HTTP.URI:QueryString (which
                  is already singly-decoded - confirmed empirically against
                  the live PASOE instance: for a request
                  "?artnr=TEST%2550PCT", URI:QueryString returns
                  "?artnr=TEST%50PCT", the correct fully-decoded value, no
                  further decoding needed) and parses name/value pairs out
                  of it itself, instead of going through the
                  double-decoding GetQueryValue().

                  2026-08-27 fix: the framework only decodes ONCE, but it
                  does so before this class ever sees the string - by the
                  time we read URI:QueryString, any literal "&" or "="
                  that was part of a value's original content (properly
                  percent-encoded by the client as "%26"/"%3D") has
                  already been decoded back into a literal "&"/"="
                  character, indistinguishable from a real separator.
                  Naively splitting that already-decoded string on every
                  "&" (as this class used to do) mis-splits such values:
                  - confirmed live: "?omschrijving=A%26B&pageSize=5" ->
                    URI:QueryString "?omschrijving=A&B&pageSize=5" -> a
                    blind split on "&" produces THREE pieces
                    ("omschrijving=A", "B", "pageSize=5"), truncating the
                    omschrijving value to "A" and silently dropping "B".
                    This mis-split value is wrong but happens to be cheap
                    to query, so it doesn't show up as a latency problem
                    directly - it's a correctness bug.
                  - confirmed live: "?omschrijving=A%3DB&pageSize=5" ->
                    URI:QueryString "?omschrijving=A=B&pageSize=5" - this
                    one does NOT actually mis-split on "&" (there's only
                    one, in the right place), and INDEX() already finds
                    only the FIRST "=" per pair (see GetQueryValue below),
                    so pageSize was never "swallowed" by this class. The
                    12-20s latency reproduced against this exact input
                    lives one layer down, in Luna.BusinessLogic.ArtikelBE
                    - see docs/backend/artikel.md and the MAX-SCAN-ROWS
                    note on ArtikelBE:GetArtikelen(). Fixed there via a
                    scan cap independent of this parsing fix.
                  No API exposed by IWebRequest/OpenEdge.Net.HTTP.URI
                  hands back the raw, still-percent-encoded query string
                  (only the singly-decoded URI:QueryString) - confirmed by
                  spiking a debug probe against the live PASOE instance;
                  IWebRequest has no GetCgiValue()/CGI-style accessor
                  either. Splitting on the raw encoded string (where a
                  literal "&"/"=" in a value is unambiguously "%26"/"%3D",
                  never a bare "&"/"=") therefore isn't available to us,
                  so this class now splits pairs using the KNOWN, closed
                  set of query-param names this backend ever reads
                  (cKnownParamNames below) as anchors: a "&" in the
                  decoded string only starts a new pair if it's
                  immediately followed by "<one of these names>="; any
                  other "&" (or "=") is treated as literal value content.
                  Residual risk (documented, accepted): a value that
                  itself contains the literal text "&<knownName>=" (e.g.
                  someone typing "...&groep=..." into the omschrijving
                  filter, encoded as %26groep%3D...) is still
                  indistinguishable from a real second param and will be
                  split there. This is a deliberate, narrow trade-off -
                  far smaller than the previous "any character" blind
                  split - and only bites on values that collide with an
                  actual param name; add any new query-param name used by
                  a handler to cKnownParamNames below.
    Author(s)   : Devin
    Created     : 2026-08-27
    Updated     : 2026-08-27 - fixed "&" pair-splitting to use known
                  param names as anchors instead of a blind split, so a
                  percent-encoded "&" inside a value (e.g.
                  omschrijving=A%26B) round-trips as the full decoded
                  value instead of being truncated at the first
                  (spurious) split point.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.IWebRequest.

CLASS Luna.Web.Util.QueryParamHelper:

    /* Closed set of every query-param name any WebHandler in this backend
       reads via GetQueryValue(). Used purely to disambiguate a real "&"
       pair-separator in the (singly-decoded) query string from a literal
       "&" that was part of a value's original, percent-encoded content
       (see the class header comment for why this anchor approach is
       needed). Add a name here whenever a handler starts reading a new
       query param, or its values containing a literal "&" or "%26" will
       silently mis-split. */
    DEFINE PRIVATE STATIC VARIABLE cKnownParamNames AS CHARACTER NO-UNDO INITIAL
        "artnr,omschrijving,groep,onderMinimum,externInBewerking,page,pageSize,datumVan,datumTot,beweging,scan,expectedArtnr,klnr,soort,perDealer,leegRijen":u.

    /*------------------------------------------------------------------------------
        Purpose: Returns the correctly (singly) decoded value of the named query
                 param, or "" (never the unknown value, ?) if it's absent.
        Notes  : Reads poRequest:URI:QueryString directly and parses it itself
                 rather than using poRequest:URI:GetQueryValue(), which
                 percent-decodes a second time on top of the single decode
                 pass the framework has already applied to QueryString - see
                 the class header comment above for the empirical evidence.
                 Pair-splitting uses cKnownParamNames as anchors rather than
                 a blind split on "&" - also see the class header comment.
    ------------------------------------------------------------------------------*/
    METHOD STATIC PUBLIC CHARACTER GetQueryValue( INPUT poRequest AS IWebRequest, INPUT pcName AS CHARACTER ):

        DEFINE VARIABLE cQuery  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iCount  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iPair   AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cPair   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iEq     AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cName   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cValue  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSafe   AS CHARACTER NO-UNDO.

        cQuery = poRequest:URI:QueryString.

        IF cQuery EQ ? OR cQuery EQ "":u THEN
            RETURN "":u.

        IF cQuery BEGINS "?":u THEN
            cQuery = SUBSTRING(cQuery, 2).

        IF cQuery EQ "":u THEN
            RETURN "":u.

        cSafe  = SplitOnKnownParamNames(cQuery).
        iCount = NUM-ENTRIES(cSafe, CHR(1)).

        DO iPair = 1 TO iCount:

            cPair = ENTRY(iPair, cSafe, CHR(1)).
            iEq   = INDEX(cPair, "=":u).

            IF iEq EQ 0 THEN
                ASSIGN
                    cName  = cPair
                    cValue = "":u
                    .
            ELSE
                ASSIGN
                    cName  = SUBSTRING(cPair, 1, iEq - 1)
                    cValue = SUBSTRING(cPair, iEq + 1)
                    .

            IF cName EQ pcName THEN
                RETURN cValue.

        END.

        RETURN "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Re-delimits pcQuery (already singly percent-decoded, no leading
                 "?") from "&"-separated pairs to CHR(1)-separated pairs, but
                 only treating a "&" as a genuine pair separator when it is
                 immediately followed by "<one of cKnownParamNames>=" - any
                 other "&" is left in place as literal value content. This is
                 the anchor logic described in the class header comment; it
                 lets a value that itself contains a percent-encoded "&"
                 (decoded back to a literal "&" by the time we see it) survive
                 intact instead of being mis-split.
        Notes  : "=" is NOT re-delimited here - GetQueryValue only ever takes
                 the FIRST "=" in a pair as the name/value boundary (a param
                 name can never itself contain "="), which is already correct
                 for values containing a literal "=" and needs no change.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE STATIC CHARACTER SplitOnKnownParamNames( INPUT pcQuery AS CHARACTER ):

        DEFINE VARIABLE cResult   AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE iPos      AS INTEGER   NO-UNDO INITIAL 1.
        DEFINE VARIABLE iAmp      AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cAfterAmp AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lGenuine  AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE iKnown    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cKnown    AS CHARACTER NO-UNDO.

        DO WHILE iPos LE LENGTH(pcQuery):

            iAmp = INDEX(pcQuery, "&":u, iPos).

            IF iAmp EQ 0 THEN
            DO:
                cResult = cResult + SUBSTRING(pcQuery, iPos).
                LEAVE.
            END.

            cAfterAmp = SUBSTRING(pcQuery, iAmp + 1).
            lGenuine  = FALSE.

            DO iKnown = 1 TO NUM-ENTRIES(cKnownParamNames):
                cKnown = ENTRY(iKnown, cKnownParamNames).
                IF cAfterAmp BEGINS (cKnown + "=":u) THEN
                DO:
                    lGenuine = TRUE.
                    LEAVE.
                END.
            END.

            IF lGenuine THEN
                ASSIGN
                    cResult = cResult + SUBSTRING(pcQuery, iPos, iAmp - iPos) + CHR(1)
                    iPos    = iAmp + 1
                    .
            ELSE
                ASSIGN
                    cResult = cResult + SUBSTRING(pcQuery, iPos, iAmp - iPos + 1)
                    iPos    = iAmp + 1
                    .

        END.

        RETURN cResult.

    END METHOD.

END CLASS.
