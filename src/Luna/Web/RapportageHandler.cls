/*------------------------------------------------------------------------
    File        : RapportageHandler.cls
    Purpose     : WebHandler mounted at /rapportage for the "Rapportage"
                  section - a dedicated mount point (not bolted onto any
                  existing CRUD handler) since this section is expected to
                  grow more than one report over time.
    Syntax      : GET /web/rapportage/verkoop-fur - Verkoop FUR dealer
                  overview (see Luna.BusinessLogic.VerkoopFurBE).
    Description : Thin WebHandler only - routing/parsing/response shaping.
                  The path after /rapportage/ must be a known literal report
                  route: "verkoop-fur", "omzetanalyse-dealers" or
                  "omzetanalyse-dealers/soorten". Unknown -> 400. All
                  business logic and DB access lives in
                  Luna.BusinessLogic.VerkoopFurBE / OmzetanalyseDealersBE. See
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
USING Luna.BusinessLogic.OmzetanalyseDealersBE.
USING Luna.Web.Util.QueryParamHelper.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.RapportageHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/rapportage" with the
       implicit trailing wildcard, so this also matches every nested path
       below it too (e.g. "/rapportage/verkoop-fur"). This constant is the
       mount point we strip off PathInfo to find the remaining path
       segment(s). */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/rapportage":u.

    DEFINE PRIVATE VARIABLE cVerkoopFurSegment AS CHARACTER NO-UNDO INITIAL "verkoop-fur":u.
    DEFINE PRIVATE VARIABLE cOmzetSegment        AS CHARACTER NO-UNDO INITIAL "omzetanalyse-dealers":u.
    DEFINE PRIVATE VARIABLE cOmzetSoortenSegment AS CHARACTER NO-UNDO INITIAL "omzetanalyse-dealers/soorten":u.

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
        Purpose: TRUE when pcValue is non-empty and consists of digits 0-9 only.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL IsDigits( INPUT pcValue AS CHARACTER ):

        DEFINE VARIABLE i AS INTEGER NO-UNDO.

        IF pcValue EQ ? OR pcValue EQ "":u THEN
            RETURN FALSE.

        DO i = 1 TO LENGTH(pcValue):
            IF INDEX("0123456789":u, SUBSTRING(pcValue, i, 1)) EQ 0 THEN
                RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses an optional "YYYY-MM-DD" query value. "" -> ? (not given).
                 Returns FALSE when the value is present but malformed.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL TryParseDate( INPUT pcValue AS CHARACTER, OUTPUT pdValue AS DATE ):

        DEFINE VARIABLE iYear  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iMonth AS INTEGER NO-UNDO.
        DEFINE VARIABLE iDay   AS INTEGER NO-UNDO.

        pdValue = ?.

        IF pcValue EQ "":u THEN
            RETURN TRUE.

        IF LENGTH(pcValue) NE 10 OR SUBSTRING(pcValue, 5, 1) NE "-":u OR SUBSTRING(pcValue, 8, 1) NE "-":u THEN
            RETURN FALSE.

        IF NOT (IsDigits(SUBSTRING(pcValue, 1, 4))
            AND IsDigits(SUBSTRING(pcValue, 6, 2))
            AND IsDigits(SUBSTRING(pcValue, 9, 2))) THEN
            RETURN FALSE.

        ASSIGN
            iYear  = INTEGER(SUBSTRING(pcValue, 1, 4))
            iMonth = INTEGER(SUBSTRING(pcValue, 6, 2))
            iDay   = INTEGER(SUBSTRING(pcValue, 9, 2))
            .

        IF iYear LT 1900 OR iMonth LT 1 OR iMonth GT 12 OR iDay LT 1 OR iDay GT 31 THEN
            RETURN FALSE.

        pdValue = DATE(iMonth, iDay, iYear) NO-ERROR.
        IF ERROR-STATUS:ERROR OR pdValue EQ ? THEN
        DO:
            pdValue = ?.
            RETURN FALSE.
        END.

        /* DATE(2,31,..) would silently roll over in some releases - round-trip check. */
        IF DAY(pdValue) NE iDay OR MONTH(pdValue) NE iMonth THEN
        DO:
            pdValue = ?.
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses an optional boolean query value ("true"/"false").
                 "" -> pcDefault. Returns FALSE when present but invalid.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL TryParseBool( INPUT pcValue AS CHARACTER, INPUT plDefault AS LOGICAL, OUTPUT plValue AS LOGICAL ):

        plValue = plDefault.

        IF pcValue EQ "":u THEN
            RETURN TRUE.

        IF pcValue EQ "true":u THEN
            plValue = TRUE.
        ELSE IF pcValue EQ "false":u THEN
            plValue = FALSE.
        ELSE
            RETURN FALSE.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Makes sure an (optional) nested array property exists on a JsonObject
                 - WRITE-JSON may omit empty nested child tables.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureArray( INPUT poObj AS JsonObject, INPUT pcName AS CHARACTER ):

        IF NOT poObj:Has(pcName) THEN
            poObj:Add(pcName, NEW JsonArray()).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Response shaping for the Omzetanalyse dealers ProDataSet JSON:
                 unwraps dataset/root table, turns the one-row "filters" array into
                 an object, turns the "meters" rows into
                 {ledstripNomatrack:[..], coverLicht:[..]}, guarantees empty arrays.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ShapeOmzetanalyse( INPUT poRaw AS JsonObject ):

        DEFINE VARIABLE oDs        AS JsonObject NO-UNDO.
        DEFINE VARIABLE oRoot      AS JsonObject NO-UNDO.
        DEFINE VARIABLE aFilters   AS JsonArray  NO-UNDO.
        DEFINE VARIABLE aSecties   AS JsonArray  NO-UNDO.
        DEFINE VARIABLE aCats      AS JsonArray  NO-UNDO.
        DEFINE VARIABLE aRijen     AS JsonArray  NO-UNDO.
        DEFINE VARIABLE aMeters    AS JsonArray  NO-UNDO.
        DEFINE VARIABLE aLsn       AS JsonArray  NO-UNDO.
        DEFINE VARIABLE aCover     AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oSectie    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oCat       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oRij       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oMeter     AS JsonObject NO-UNDO.
        DEFINE VARIABLE oMeters    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oFilters   AS JsonObject NO-UNDO.
        DEFINE VARIABLE cNames     AS CHARACTER  NO-UNDO EXTENT.
        DEFINE VARIABLE iSec       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iCat       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iRij       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iMet       AS INTEGER    NO-UNDO.

        cNames = poRaw:GetNames().
        oDs    = poRaw:GetJsonObject(cNames[1]).
        oRoot = oDs:GetJsonArray("analyse":u):GetJsonObject(1).

        EnsureArray(oRoot, "kolommen":u).
        EnsureArray(oRoot, "secties":u).

        aFilters = oRoot:GetJsonArray("filters":u).
        oFilters = aFilters:GetJsonObject(1).
        oRoot:Remove("filters":u).
        oRoot:Add("filters":u, oFilters).

        aSecties = oRoot:GetJsonArray("secties":u).
        DO iSec = 1 TO aSecties:Length:
            oSectie = aSecties:GetJsonObject(iSec).
            EnsureArray(oSectie, "categorieen":u).
            EnsureArray(oSectie, "omzet":u).
            EnsureArray(oSectie, "meters":u).

            aMeters = oSectie:GetJsonArray("meters":u).
            aLsn    = NEW JsonArray().
            aCover  = NEW JsonArray().
            DO iMet = 1 TO aMeters:Length:
                oMeter = aMeters:GetJsonObject(iMet).
                aLsn:Add(oMeter:GetDecimal("ledstripNomatrack":u)).
                aCover:Add(oMeter:GetDecimal("coverLicht":u)).
            END.
            oMeters = NEW JsonObject().
            oMeters:Add("ledstripNomatrack":u, aLsn).
            oMeters:Add("coverLicht":u, aCover).
            oSectie:Remove("meters":u).
            oSectie:Add("meters":u, oMeters).

            aCats = oSectie:GetJsonArray("categorieen":u).
            DO iCat = 1 TO aCats:Length:
                oCat = aCats:GetJsonObject(iCat).
                EnsureArray(oCat, "rijen":u).
                EnsureArray(oCat, "totalen":u).
                aRijen = oCat:GetJsonArray("rijen":u).
                DO iRij = 1 TO aRijen:Length:
                    oRij = aRijen:GetJsonObject(iRij).
                    EnsureArray(oRij, "perioden":u).
                END.
            END.
        END.

        RETURN oRoot.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /rapportage/omzetanalyse-dealers[/soorten] - parses query
                 params (type validation only), calls the BE, shapes the response.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleOmzetanalyse( INPUT poRequest AS IWebRequest, INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE oService    AS OmzetanalyseDealersBE NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE cVan        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cTot        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cKlnr       AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cSoort      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cPerDealer  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cLeeg       AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE dVan        AS DATE       NO-UNDO.
        DEFINE VARIABLE dTot        AS DATE       NO-UNDO.
        DEFINE VARIABLE iKlnr       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE lPerDealer  AS LOGICAL    NO-UNDO.
        DEFINE VARIABLE lLeeg       AS LOGICAL    NO-UNDO.

        oService = NEW OmzetanalyseDealersBE().

        IF pcRemainder EQ cOmzetSoortenSegment THEN
        DO:
            hResult = oService:GetSoorten().
            oBody   = ResultHandleToJson(hResult).
            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
            RETURN.
        END.

        ASSIGN
            cVan       = QueryParamHelper:GetQueryValue(poRequest, "datumVan":u)
            cTot       = QueryParamHelper:GetQueryValue(poRequest, "datumTot":u)
            cKlnr      = QueryParamHelper:GetQueryValue(poRequest, "klnr":u)
            cSoort     = QueryParamHelper:GetQueryValue(poRequest, "soort":u)
            cPerDealer = QueryParamHelper:GetQueryValue(poRequest, "perDealer":u)
            cLeeg      = QueryParamHelper:GetQueryValue(poRequest, "leegRijen":u)
            .

        IF NOT TryParseDate(cVan, OUTPUT dVan) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ongeldige datumVan - verwacht formaat YYYY-MM-DD":u).
            RETURN.
        END.
        IF NOT TryParseDate(cTot, OUTPUT dTot) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ongeldige datumTot - verwacht formaat YYYY-MM-DD":u).
            RETURN.
        END.

        iKlnr = ?.
        IF cKlnr NE "":u THEN
        DO:
            IF LENGTH(cKlnr) GT 9 OR NOT IsDigits(cKlnr) OR INTEGER(cKlnr) LE 0 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ongeldige klnr - verwacht een positief geheel getal":u).
                RETURN.
            END.
            iKlnr = INTEGER(cKlnr).
        END.

        IF NOT TryParseBool(cPerDealer, FALSE, OUTPUT lPerDealer) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ongeldige perDealer - verwacht true of false":u).
            RETURN.
        END.
        IF NOT TryParseBool(cLeeg, TRUE, OUTPUT lLeeg) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ongeldige leegRijen - verwacht true of false":u).
            RETURN.
        END.

        hResult = oService:GetAnalyse(dVan, dTot, iKlnr,
                                      (IF cSoort EQ "":u THEN ? ELSE cSoort),
                                      lPerDealer, lLeeg).

        oBody = ShapeOmzetanalyse(ResultHandleToJson(hResult)).
        oBody:Add("generatedAt":u, ISO-DATE(NOW)).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Routes GET /rapportage/<report>. Route table:
                   verkoop-fur                     -> VerkoopFurBE
                   omzetanalyse-dealers            -> OmzetanalyseDealersBE:GetAnalyse
                   omzetanalyse-dealers/soorten    -> OmzetanalyseDealersBE:GetSoorten
                 Anything else -> 400.
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

        IF iSegCount GE 1 AND iSegCount LE 2
           AND (cRemainder EQ cOmzetSegment OR cRemainder EQ cOmzetSoortenSegment) THEN
        DO:
            HandleOmzetanalyse(poRequest, cRemainder).
            RETURN 0.
        END.

        IF iSegCount NE 1 OR cRemainder NE cVerkoopFurSegment THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Unknown report /rapportage/&1 - expected /rapportage/&2, /rapportage/&3 or /rapportage/&4":u,
                    cRemainder, cVerkoopFurSegment, cOmzetSegment, cOmzetSoortenSegment)).
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

        CATCH oError AS Progress.Lang.Error:
            WriteErrorResponse(INTEGER(StatusCodeEnum:InternalServerError), "Interne fout bij het opbouwen van het rapport":u).
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
