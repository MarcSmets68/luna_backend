/*------------------------------------------------------------------------
    File        : OfferteHandler.cls
    Purpose     : WebHandler exposing full CRUD for the "offerte" (quote)
                  table (core field subset - see Luna.BusinessLogic.OfferteBE
                  for the field map), plus full CRUD for its `offlijn`
                  (quote line) child rows nested under it (see
                  Luna.BusinessLogic.OfflijnBE for the field map).
    Syntax      : GET    /web/offerte                                 - list offerte (paged/filtered)
                  GET    /web/offerte/{offnr}/{versie}                - get one offerte
                  POST   /web/offerte                                 - create offerte
                  PUT    /web/offerte/{offnr}/{versie}                - update offerte
                  DELETE /web/offerte/{offnr}/{versie}                - delete offerte (cascades its offlijn rows)
                  GET    /web/offerte/{offnr}/{versie}/lijn            - list offlijn for this offerte
                  GET    /web/offerte/{offnr}/{versie}/lijn/{lijnnr}   - get one offlijn
                  POST   /web/offerte/{offnr}/{versie}/lijn            - create offlijn
                  PUT    /web/offerte/{offnr}/{versie}/lijn/{lijnnr}   - update offlijn
                  DELETE /web/offerte/{offnr}/{versie}/lijn/{lijnnr}   - delete offlijn
                  POST   /web/offerte/{offnr}/{versie}/lijn/{lijnnr}/reorder - move offlijn up/down
    Description : Thin WebHandler only - routing, request parsing, response
                  formatting and HTTP status/error mapping. No business logic
                  and no direct DB access - all of that lives in
                  Luna.BusinessLogic.OfferteBE (offerte) and
                  Luna.BusinessLogic.OfflijnBE (offlijn).
    Author(s)   : Devin
    Created     : 2026-08-11
    Updated     : 2026-08-12 - added full offerte CRUD and nested offlijn CRUD.
                  2026-08-19 - pass through new `offnr` query param (prefix
                  filter) to OfferteBE:GetOffertes().
                  2026-08-26 - Offertebeheer Fase 1: POST /offerte and POST
                  .../lijn now support offnr/versie/lijnnr auto-allocation;
                  added the nested POST .../lijn/{lijnnr}/reorder action
                  route (OfflijnBE:ReorderOfflijn). All new business logic
                  (auto-allocation, verloren auto-clear, structural guards,
                  swap logic) lives in OfferteBE/OfflijnBE - this class only
                  gained the extra path-segment routing for `reorder`.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.OfferteBE.
USING Luna.BusinessLogic.OfflijnBE.
USING Luna.BusinessLogic.OfferteConversieBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.OfferteHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/offerte" with the implicit
       trailing wildcard, so this also matches every nested path below it
       too (offnr/versie, and offnr/versie/lijn[/lijnnr]). This constant is
       the mount point we strip off PathInfo to find the remaining path
       segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/offerte":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount point,
                 e.g. "/offerte/123/1" -> "123/1", "/offerte/123/1/lijn/5" ->
                 "123/1/lijn/5", "/offerte" or "/offerte/" -> "".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetPathRemainder( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cPathInfo AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRest     AS CHARACTER NO-UNDO.

        cPathInfo = poRequest:PathInfo.

        IF cPathInfo BEGINS cMountPoint THEN
            cRest = SUBSTRING(cPathInfo, LENGTH(cMountPoint) + 1).
        ELSE
            cRest = cPathInfo.

        cRest = TRIM(cRest, "/":u).

        RETURN cRest.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Number of "/"-separated segments in the path remainder ("" -> 0).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER SegmentCount( INPUT pcRemainder AS CHARACTER ):

        IF pcRemainder EQ "":u THEN
            RETURN 0.

        RETURN NUM-ENTRIES(pcRemainder, "/":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the "/offnr/versie" prefix (the first two segments) of
                 a path remainder into integers.
        Errors : Throws AppError 400 if either segment is missing/not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ParseOffnrVersie(
        INPUT  pcRemainder AS CHARACTER,
        OUTPUT piOffnr     AS INTEGER,
        OUTPUT piVersie    AS INTEGER ):

        DEFINE VARIABLE cOffnr  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cVersie AS CHARACTER NO-UNDO.

        cOffnr  = ENTRY(1, pcRemainder, "/":u).
        cVersie = ENTRY(2, pcRemainder, "/":u).

        piOffnr = INTEGER(cOffnr) NO-ERROR.
        IF piOffnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid offnr &1":u, cOffnr), 400).

        piVersie = INTEGER(cVersie) NO-ERROR.
        IF piVersie EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid versie &1":u, cVersie), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the "/offnr/versie/lijn/lijnnr" path remainder's
                 4th segment (lijnnr) into an integer.
        Errors : Throws AppError 400 if the segment is not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseLijnnr( INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE cLijnnr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iLijnnr AS INTEGER   NO-UNDO.

        cLijnnr = ENTRY(4, pcRemainder, "/":u).

        iLijnnr = INTEGER(cLijnnr) NO-ERROR.
        IF iLijnnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid lijnnr &1":u, cLijnnr), 400).

        RETURN iLijnnr.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates that the 3rd path segment (if present) is the
                 literal "lijn" - the only nested resource under offerte.
        Errors : Throws AppError 400 if it isn't.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateLijnSegment( INPUT pcRemainder AS CHARACTER ):

        IF ENTRY(3, pcRemainder, "/":u) NE "lijn":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Expected /offerte/[offnr]/[versie]/lijn[/[lijnnr]], got &1":u, pcRemainder), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject.
        Errors : Throws AppError 400 if the body is missing or not a JSON object.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            /* poRequest:Entity lazily deserializes the raw request body the
               first time it's accessed, right here. A malformed body (e.g.
               a stray UTF-8 BOM prepended by some HTTP clients/tools before
               the JSON, or plain invalid JSON) makes the underlying
               OpenEdge JSON parser throw a non-AppError (a JSON parser
               lexical error) - uncaught, that used to escape this method
               entirely, bypass the calling method's own
               "CATCH ... AS Progress.Lang.AppError", and reach PASOE's
               generic framework error handler, producing a raw 500 (HTML,
               or a JSON envelope with empty exception fields) instead of
               the documented 400. Re-throw AppErrors as-is (e.g. the
               "must be a JSON object" one above); convert anything else
               (the JSON parser error case) into a clean AppError 400 here
               so it's mapped the same as any other bad request. */
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Serializes a ttOfferte/ttOfflijn result handle to a
                 JsonObject shaped as {"items": [...]}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR         NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes a JSON response with the given status code.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteJsonResponse( INPUT piStatusCode AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE oResponse AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter               NO-UNDO.

        ASSIGN
            oResponse             = NEW OpenEdge.Web.WebResponse()
            oResponse:StatusCode  = piStatusCode
            oResponse:Entity      = poBody
            oResponse:ContentType = "application/json":u
            .

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes a JSON error response: {"error": {"message": "...", "code": n}}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteErrorResponse( INPUT piStatusCode AS INTEGER, INPUT pcMessage AS CHARACTER ):

        DEFINE VARIABLE oError AS JsonObject NO-UNDO.
        DEFINE VARIABLE oBody  AS JsonObject NO-UNDO.

        oError = NEW JsonObject().
        oError:Add("message":u, pcMessage).
        oError:Add("code":u, piStatusCode).

        oBody = NEW JsonObject().
        oBody:Add("error":u, oError).

        WriteJsonResponse(piStatusCode, oBody).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Maps an AppError raised by OfferteBE/OfflijnBE (400/404/409)
                 to an HTTP status code, defaulting unrecognized codes to 500
                 so no ABL stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /offerte (list, paged/filtered), GET /offerte/{offnr}/{versie}
                 (single offerte), GET /offerte/{offnr}/{versie}/lijn (list
                 offlijn) and GET /offerte/{offnr}/{versie}/lijn/{lijnnr}
                 (single offlijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oOfferteService AS OfferteBE   NO-UNDO.
        DEFINE VARIABLE oOfflijnService AS OfflijnBE   NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iOffnr          AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iVersie         AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER     NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray   NO-UNDO.
        DEFINE VARIABLE cKlnr           AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iKlnr           AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cOffgroep       AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cOffnr          AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cNaam           AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iPage           AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize       AS INTEGER     NO-UNDO.
        DEFINE VARIABLE lHasMore        AS LOGICAL     NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 3 THEN
        DO:
            /* GET /offerte/{offnr}/{versie}/lijn[/{lijnnr}] */
            ValidateLijnSegment(cRemainder).
            ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).

            oOfflijnService = NEW OfflijnBE().

            IF iSegCount EQ 4 THEN
            DO:
                iLijnnr = ParseLijnnr(cRemainder).

                hResult = oOfflijnService:GetOfflijn(iOffnr, iVersie, iLijnnr).
                oBody   = ResultHandleToJson(hResult).
                oItems  = oBody:GetJsonArray("items":u).

                IF oItems:Length EQ 0 THEN
                    WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                        SUBSTITUTE("Offlijn &1/&2/&3 not found":u, iOffnr, iVersie, iLijnnr)).
                ELSE
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF iSegCount NE 3 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /offerte/[offnr]/[versie]/lijn[/[lijnnr]], got &1":u, cRemainder)).
                RETURN 0.
            END.

            /* GET /offerte/{offnr}/{versie}/lijn (list, no paging - a quote
               typically has a bounded number of lines). */
            hResult = oOfflijnService:GetOfflijnen(iOffnr, iVersie).
            oBody   = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        oOfferteService = NEW OfferteBE().

        IF iSegCount EQ 2 THEN
        DO:
            /* GET /offerte/{offnr}/{versie} */
            ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).

            hResult = oOfferteService:GetOfferte(iOffnr, iVersie).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                    SUBSTITUTE("Offerte &1/&2 not found":u, iOffnr, iVersie)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 1 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /offerte/[offnr]/[versie], got &1":u, cRemainder)).
            RETURN 0.
        END.

        /* GET /offerte (list). GetQueryValue returns the unknown value (?)
           when a query param is absent - normalize that to "" (or 0 for
           klnr) so the OfferteBE filters treat "not supplied" and
           "supplied blank" the same way. */
        cKlnr     = poRequest:URI:GetQueryValue("klnr":u).
        cOffgroep = poRequest:URI:GetQueryValue("offgroep":u).
        cOffnr    = poRequest:URI:GetQueryValue("offnr":u).
        cNaam     = poRequest:URI:GetQueryValue("naam":u).

        IF cOffgroep EQ ? THEN cOffgroep = "":u.
        IF cOffnr EQ ? THEN cOffnr = "":u.
        IF cNaam EQ ? THEN cNaam = "":u.

        iKlnr = INTEGER(cKlnr) NO-ERROR.
        IF iKlnr EQ ? THEN iKlnr = 0.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        hResult = oOfferteService:GetOffertes(iKlnr, cOffgroep, cOffnr, cNaam, iPage, iPageSize, OUTPUT lHasMore).
        oBody   = ResultHandleToJson(hResult).

        oBody:Add("page":u, iPage).
        oBody:Add("pageSize":u, iPageSize).
        oBody:Add("hasMore":u, lHasMore).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /offerte (create offerte) and
                 POST /offerte/{offnr}/{versie}/lijn (create offlijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oOfferteService          AS OfferteBE          NO-UNDO.
        DEFINE VARIABLE oOfflijnService          AS OfflijnBE          NO-UNDO.
        DEFINE VARIABLE oOfferteConversieService AS OfferteConversieBE NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iOffnr          AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVersie         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cDirection      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oReqBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray  NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).
        oReqBody   = GetJsonBody(poRequest).

        IF iSegCount EQ 0 THEN
        DO:
            /* POST /offerte (create offerte) - offnr/versie explicit, or
               both omitted for server auto-allocation (see OfferteBE:CreateOfferte). */
            oOfferteService = NEW OfferteBE().
            hResult = oOfferteService:CreateOfferte(oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 3 AND ENTRY(3, cRemainder, "/":u) EQ "omzetten-naar-order":u THEN
        DO:
            /* POST /offerte/{offnr}/{versie}/omzetten-naar-order (Iteratie
               D - Offerte->Order conversie). Body is not read - the
               conversion takes no parameters. */
            ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).

            oOfferteConversieService = NEW OfferteConversieBE().
            hResult = oOfferteConversieService:OmzettenNaarOrder(iOffnr, iVersie).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("resultaat":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            /* POST /offerte/{offnr}/{versie}/lijn (create offlijn) - lijnnr
               explicit, or omitted for server auto-allocation (see
               OfflijnBE:CreateOfflijn). */
            ValidateLijnSegment(cRemainder).
            ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).

            oOfflijnService = NEW OfflijnBE().
            hResult = oOfflijnService:CreateOfflijn(iOffnr, iVersie, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 5 THEN
        DO:
            /* POST /offerte/{offnr}/{versie}/lijn/{lijnnr}/reorder */
            ValidateLijnSegment(cRemainder).
            ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).
            iLijnnr = ParseLijnnr(cRemainder).

            IF ENTRY(5, cRemainder, "/":u) NE "reorder":u THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /offerte/[offnr]/[versie]/lijn/[lijnnr]/reorder, got &1":u, cRemainder)).
                RETURN 0.
            END.

            cDirection = "":u.
            IF oReqBody:Has("direction":u) THEN
                cDirection = oReqBody:GetCharacter("direction":u).

            oOfflijnService = NEW OfflijnBE().
            hResult = oOfflijnService:ReorderOfflijn(iOffnr, iVersie, iLijnnr, cDirection).
            oBody   = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Expected /offerte, /offerte/[offnr]/[versie]/lijn or /offerte/[offnr]/[versie]/lijn/[lijnnr]/reorder, got &1":u, cRemainder)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /offerte/{offnr}/{versie} (update offerte) and
                 PUT /offerte/{offnr}/{versie}/lijn/{lijnnr} (update offlijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oOfferteService AS OfferteBE   NO-UNDO.
        DEFINE VARIABLE oOfflijnService AS OfflijnBE   NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iOffnr          AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVersie         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray  NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount NE 2 AND iSegCount NE 4 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /offerte/[offnr]/[versie] or /offerte/[offnr]/[versie]/lijn/[lijnnr], got &1":u,
                    cRemainder)).
            RETURN 0.
        END.

        ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).
        oReqBody = GetJsonBody(poRequest).

        IF iSegCount EQ 4 THEN
        DO:
            /* PUT /offerte/{offnr}/{versie}/lijn/{lijnnr} (update offlijn) */
            ValidateLijnSegment(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).

            oOfflijnService = NEW OfflijnBE().
            hResult = oOfflijnService:UpdateOfflijn(iOffnr, iVersie, iLijnnr, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* PUT /offerte/{offnr}/{versie} (update offerte) */
        oOfferteService = NEW OfferteBE().
        hResult = oOfferteService:UpdateOfferte(iOffnr, iVersie, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: DELETE /offerte/{offnr}/{versie} (delete offerte, cascades
                 its offlijn rows) and
                 DELETE /offerte/{offnr}/{versie}/lijn/{lijnnr} (delete offlijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oOfferteService AS OfferteBE   NO-UNDO.
        DEFINE VARIABLE oOfflijnService AS OfflijnBE   NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iOffnr          AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVersie         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount NE 2 AND iSegCount NE 4 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /offerte/[offnr]/[versie] or /offerte/[offnr]/[versie]/lijn/[lijnnr], got &1":u,
                    cRemainder)).
            RETURN 0.
        END.

        ParseOffnrVersie(cRemainder, OUTPUT iOffnr, OUTPUT iVersie).

        IF iSegCount EQ 4 THEN
        DO:
            /* DELETE /offerte/{offnr}/{versie}/lijn/{lijnnr} */
            ValidateLijnSegment(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).

            oOfflijnService = NEW OfflijnBE().
            oOfflijnService:DeleteOfflijn(iOffnr, iVersie, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("offnr":u, iOffnr).
            oBody:Add("versie":u, iVersie).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        /* DELETE /offerte/{offnr}/{versie} */
        oOfferteService = NEW OfferteBE().
        oOfferteService:DeleteOfferte(iOffnr, iVersie).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("offnr":u, iOffnr).
        oBody:Add("versie":u, iVersie).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /offerte":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /offerte":u).
        RETURN 0.
    END METHOD.

END CLASS.
