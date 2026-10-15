/*------------------------------------------------------------------------
    File        : LeverancierHandler.cls
    Purpose     : WebHandler exposing full CRUD for the "lever" table
                  (core field subset - see Luna.BusinessLogic.LeverancierBE
                  for the field map).
    Syntax      : GET    /web/leverancier                 - list (paged/filtered)
                  GET    /web/leverancier/{levnr}         - get one
                  POST   /web/leverancier                 - create (levnr auto-generated server-side)
                  PUT    /web/leverancier/{levnr}         - update
                  DELETE /web/leverancier/{levnr}         - delete
    Description : Thin WebHandler only - routing, request parsing, response
                  formatting and HTTP status/error mapping. No business logic
                  and no direct DB access - all of that lives in
                  Luna.BusinessLogic.LeverancierBE.
    Author(s)   : Devin
    Created     : 2026-08-10
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LeverancierBE.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LeverancierHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/leverancier" with the implicit
       trailing wildcard, so this also matches "/leverancier/{levnr}". This
       constant is the mount point we strip off PathInfo to find the
       (optional) levnr path segment. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/leverancier":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the levnr path segment (if any) from the request, e.g.
                 "/leverancier/123" -> "123", "/leverancier" or "/leverancier/" -> "".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetLevnrFromPath( INPUT poRequest AS IWebRequest ):

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
        Purpose: Serializes a ttLeverancier result handle (from LeverancierBE)
                 to a JsonObject shaped as {"items": [...]}.
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
        Purpose: Maps an AppError raised by LeverancierBE (400/404/409) to an
                 HTTP status code, defaulting unrecognized codes to 500 so no
                 ABL stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /leverancier (list, paged/filtered) and GET /leverancier/{levnr}
                 (single record).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService  AS LeverancierBE NO-UNDO.
        DEFINE VARIABLE cLevnr    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iLevnr    AS INTEGER     NO-UNDO.
        DEFINE VARIABLE hResult   AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody     AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems    AS JsonArray   NO-UNDO.
        DEFINE VARIABLE iPage     AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cNaam     AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE lHasMore  AS LOGICAL     NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        oService = NEW LeverancierBE().
        cLevnr   = GetLevnrFromPath(poRequest).

        IF cLevnr NE "":u THEN
        DO:
            /* GET /leverancier/{levnr} */
            iLevnr = INTEGER(cLevnr) NO-ERROR.
            IF iLevnr EQ ? OR ERROR-STATUS:ERROR THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid levnr &1":u, cLevnr)).
                RETURN 0.
            END.

            hResult = oService:GetLeverancier(iLevnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Leverancier &1 not found":u, iLevnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* GET /leverancier (list). */
        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        /* GetQueryValue returns the unknown value (?) when the query param
           is absent - normalize that to "" so LeverancierBE treats "not
           supplied" and "supplied blank" the same way (same as
           Luna.Web.KlantHandler). */
        cNaam = poRequest:URI:GetQueryValue("naam":u).
        IF cNaam EQ ? THEN cNaam = "":u.

        hResult = oService:GetLeveranciers(iPage, iPageSize, cNaam, OUTPUT lHasMore).
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
        Purpose: POST /leverancier (create). `levnr` is generated server-side
                 by LeverancierBE:CreateLeverancier (last existing + 1) - any
                 `levnr` present in the request body is ignored.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LeverancierBE NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray  NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        oService = NEW LeverancierBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:CreateLeverancier(oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /leverancier/{levnr} (update).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LeverancierBE NO-UNDO.
        DEFINE VARIABLE cLevnr   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iLevnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray  NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cLevnr = GetLevnrFromPath(poRequest).

        IF cLevnr EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "levnr path segment is required, e.g. /leverancier/123":u).
            RETURN 0.
        END.

        iLevnr = INTEGER(cLevnr) NO-ERROR.
        IF iLevnr EQ ? OR ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid levnr &1":u, cLevnr)).
            RETURN 0.
        END.

        oService = NEW LeverancierBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:UpdateLeverancier(iLevnr, oReqBody).
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
        Purpose: DELETE /leverancier/{levnr}.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LeverancierBE NO-UNDO.
        DEFINE VARIABLE cLevnr   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iLevnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cLevnr = GetLevnrFromPath(poRequest).

        IF cLevnr EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "levnr path segment is required, e.g. /leverancier/123":u).
            RETURN 0.
        END.

        iLevnr = INTEGER(cLevnr) NO-ERROR.
        IF iLevnr EQ ? OR ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid levnr &1":u, cLevnr)).
            RETURN 0.
        END.

        oService = NEW LeverancierBE().
        oService:DeleteLeverancier(iLevnr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("levnr":u, iLevnr).

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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /leverancier":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /leverancier":u).
        RETURN 0.
    END METHOD.

END CLASS.

