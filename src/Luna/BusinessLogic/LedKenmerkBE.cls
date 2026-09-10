/*------------------------------------------------------------------------  
    File        : LedKenmerkBE.cls  
    Purpose     : Business Entity for led_kenmerk (LED kenmerk codes).  
                  NO-LOCK reads, EXCLUSIVE-LOCK in a transaction for writes.  
    Field map   : kode -> kode (PK, immutable, char(10))  
    Notes       : No referential validation on create/update. DELETE is  
                  blocked (409) if kode is referenced by artikel.led-kenmerk.  
                  art_led has no led-kenmerk field (checked against  
                  docs/db-analysis/schema_dump.txt), so it is not checked.  
    Author(s)   : Devin  
    Created     : 2026-08-29  
  ----------------------------------------------------------------------*/  
  
USING Progress.Lang.*.  
USING Progress.Json.ObjectModel.JsonObject.  
  
BLOCK-LEVEL ON ERROR UNDO, THROW.  
  
CLASS Luna.BusinessLogic.LedKenmerkBE:  
 
    DEFINE TEMP-TABLE ttLedKenmerk NO-UNDO SERIALIZE-NAME "items":u  
        FIELD kode AS CHARACTER SERIALIZE-NAME "kode":u  
        INDEX idx-kode IS PRIMARY kode.  
  
    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_kenmerk, BUFFER pbTt FOR ttLedKenmerk ):  
        ASSIGN pbTt.kode = pbSrc.kode.  
    END METHOD.  
  
    METHOD PUBLIC HANDLE GetItems(  
        INPUT  piPage AS INTEGER, INPUT piPageSize AS INTEGER,  
        INPUT  pcKode AS CHARACTER, INPUT pcKodePrefix AS CHARACTER,  
        OUTPUT plHasMore AS LOGICAL ):  
  
        DEFINE VARIABLE iSkip AS INTEGER NO-UNDO.  
        DEFINE VARIABLE iSeen AS INTEGER NO-UNDO.  
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.  
        DEFINE VARIABLE cScan AS CHARACTER NO-UNDO.  
  
        EMPTY TEMP-TABLE ttLedKenmerk. 
  
        ASSIGN  
            pcKode = TRIM(pcKode)  
            pcKodePrefix = TRIM(pcKodePrefix)  
            cScan = (IF pcKode NE "":u THEN pcKode ELSE pcKodePrefix)  
            iSkip = (piPage - 1) * piPageSize  
            iSeen = 0  
            iTaken = 0  
            plHasMore = FALSE.  
  
        FOR EACH led_kenmerk NO-LOCK WHERE led_kenmerk.kode BEGINS cScan BY led_kenmerk.kode:  
            IF pcKode NE "":u AND led_kenmerk.kode NE pcKode THEN NEXT.  
            iSeen = iSeen + 1.  
            IF iSeen LE iSkip THEN NEXT.  
            IF iTaken GE piPageSize THEN DO:  
                plHasMore = TRUE.  
                LEAVE.  
            END.  
            CREATE ttLedKenmerk.  
            CopyToTt( BUFFER led_kenmerk, BUFFER ttLedKenmerk ).  
            iTaken = iTaken + 1.  
        END. 
  
        RETURN TEMP-TABLE ttLedKenmerk:HANDLE.  
    END METHOD.  
  
    METHOD PUBLIC HANDLE GetItem( INPUT pcKode AS CHARACTER ):  
        EMPTY TEMP-TABLE ttLedKenmerk.  
        FIND FIRST led_kenmerk NO-LOCK WHERE led_kenmerk.kode EQ pcKode NO-ERROR.  
        IF AVAILABLE led_kenmerk THEN DO:  
            CREATE ttLedKenmerk.  
            CopyToTt( BUFFER led_kenmerk, BUFFER ttLedKenmerk ).  
        END.  
        RETURN TEMP-TABLE ttLedKenmerk:HANDLE.  
    END METHOD.  
 
    METHOD PUBLIC HANDLE CreateItem( INPUT pcKode AS CHARACTER ):  
        EMPTY TEMP-TABLE ttLedKenmerk.  
        DO TRANSACTION:  
            FIND FIRST led_kenmerk EXCLUSIVE-LOCK WHERE led_kenmerk.kode EQ pcKode NO-ERROR.  
            IF AVAILABLE led_kenmerk THEN  
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_kenmerk &1 already exists":u, pcKode), 409).  
            CREATE led_kenmerk.  
            ASSIGN led_kenmerk.kode = pcKode.  
            CREATE ttLedKenmerk.  
            CopyToTt( BUFFER led_kenmerk, BUFFER ttLedKenmerk ).  
        END.  
        RETURN TEMP-TABLE ttLedKenmerk:HANDLE.  
    END METHOD.  
 
    METHOD PRIVATE LOGICAL IsKenmerkReferenced( INPUT pcKode AS CHARACTER ):  
        FIND FIRST artikel NO-LOCK WHERE artikel.led-kenmerk EQ pcKode NO-ERROR.  
        RETURN AVAILABLE artikel.  
    END METHOD.  
  
    METHOD PUBLIC VOID DeleteItem( INPUT pcKode AS CHARACTER ):  
        DO TRANSACTION:  
            FIND FIRST led_kenmerk EXCLUSIVE-LOCK WHERE led_kenmerk.kode EQ pcKode NO-ERROR.  
            IF NOT AVAILABLE led_kenmerk THEN  
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_kenmerk &1 not found":u, pcKode), 404).  
            IF IsKenmerkReferenced(pcKode) THEN  
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_kenmerk &1 is still referenced by artikel rows":u, pcKode), 409).  
            DELETE led_kenmerk.  
        END.  
    END METHOD.  
  
END CLASS. 
