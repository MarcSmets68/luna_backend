/*------------------------------------------------------------------------
    File        : LedKleurafwerkingHandler.cls
    Purpose     : WebHandler exposing full CRUD for led_kleurafwerking.
    Syntax      : GET    /web/led-kleurafwerking                       - list (paged/filtered - kleursoort, standaard)
                  GET    /web/led-kleurafwerking/kleursoort/kode        - get one
                  POST   /web/led-kleurafwerking                       - create (404 if kleursoort not in led_kleursoort, 409 on key collision)
                  PUT    /web/led-kleurafwerking/kleursoort/kode        - update (omschr/standaard only)
                  DELETE /web/led-kleurafwerking/kleursoort/kode        - delete (no known referential block, see LedKleurafwerkingBE header)
    Description : Thin WebHandler only - all DB access/business logic lives
                  in Luna.BusinessLogic.LedKleurafwerkingBE. Composite key
                  path segments are in the fixed order kleursoort/kode.
                  Added per docs/architecture/coating-fase1-afronding-ontwerp.md
                  sectie 7 - exposes the pre-existing `standaard` flag
                  (standaardkleur, Punt 6 / FR-15/16/17), no schema change.
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LedKleurafwerkingBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LedKleurafwerkingHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-kleurafwerking":u.

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

    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

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

    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the 2 key path segments (kleursoort/kode).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ParseKey(
        INPUT  poRequest    AS IWebRequest,
        OUTPUT pcKleursoort AS CHARACTER,
        OUTPUT pcKode       AS CHARACTER ):

        DEFINE VARIABLE cRemainder AS CHARACTER NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).

        IF NUM-ENTRIES(cRemainder, "/":u) NE 2 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                "Expected /led-kleurafwerking/kleursoort/kode (2 non-empty path segments)":u).
            RETURN FALSE.
        END.

        ASSIGN
            pcKleursoort = ENTRY(1, cRemainder, "/":u)
            pcKode       = ENTRY(2, cRemainder, "/":u)
            .

        IF pcKleursoort EQ "":u OR pcKode EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kleursoort and kode path segments cannot be empty":u).
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService          AS LedKleurafwerkingBE NO-UNDO.
        DEFINE VARIABLE cRemainder        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKleursoort       AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKode             AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE hResult           AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody             AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems            AS JsonArray  NO-UNDO.
        DEFINE VARIABLE iPage             AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPageSize         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cKleursoortFilter AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cStandaardFilter  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE lHasMore          AS LOGICAL    NO-UNDO.

        oService   = NEW LedKleurafwerkingBE().
        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "":u THEN
        DO:
            IF NOT ParseKey(poRequest, OUTPUT cKleursoort, OUTPUT cKode) THEN
                RETURN 0.

            hResult = oService:GetItem(cKleursoort, cKode).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                    SUBSTITUTE("led_kleurafwerking &1/&2 not found":u, cKleursoort, cKode)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        cKleursoortFilter = poRequest:URI:GetQueryValue("kleursoort":u).
        IF cKleursoortFilter EQ ? THEN cKleursoortFilter = "":u.

        cStandaardFilter = poRequest:URI:GetQueryValue("standaard":u).
        IF cStandaardFilter EQ ? THEN cStandaardFilter = "":u.
        cStandaardFilter = LC(cStandaardFilter).

        hResult = oService:GetItems(iPage, iPageSize, cKleursoortFilter, cStandaardFilter, OUTPUT lHasMore).
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

    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS LedKleurafwerkingBE NO-UNDO.
        DEFINE VARIABLE oReqBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cKleursoort AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKode       AS CHARACTER  NO-UNDO.

        oService = NEW LedKleurafwerkingBE().
        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("kleursoort":u) OR TRIM(oReqBody:GetCharacter("kleursoort":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kleursoort is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("kode":u) OR TRIM(oReqBody:GetCharacter("kode":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode is required":u).
            RETURN 0.
        END.

        ASSIGN
            cKleursoort = oReqBody:GetCharacter("kleursoort":u)
            cKode       = oReqBody:GetCharacter("kode":u)
            .

        hResult = oService:CreateItem(cKleursoort, cKode, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS LedKleurafwerkingBE NO-UNDO.
        DEFINE VARIABLE cKleursoort AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKode       AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oReqBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cKleursoort, OUTPUT cKode) THEN
            RETURN 0.

        oService = NEW LedKleurafwerkingBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:UpdateItem(cKleursoort, cKode, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS LedKleurafwerkingBE NO-UNDO.
        DEFINE VARIABLE cKleursoort AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKode       AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cKleursoort, OUTPUT cKode) THEN
            RETURN 0.

        oService = NEW LedKleurafwerkingBE().
        oService:DeleteItem(cKleursoort, cKode).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("kleursoort":u, cKleursoort).
        oBody:Add("kode":u, cKode).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-kleurafwerking":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-kleurafwerking":u).
        RETURN 0.
    END METHOD.

END CLASS.
