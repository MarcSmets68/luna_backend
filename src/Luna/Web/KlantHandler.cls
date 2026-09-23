/*------------------------------------------------------------------------
    File        : KlantHandler.cls
    Purpose     : WebHandler exposing full CRUD for the "klant" table
                  (core field subset - see Luna.BusinessLogic.KlantBE for
                  the field map), plus the extended klant info tab
                  ("uitgebreid") and full CRUD for its three nested child
                  resources: adres (klant-adr), contact (klant-contact) and
                  korting (korting, swGroep = FALSE only).
    Syntax      : GET    /web/klant                                 - list (paged/filtered)
                  GET    /web/klant/{klnr}                          - get one
                  POST   /web/klant                                 - create
                  PUT    /web/klant/{klnr}                          - update
                  DELETE /web/klant/{klnr}                          - delete
                  GET    /web/klant/{klnr}/uitgebreid                - get extended scalar fields
                                                                        + nested adressen/contacten/kortingen
                  PUT    /web/klant/{klnr}/uitgebreid                - update extended scalar fields (partial)
                  GET    /web/klant/{klnr}/adres                     - list klant-adr
                  GET    /web/klant/{klnr}/adres/{lijnnr}            - get one klant-adr
                  POST   /web/klant/{klnr}/adres                     - create klant-adr
                  PUT    /web/klant/{klnr}/adres/{lijnnr}            - update klant-adr
                  DELETE /web/klant/{klnr}/adres/{lijnnr}            - delete klant-adr
                  GET    /web/klant/{klnr}/contact                   - list klant-contact
                  GET    /web/klant/{klnr}/contact/{lijnnr}          - get one klant-contact
                  POST   /web/klant/{klnr}/contact                   - create klant-contact
                  PUT    /web/klant/{klnr}/contact/{lijnnr}          - update klant-contact
                  DELETE /web/klant/{klnr}/contact/{lijnnr}          - delete klant-contact
                  GET    /web/klant/{klnr}/korting                   - list korting (swGroep = FALSE)
                  GET    /web/klant/{klnr}/korting/{artnr}           - get one korting
                  POST   /web/klant/{klnr}/korting                   - create korting
                  PUT    /web/klant/{klnr}/korting/{artnr}           - update korting
                  DELETE /web/klant/{klnr}/korting/{artnr}           - delete korting
    Description : Thin WebHandler only - routing, request parsing, response
                  formatting and HTTP status/error mapping. No business logic
                  and no direct DB access - all of that lives in
                  Luna.BusinessLogic.KlantBE (klant + uitgebreid),
                  Luna.BusinessLogic.KlantAdresBE (klant-adr),
                  Luna.BusinessLogic.KlantContactBE (klant-contact) and
                  Luna.BusinessLogic.KlantKortingBE (korting). The GET
                  .../uitgebreid response is composed here (scalar fields +
                  the three nested lists merged into one JSON object) - this
                  is response shaping, not business logic; every field/list
                  itself still comes straight from its owning Business
                  Entity.
    Author(s)   : Devin
    Created     : 2026-08-10
    Updated     : 2026-08-27 - added the "uitgebreid" extended info tab and
                  nested adres/contact/korting CRUD (Klant - Uitgebreide
                  klanteninfo). Path parsing for the nested sub-resources
                  follows the GetPathRemainder/SegmentCount pattern from
                  Luna.Web.OfferteHandler.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.KlantBE.
USING Luna.BusinessLogic.KlantAdresBE.
USING Luna.BusinessLogic.KlantContactBE.
USING Luna.BusinessLogic.KlantKortingBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.KlantHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/klant" with the implicit
       trailing wildcard, so this also matches every nested path below it
       too (klnr, klnr/uitgebreid, klnr/adres[/lijnnr], klnr/contact[/lijnnr]
       and klnr/korting[/artnr]). This constant is the mount point we strip
       off PathInfo to find the remaining path segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/klant":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount point,
                 e.g. "/klant/123/adres/5" -> "123/adres/5", "/klant" or
                 "/klant/" -> "".
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
        Purpose: Parses the leading klnr segment of a path remainder into an
                 integer.
        Errors : Throws AppError 400 if it's missing/not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseKlnr( INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE cKlnr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iKlnr AS INTEGER   NO-UNDO.

        cKlnr = ENTRY(1, pcRemainder, "/":u).

        iKlnr = INTEGER(cKlnr) NO-ERROR.
        IF ERROR-STATUS:ERROR OR iKlnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid klnr &1":u, cKlnr), 400).

        RETURN iKlnr.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the 3rd segment of a path remainder (the child's own
                 id - lijnnr for adres/contact, artnr for korting).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetChildId( INPUT pcRemainder AS CHARACTER ):

        RETURN ENTRY(3, pcRemainder, "/":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses a child id segment (lijnnr, for adres/contact) into
                 an integer.
        Errors : Throws AppError 400 if it's not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseLijnnr( INPUT pcLijnnr AS CHARACTER ):

        DEFINE VARIABLE iLijnnr AS INTEGER NO-UNDO.

        iLijnnr = INTEGER(pcLijnnr) NO-ERROR.
        IF ERROR-STATUS:ERROR OR iLijnnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid lijnnr &1":u, pcLijnnr), 400).

        RETURN iLijnnr.

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
               entirely, bypass HandlePost/HandlePut's own
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
        Purpose: Serializes a ttKlant result handle (from KlantBE) to a
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
        Purpose: Maps an AppError raised by KlantBE (400/404/409) to an HTTP
                 status code, defaulting unrecognized codes to 500 so no ABL
                 stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the composed GET /klant/{klnr}/uitgebreid response:
                 the extended scalar fields plus the three nested lists
                 (adressen, contacten, kortingen) merged into one JSON
                 object. Pure response shaping - each field/list still comes
                 straight from its owning Business Entity.
        Errors : AppError code 404 - klnr not found (from KlantBE).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject BuildUitgebreidResponse( INPUT piKlnr AS INTEGER ):

        DEFINE VARIABLE oKlantService   AS KlantBE        NO-UNDO.
        DEFINE VARIABLE oAdresService   AS KlantAdresBE   NO-UNDO.
        DEFINE VARIABLE oContactService AS KlantContactBE NO-UNDO.
        DEFINE VARIABLE oKortingService AS KlantKortingBE NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE         NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray      NO-UNDO.
        DEFINE VARIABLE oKlantObj       AS JsonObject     NO-UNDO.

        oKlantService = NEW KlantBE().

        hResult = oKlantService:GetKlantUitgebreid(piKlnr).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        IF oItems:Length EQ 0 THEN
            RETURN ?.

        oKlantObj = oItems:GetJsonObject(1).

        oAdresService   = NEW KlantAdresBE().
        oContactService = NEW KlantContactBE().
        oKortingService = NEW KlantKortingBE().

        hResult = oAdresService:GetKlantAdressen(piKlnr).
        oKlantObj:Add("adressen":u, ResultHandleToJson(hResult):GetJsonArray("items":u)).

        hResult = oContactService:GetKlantContacten(piKlnr).
        oKlantObj:Add("contacten":u, ResultHandleToJson(hResult):GetJsonArray("items":u)).

        hResult = oKortingService:GetKortingen(piKlnr).
        oKlantObj:Add("kortingen":u, ResultHandleToJson(hResult):GetJsonArray("items":u)).

        RETURN oKlantObj.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /klant (list, paged/filtered), GET /klant/{klnr}
                 (single record), GET /klant/{klnr}/uitgebreid (extended
                 fields + nested lists) and GET /klant/{klnr}/{adres|
                 contact|korting}[/{id}] (list/get one child row).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService        AS KlantBE        NO-UNDO.
        DEFINE VARIABLE oAdresService   AS KlantAdresBE   NO-UNDO.
        DEFINE VARIABLE oContactService AS KlantContactBE NO-UNDO.
        DEFINE VARIABLE oKortingService AS KlantKortingBE NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER        NO-UNDO.
        DEFINE VARIABLE iKlnr           AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cSub            AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE cChildId        AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER        NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE         NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray      NO-UNDO.
        DEFINE VARIABLE oKlantObj       AS JsonObject     NO-UNDO.
        DEFINE VARIABLE iPage           AS INTEGER        NO-UNDO.
        DEFINE VARIABLE iPageSize       AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cNaam           AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE lHasMore        AS LOGICAL        NO-UNDO.
        DEFINE VARIABLE lNomaledOnly    AS LOGICAL        NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount EQ 0 THEN
        DO:
            /* GET /klant (list). */
            oService = NEW KlantBE().

            iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
            IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

            iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
            IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
            IF iPageSize GT 200 THEN iPageSize = 200.

            /* GetQueryValue returns the unknown value (?) when the query
               param is absent - normalize that to "" so KlantBE treats
               "not supplied" and "supplied blank" the same way (same as
               Luna.Web.FactuurHandler). */
            cNaam = poRequest:URI:GetQueryValue("naam":u).
            IF cNaam EQ ? THEN cNaam = "":u.

            /* Same permissive parse style as page/pageSize above - invalid
               or missing "nomaled" query param means "no filter" (FALSE),
               never a 400. */
            lNomaledOnly = LOGICAL(poRequest:URI:GetQueryValue("nomaled":u)) NO-ERROR.
            IF lNomaledOnly EQ ? THEN lNomaledOnly = FALSE.

            hResult = oService:GetKlanten(iPage, iPageSize, cNaam, lNomaledOnly, OUTPUT lHasMore).
            oBody   = ResultHandleToJson(hResult).

            oBody:Add("page":u, iPage).
            oBody:Add("pageSize":u, iPageSize).
            oBody:Add("hasMore":u, lHasMore).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        iKlnr = ParseKlnr(cRemainder).

        IF iSegCount EQ 1 THEN
        DO:
            /* GET /klant/{klnr} */
            oService = NEW KlantBE().

            hResult = oService:GetKlant(iKlnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Klant &1 not found":u, iKlnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        cSub = ENTRY(2, cRemainder, "/":u).

        IF iSegCount EQ 2 THEN
        DO:
            CASE cSub:
                WHEN "uitgebreid":u THEN
                DO:
                    /* GET /klant/{klnr}/uitgebreid */
                    oKlantObj = BuildUitgebreidResponse(iKlnr).

                    IF oKlantObj EQ ? THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Klant &1 not found":u, iKlnr)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oKlantObj).

                    RETURN 0.
                END.
                WHEN "adres":u THEN
                DO:
                    /* GET /klant/{klnr}/adres (list) */
                    oAdresService = NEW KlantAdresBE().
                    hResult = oAdresService:GetKlantAdressen(iKlnr).
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), ResultHandleToJson(hResult)).
                    RETURN 0.
                END.
                WHEN "contact":u THEN
                DO:
                    /* GET /klant/{klnr}/contact (list) */
                    oContactService = NEW KlantContactBE().
                    hResult = oContactService:GetKlantContacten(iKlnr).
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), ResultHandleToJson(hResult)).
                    RETURN 0.
                END.
                WHEN "korting":u THEN
                DO:
                    /* GET /klant/{klnr}/korting (list) */
                    oKortingService = NEW KlantKortingBE().
                    hResult = oKortingService:GetKortingen(iKlnr).
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), ResultHandleToJson(hResult)).
                    RETURN 0.
                END.
                OTHERWISE
                DO:
                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Expected /klant/[klnr]/(uitgebreid|adres|contact|korting), got &1":u, cRemainder)).
                    RETURN 0.
                END.
            END CASE.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            cChildId = GetChildId(cRemainder).

            CASE cSub:
                WHEN "adres":u THEN
                DO:
                    /* GET /klant/{klnr}/adres/{lijnnr} */
                    iLijnnr = ParseLijnnr(cChildId).
                    oAdresService = NEW KlantAdresBE().

                    hResult = oAdresService:GetKlantAdres(iKlnr, iLijnnr).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    IF oItems:Length EQ 0 THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                            SUBSTITUTE("Adres &1/&2 not found":u, iKlnr, iLijnnr)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.
                WHEN "contact":u THEN
                DO:
                    /* GET /klant/{klnr}/contact/{lijnnr} */
                    iLijnnr = ParseLijnnr(cChildId).
                    oContactService = NEW KlantContactBE().

                    hResult = oContactService:GetKlantContact(iKlnr, iLijnnr).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    IF oItems:Length EQ 0 THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                            SUBSTITUTE("Contact &1/&2 not found":u, iKlnr, iLijnnr)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.
                WHEN "korting":u THEN
                DO:
                    /* GET /klant/{klnr}/korting/{artnr} */
                    oKortingService = NEW KlantKortingBE().

                    hResult = oKortingService:GetKorting(iKlnr, cChildId).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    IF oItems:Length EQ 0 THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                            SUBSTITUTE("Korting &1/&2 not found":u, iKlnr, cChildId)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.
                OTHERWISE
                DO:
                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Expected /klant/[klnr]/(adres|contact|korting)/[id], got &1":u, cRemainder)).
                    RETURN 0.
                END.
            END CASE.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Unrecognized path /klant/&1":u, cRemainder)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /klant (create) and
                 POST /klant/{klnr}/(adres|contact|korting) (create child row).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService        AS KlantBE        NO-UNDO.
        DEFINE VARIABLE oAdresService   AS KlantAdresBE   NO-UNDO.
        DEFINE VARIABLE oContactService AS KlantContactBE NO-UNDO.
        DEFINE VARIABLE oKortingService AS KlantKortingBE NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER        NO-UNDO.
        DEFINE VARIABLE iKlnr           AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cSub            AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE oReqBody        AS JsonObject     NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE         NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray      NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).
        oReqBody   = GetJsonBody(poRequest).

        IF iSegCount EQ 0 THEN
        DO:
            /* POST /klant (create) */
            oService = NEW KlantBE().

            hResult = oService:CreateKlant(oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 2 THEN
        DO:
            iKlnr = ParseKlnr(cRemainder).
            cSub  = ENTRY(2, cRemainder, "/":u).

            CASE cSub:
                WHEN "adres":u THEN
                DO:
                    oAdresService = NEW KlantAdresBE().
                    hResult = oAdresService:CreateKlantAdres(iKlnr, oReqBody).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).
                    WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).
                    RETURN 0.
                END.
                WHEN "contact":u THEN
                DO:
                    oContactService = NEW KlantContactBE().
                    hResult = oContactService:CreateKlantContact(iKlnr, oReqBody).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).
                    WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).
                    RETURN 0.
                END.
                WHEN "korting":u THEN
                DO:
                    oKortingService = NEW KlantKortingBE().
                    hResult = oKortingService:CreateKorting(iKlnr, oReqBody).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).
                    WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).
                    RETURN 0.
                END.
                OTHERWISE
                DO:
                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Expected /klant/[klnr]/(adres|contact|korting), got &1":u, cRemainder)).
                    RETURN 0.
                END.
            END CASE.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Unrecognized path /klant/&1":u, cRemainder)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /klant/{klnr} (update), PUT /klant/{klnr}/uitgebreid
                 (update extended fields) and
                 PUT /klant/{klnr}/(adres|contact|korting)/{id} (update
                 child row).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService        AS KlantBE        NO-UNDO.
        DEFINE VARIABLE oAdresService   AS KlantAdresBE   NO-UNDO.
        DEFINE VARIABLE oContactService AS KlantContactBE NO-UNDO.
        DEFINE VARIABLE oKortingService AS KlantKortingBE NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER        NO-UNDO.
        DEFINE VARIABLE iKlnr           AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cSub            AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE cChildId        AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER        NO-UNDO.
        DEFINE VARIABLE oReqBody        AS JsonObject     NO-UNDO.
        DEFINE VARIABLE hResult         AS HANDLE         NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oItems          AS JsonArray      NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "klnr path segment is required, e.g. /klant/123":u).
            RETURN 0.
        END.

        iKlnr    = ParseKlnr(cRemainder).
        oReqBody = GetJsonBody(poRequest).

        IF iSegCount EQ 1 THEN
        DO:
            /* PUT /klant/{klnr} */
            oService = NEW KlantBE().

            hResult = oService:UpdateKlant(iKlnr, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        cSub = ENTRY(2, cRemainder, "/":u).

        IF iSegCount EQ 2 THEN
        DO:
            IF cSub NE "uitgebreid":u THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /klant/[klnr]/uitgebreid, got &1":u, cRemainder)).
                RETURN 0.
            END.

            /* PUT /klant/{klnr}/uitgebreid */
            oService = NEW KlantBE().

            hResult = oService:UpdateKlantUitgebreid(iKlnr, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            cChildId = GetChildId(cRemainder).

            CASE cSub:
                WHEN "adres":u THEN
                DO:
                    iLijnnr = ParseLijnnr(cChildId).
                    oAdresService = NEW KlantAdresBE().

                    hResult = oAdresService:UpdateKlantAdres(iKlnr, iLijnnr, oReqBody).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).
                    RETURN 0.
                END.
                WHEN "contact":u THEN
                DO:
                    iLijnnr = ParseLijnnr(cChildId).
                    oContactService = NEW KlantContactBE().

                    hResult = oContactService:UpdateKlantContact(iKlnr, iLijnnr, oReqBody).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).
                    RETURN 0.
                END.
                WHEN "korting":u THEN
                DO:
                    oKortingService = NEW KlantKortingBE().

                    hResult = oKortingService:UpdateKorting(iKlnr, cChildId, oReqBody).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).
                    RETURN 0.
                END.
                OTHERWISE
                DO:
                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Expected /klant/[klnr]/(adres|contact|korting)/[id], got &1":u, cRemainder)).
                    RETURN 0.
                END.
            END CASE.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Unrecognized path /klant/&1":u, cRemainder)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: DELETE /klant/{klnr} and
                 DELETE /klant/{klnr}/(adres|contact|korting)/{id}.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService        AS KlantBE        NO-UNDO.
        DEFINE VARIABLE oAdresService   AS KlantAdresBE   NO-UNDO.
        DEFINE VARIABLE oContactService AS KlantContactBE NO-UNDO.
        DEFINE VARIABLE oKortingService AS KlantKortingBE NO-UNDO.
        DEFINE VARIABLE cRemainder      AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iSegCount       AS INTEGER        NO-UNDO.
        DEFINE VARIABLE iKlnr           AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cSub            AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE cChildId        AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iLijnnr         AS INTEGER        NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject     NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "klnr path segment is required, e.g. /klant/123":u).
            RETURN 0.
        END.

        iKlnr = ParseKlnr(cRemainder).

        IF iSegCount EQ 1 THEN
        DO:
            /* DELETE /klant/{klnr} */
            oService = NEW KlantBE().
            oService:DeleteKlant(iKlnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("klnr":u, iKlnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            cSub     = ENTRY(2, cRemainder, "/":u).
            cChildId = GetChildId(cRemainder).

            CASE cSub:
                WHEN "adres":u THEN
                DO:
                    iLijnnr = ParseLijnnr(cChildId).
                    oAdresService = NEW KlantAdresBE().
                    oAdresService:DeleteKlantAdres(iKlnr, iLijnnr).

                    oBody = NEW JsonObject().
                    oBody:Add("status":u, "deleted":u).
                    oBody:Add("klnr":u, iKlnr).
                    oBody:Add("lijnnr":u, iLijnnr).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                    RETURN 0.
                END.
                WHEN "contact":u THEN
                DO:
                    iLijnnr = ParseLijnnr(cChildId).
                    oContactService = NEW KlantContactBE().
                    oContactService:DeleteKlantContact(iKlnr, iLijnnr).

                    oBody = NEW JsonObject().
                    oBody:Add("status":u, "deleted":u).
                    oBody:Add("klnr":u, iKlnr).
                    oBody:Add("lijnnr":u, iLijnnr).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                    RETURN 0.
                END.
                WHEN "korting":u THEN
                DO:
                    oKortingService = NEW KlantKortingBE().
                    oKortingService:DeleteKorting(iKlnr, cChildId).

                    oBody = NEW JsonObject().
                    oBody:Add("status":u, "deleted":u).
                    oBody:Add("klnr":u, iKlnr).
                    oBody:Add("artnr":u, cChildId).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                    RETURN 0.
                END.
                OTHERWISE
                DO:
                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Expected /klant/[klnr]/(adres|contact|korting)/[id], got &1":u, cRemainder)).
                    RETURN 0.
                END.
            END CASE.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Unrecognized path /klant/&1":u, cRemainder)).

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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /klant":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /klant":u).
        RETURN 0.
    END METHOD.

END CLASS.
