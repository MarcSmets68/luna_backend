/*------------------------------------------------------------------------
    File        : LedTechniekleverHandler.cls
    Purpose     : WebHandler exposing CRUD for led_technieklever.
    Syntax      : GET    /web/led-technieklever                                          - list (paged/filtered - laktechniek, levnr)
                  GET    /web/led-technieklever/laktechniek/kleursoort/ledType/levnr       - get one
                  POST   /web/led-technieklever                                           - create (404 if levnr not in lever, 409 on key collision)
                  PUT    /web/led-technieklever/laktechniek/kleursoort/ledType/levnr       - update (instelkost/kleursupplement only)
                  DELETE /web/led-technieklever/laktechniek/kleursoort/ledType/levnr       - delete
    Description : Thin WebHandler only - all DB access/business logic lives
                  in Luna.BusinessLogic.LedTechniekleverBE. Composite key
                  path segments are in the fixed order
                  laktechniek/kleursoort/ledType/levnr.
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LedTechniekleverBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LedTechniekleverHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-technieklever":u.

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
        Purpose: Parses the 4 key path segments (laktechniek/kleursoort/ledType/levnr).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ParseKey(
        INPUT  poRequest      AS IWebRequest,
        OUTPUT pcLaktechniek  AS CHARACTER,
        OUTPUT pcKleursoort   AS CHARACTER,
        OUTPUT pcLedType      AS CHARACTER,
        OUTPUT piLevnr        AS INTEGER ):

        DEFINE VARIABLE cRemainder AS CHARACTER NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).

        IF NUM-ENTRIES(cRemainder, "/":u) NE 4 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                "Expected /led-technieklever/laktechniek/kleursoort/ledType/levnr (4 non-empty path segments)":u).
            RETURN FALSE.
        END.

        ASSIGN
            pcLaktechniek = ENTRY(1, cRemainder, "/":u)
            pcKleursoort  = ENTRY(2, cRemainder, "/":u)
            pcLedType     = ENTRY(3, cRemainder, "/":u)
            .

        IF pcLaktechniek EQ "":u OR pcKleursoort EQ "":u OR pcLedType EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "laktechniek, kleursoort and ledType path segments cannot be empty":u).
            RETURN FALSE.
        END.

        piLevnr = INTEGER(ENTRY(4, cRemainder, "/":u)) NO-ERROR.
        IF piLevnr EQ ? OR ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Invalid levnr &1":u, ENTRY(4, cRemainder, "/":u))).
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService       AS LedTechniekleverBE NO-UNDO.
        DEFINE VARIABLE cRemainder     AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cLaktechniek   AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cKleursoort    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cLedType       AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iLevnr         AS INTEGER     NO-UNDO.
        DEFINE VARIABLE hResult        AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody          AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems         AS JsonArray   NO-UNDO.
        DEFINE VARIABLE iPage          AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize      AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cLaktFilter    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cLevnrFilter   AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iLevnrFilter   AS INTEGER     NO-UNDO.
        DEFINE VARIABLE lHasMore       AS LOGICAL     NO-UNDO.

        oService   = NEW LedTechniekleverBE().
        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "":u THEN
        DO:
            IF NOT ParseKey(poRequest, OUTPUT cLaktechniek, OUTPUT cKleursoort, OUTPUT cLedType, OUTPUT iLevnr) THEN
                RETURN 0.

            hResult = oService:GetItem(cLaktechniek, cKleursoort, cLedType, iLevnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                    SUBSTITUTE("led_technieklever &1/&2/&3/&4 not found":u, cLaktechniek, cKleursoort, cLedType, iLevnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        cLaktFilter = poRequest:URI:GetQueryValue("laktechniek":u).
        IF cLaktFilter EQ ? THEN cLaktFilter = "":u.

        cLevnrFilter = poRequest:URI:GetQueryValue("levnr":u).
        iLevnrFilter = INTEGER(cLevnrFilter) NO-ERROR.
        IF iLevnrFilter EQ ? OR ERROR-STATUS:ERROR THEN iLevnrFilter = 0.

        hResult = oService:GetItems(iPage, iPageSize, cLaktFilter, iLevnrFilter, OUTPUT lHasMore).
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

        DEFINE VARIABLE oService     AS LedTechniekleverBE NO-UNDO.
        DEFINE VARIABLE oReqBody     AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems       AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cLaktechniek AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKleursoort  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cLedType     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iLevnr       AS INTEGER    NO-UNDO.

        oService = NEW LedTechniekleverBE().
        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("laktechniek":u) OR TRIM(oReqBody:GetCharacter("laktechniek":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "laktechniek is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("kleursoort":u) OR TRIM(oReqBody:GetCharacter("kleursoort":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kleursoort is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("levnr":u) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "levnr is required":u).
            RETURN 0.
        END.

        ASSIGN
            cLaktechniek = oReqBody:GetCharacter("laktechniek":u)
            cKleursoort  = oReqBody:GetCharacter("kleursoort":u)
            cLedType     = (IF oReqBody:Has("ledType":u) AND TRIM(oReqBody:GetCharacter("ledType":u)) NE "":u
                             THEN oReqBody:GetCharacter("ledType":u) ELSE "Geen":u)
            iLevnr       = oReqBody:GetInteger("levnr":u)
            .

        hResult = oService:CreateItem(cLaktechniek, cKleursoort, cLedType, iLevnr, oReqBody).
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

        DEFINE VARIABLE oService     AS LedTechniekleverBE NO-UNDO.
        DEFINE VARIABLE cLaktechniek AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKleursoort  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cLedType     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iLevnr       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody     AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems       AS JsonArray  NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cLaktechniek, OUTPUT cKleursoort, OUTPUT cLedType, OUTPUT iLevnr) THEN
            RETURN 0.

        oService = NEW LedTechniekleverBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:UpdateItem(cLaktechniek, cKleursoort, cLedType, iLevnr, oReqBody).
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

        DEFINE VARIABLE oService     AS LedTechniekleverBE NO-UNDO.
        DEFINE VARIABLE cLaktechniek AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKleursoort  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cLedType     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iLevnr       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cLaktechniek, OUTPUT cKleursoort, OUTPUT cLedType, OUTPUT iLevnr) THEN
            RETURN 0.

        oService = NEW LedTechniekleverBE().
        oService:DeleteItem(cLaktechniek, cKleursoort, cLedType, iLevnr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("laktechniek":u, cLaktechniek).
        oBody:Add("kleursoort":u, cKleursoort).
        oBody:Add("ledType":u, cLedType).
        oBody:Add("levnr":u, iLevnr).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-technieklever":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-technieklever":u).
        RETURN 0.
    END METHOD.

END CLASS. 
