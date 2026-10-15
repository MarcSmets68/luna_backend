/*------------------------------------------------------------------------
    File        : PlaatsingHandler.cls
    Purpose     : WebHandler exposing read-only access to the "plaatsing"
                  table (on-site installation appointments), see
                  Luna.BusinessLogic.PlaatsingBE for the field map.
    Syntax      : GET /web/plaatsing                 - list (paged/filtered: klnr, planr, naam, page, pageSize)
                  GET /web/plaatsing/{planr}         - get one
    Description : Thin WebHandler only - routing, request parsing and response
                  formatting. All DB access lives in PlaatsingBE.
    Author(s)   : Devin
    Created     : 2026-10-14
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.PlaatsingBE.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.PlaatsingHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/plaatsing":u.

    METHOD PRIVATE CHARACTER GetPathRemainder( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cPathInfo AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRest     AS CHARACTER NO-UNDO.

        cPathInfo = poRequest:PathInfo.

        IF cPathInfo BEGINS cMountPoint THEN
            cRest = SUBSTRING(cPathInfo, LENGTH(cMountPoint) + 1).
        ELSE
            cRest = cPathInfo.

        RETURN TRIM(cRest, "/":u).

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

    /*------------------------------------------------------------------------------
        Purpose: GET /plaatsing (list) and GET /plaatsing/{planr} (single).
                 Invalid numeric params silently fall back to defaults/no
                 filter (same approach as /web/bestelorder).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService   AS PlaatsingBE NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iPlanr     AS INTEGER     NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray   NO-UNDO.
        DEFINE VARIABLE iKlnr      AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cPlanr     AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cNaam      AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iPage      AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize  AS INTEGER     NO-UNDO.
        DEFINE VARIABLE lHasMore   AS LOGICAL     NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        oService   = NEW PlaatsingBE().
        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "":u THEN
        DO:
            IF NUM-ENTRIES(cRemainder, "/":u) GT 1 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /plaatsing/[planr], got &1":u, cRemainder)).
                RETURN 0.
            END.

            iPlanr = INTEGER(cRemainder) NO-ERROR.
            IF iPlanr EQ ? THEN iPlanr = 0.

            hResult = oService:GetPlaatsing(iPlanr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Plaatsing &1 not found":u, cRemainder)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iKlnr = INTEGER(poRequest:URI:GetQueryValue("klnr":u)) NO-ERROR.
        IF iKlnr EQ ? THEN iKlnr = 0.

        cPlanr = poRequest:URI:GetQueryValue("planr":u).
        IF cPlanr EQ ? THEN cPlanr = "":u.

        cNaam = poRequest:URI:GetQueryValue("naam":u).
        IF cNaam EQ ? THEN cNaam = "":u.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        hResult = oService:GetPlaatsingen(iKlnr, cPlanr, cNaam, iPage, iPageSize, OUTPUT lHasMore).
        oBody   = ResultHandleToJson(hResult).

        oBody:Add("page":u, iPage).
        oBody:Add("pageSize":u, iPageSize).
        oBody:Add("hasMore":u, lHasMore).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /plaatsing":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /plaatsing":u).
        RETURN 0.
    END METHOD.

END CLASS.
