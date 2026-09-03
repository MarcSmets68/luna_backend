/*------------------------------------------------------------------------
    File        : RapportageHandler.cls
    Purpose     : WebHandler mounted at /rapportage for the "Rapportage"
                  section - a dedicated mount point (not bolted onto any
                  existing CRUD handler) since this section is expected to
                  grow more than one report over time.
    Syntax      : GET /web/rapportage/verkoop-fur - Verkoop FUR dealer
                  overview (see Luna.BusinessLogic.VerkoopFurBE).
    Description : Thin WebHandler only - routing/parsing/response shaping.
                  The 1st path segment after /rapportage/ must be a known
                  literal report name; today only "verkoop-fur" is valid.
                  Unknown segment -> 400. All business logic and DB access
                  lives in Luna.BusinessLogic.VerkoopFurBE. See
                  docs/architecture/verkoop-fur-ontwerp.md for the full
                  design.
    Author(s)   : Devin
    Created     : 2026-09-03
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.VerkoopFurBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.RapportageHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/rapportage" with the
       implicit trailing wildcard, so this also matches every nested path
       below it too (e.g. "/rapportage/verkoop-fur"). This constant is the
       mount point we strip off PathInfo to find the remaining path
       segment(s). */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/rapportage":u.

    DEFINE PRIVATE VARIABLE cVerkoopFurSegment AS CHARACTER NO-UNDO INITIAL "verkoop-fur":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segment(s) (if any) after the mount
                 point, e.g. "/rapportage/verkoop-fur" -> "verkoop-fur",
                 "/rapportage" or "/rapportage/" -> "".
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
        Purpose: Serializes a result handle (from a Business Entity) to a JsonObject.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
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
        Purpose: Maps an AppError raised by a Business Entity (400/404/409)
                 to an HTTP status code, defaulting unrecognized codes to
                 500 so no ABL stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /rapportage/verkoop-fur - the Verkoop FUR dealer
                 overview. Any other 1st path segment (or none) -> 400.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cRemainder AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oService   AS VerkoopFurBE NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.
        DEFINE VARIABLE dPeriodeVan AS DATE      NO-UNDO.
        DEFINE VARIABLE dPeriodeTot AS DATE      NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount NE 1 OR cRemainder NE cVerkoopFurSegment THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Unknown report /rapportage/&1 - expected /rapportage/&2":u,
                    cRemainder, cVerkoopFurSegment)).
            RETURN 0.
        END.

        oService = NEW VerkoopFurBE().
        hResult  = oService:GetVerkoopFurOverzicht(OUTPUT dPeriodeVan, OUTPUT dPeriodeTot).

        oBody = ResultHandleToJson(hResult).
        oBody:Add("periodeVan":u, dPeriodeVan).
        oBody:Add("periodeTot":u, dPeriodeTot).
        oBody:Add("generatedAt":u, ISO-DATE(NOW)).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint (all
                 except GET).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /rapportage":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /rapportage":u).
        RETURN 0.
    END METHOD.

END CLASS.
